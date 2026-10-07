import AppKit
import Foundation
import Darwin

private final class WorkDailyContext {
    let plan: AppInitialTrialPlan
    let lease: AppTrialRootLease
    let store: PrivateStore
    let coordinator: WorkDailyCoordinator
    let toolFingerprint: String
    let toolPath: String
    let directories: [String: WorkDirectory]
    let bootSession: String
    // The segment belongs to another launcher or official target. Only beginUpdate may continue.
    let updateRequired: Bool
    init() throws {
        guard Thread.isMainThread, CommandLine.arguments.count == 1,
              Bundle.main.bundleIdentifier == "local.codexsplit.work", WorkUpdateGuide.ownBundleIntact,
              let executable = Bundle.main.executableURL else { throw Failure.identityMismatch }
        let bundle = Bundle.main.bundleURL.path
        // Only the installed launcher, or the development build inside its own recorded source checkout.
        guard [CodexSplitPaths.installedWorkLauncher, WorkUpdateGuide.sourceRoot.map { $0 + "/.build/CodexSplit-work-standalone.app" }]
                .contains(bundle),
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == bundle,
              executable.path == bundle + "/Contents/MacOS/launcher",
              executable.resolvingSymlinksInPath().path == executable.path,
              let hash = fileDigest(executable.path) else { throw Failure.identityMismatch }
        toolPath = executable.path; toolFingerprint = hash
        plan = .workSetup(requestedAt: Date())
        try ProductionInitialTrial.checkBinaries(plan)
        lease = try AppTrialRootLease.resumeWork(plan)
        directories = try WorkDirectory.snapshot(plan.root)
        store = try PrivateStore(root: plan.root + "/control")
        coordinator = .production(store: store)
        let daily = try coordinator.read()
        // Before the first visit the completed setup's target stands in for the segment.
        let segmentPlan = try daily.segment?.plan ?? store.read().workSetup?.plan
        if let segmentPlan, !WorkDailyState.sameTarget(segmentPlan, plan) || (daily.segment.map { $0.toolFingerprint != hash } ?? false) {
            updateRequired = true // re-verified under the lock by beginUpdate, then by submit
        } else {
            updateRequired = false
            try WorkDailyCoordinator.prerequisites(store.read(), plan: plan, daily: daily)
        }
        var bytes = [CChar](repeating: 0, count: 128)
        guard cs_boot_session(&bytes, 128) == 0 else { throw Failure.processUnknown }
        let boot = String(cString: bytes)
        guard UUID(uuidString: boot) != nil else { throw Failure.processUnknown }
        bootSession = boot
        try verify()
    }
    func verify() throws {
        try verifyRunning()
        try ProductionInitialTrial.checkBinaries(plan)
        try lease.validate(requireEmpty: false)
    }
    // Nothing is launched here, so an on-disk official update must not sever an observed window.
    func verifyRunning() throws {
        try lease.validate(requireEmpty: false)
        guard fileDigest(toolPath) == toolFingerprint,
              try WorkDirectory.snapshot(plan.root) == directories else { throw Failure.identityMismatch }
    }
}

private final class WorkDailyDelegate: NSObject, NSApplicationDelegate {
    private let owner = UUID()
    private var context: WorkDailyContext?
    private var adapter: AppInitialTrialObjectAdapter<NSRunningApplication>?
    private var attemptID: UUID?
    private var generation: WorkProcess?
    private var descriptor: Int32 = -1
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var lastHeartbeat = Date.distantPast
    private var submitting = false
    private var ended = false
    private var failureStage: WorkDailyFailureStage = .finalVerification
    private lazy var startScheduler = WorkDailyStartScheduler { [weak self] in self?.start() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        startScheduler.schedule()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !submitting { startScheduler.schedule() }
        return false
    }
    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "업무"
        let menu = NSMenu()
        for (title, action) in [("상태 확인", #selector(showStatus)), ("앱 업데이트 확인", #selector(showUpdateStatus)), ("계정·개인 앱·프로젝트 확인", #selector(reportUI)),
                                ("업무 앱 정상 종료 준비", #selector(prepareQuit)), ("런처 관측 종료", #selector(stopObserver))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; statusItem = item
    }
    private func message(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "CodexSplit 업무용"
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func consent(_ text: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "CodexSplit 업무용"
        alert.informativeText = text
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: action)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "위 영향과 제한을 이해하고 동의합니다."
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn && alert.suppressionButton?.state == .on
    }
    private func choose(_ text: String, buttons: [String]) -> Int? {
        let alert = NSAlert()
        alert.messageText = "CodexSplit 업무용"
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(response) ? response : nil
    }
    @objc private func showUpdateStatus() {
        message(WorkUpdateInspector.production().inspect().text)
    }
    private func start() {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }
        failureStage = .finalVerification
        var updatePending = false
        do {
            if let context, let adapter, let generation, let attemptID, descriptor >= 0, !ended {
                failureStage = .duplicateActivation
                try requireCurrent(context, adapter: adapter, generation: generation, id: attemptID)
                try context.verifyRunning()
                guard adapter.currentApplicationForObservation.activate(options: []) else { throw Failure.processUnknown }
                if (try? ProductionInitialTrial.checkBinaries(context.plan)) == nil {
                    message("이 업무 창을 연 뒤 공식 앱 파일이 바뀌었거나 확인되지 않습니다. 열린 업무 창은 계속 관측하고 종료하지 않습니다. 종료 후에는 새 버전 검토·설치 승인 전까지 업무 앱을 열지 않습니다.")
                }
                return
            }
            let context = try WorkDailyContext()
            self.context = context
            var state = try context.coordinator.read()
            guard !state.pending else {
                message("업무 실행 중이거나 이전 실행의 종료를 확인하지 못했습니다. 새 앱을 열지 않습니다. 기존 업무 창을 사용하고, 관측이 끊겼다면 기록을 보존한 채 확인을 요청하세요.")
                NSApplication.shared.terminate(nil); return
            }
            if context.updateRequired {
                updatePending = true
                guard try beginUpdate(context) else { NSApplication.shared.terminate(nil); return }
                updatePending = false
                state = try context.coordinator.read()
            }
            if state.grant == nil && state.acceptedCount >= 2 {
                let accepted = consent("이 도구에서 업무 앱 열기·계정/개인 앱/프로젝트 확인·정상 종료를 두 번 완료했습니다. 현재 고정 버전과 기존 업무 root에 한해 이후 더블클릭 실행을 허용할 수 있습니다. 앱 시작은 업무 데이터 갱신·네트워크·공유 OS 인증 저장소 접근과 개인 앱 영향을 일으킬 수 있습니다. 완전한 인증 분리는 보장하지 않습니다. 버전·도구·root 변경 또는 미확인 실행은 차단합니다.", action: "이 버전의 일상 사용 허용")
                guard accepted else { NSApplication.shared.terminate(nil); return }
                try context.verify()
                try context.coordinator.transaction {
                    try WorkDailyCoordinator.prerequisites(context.store.readLocked(), plan: context.plan, daily: $0)
                    try $0.approveNormal(toolFingerprint: context.toolFingerprint, directories: context.directories,
                                         accepted: accepted, now: Date())
                }
                state = try context.coordinator.read()
            }
            let scope: WorkDailyScope = state.grant == nil ? .acceptance : .normal
            let plan = AppInitialTrialPlan.workSetup(requestedAt: Date())
            guard WorkDailyState.sameTarget(context.plan, plan) else { throw Failure.identityMismatch }
            if scope == .acceptance {
                let accepted = consent("기존 업무 로그인과 업무 프로젝트를 유지하여 업무 창 하나를 여는 수용 시험입니다. 로그인·모델 요청·이전 자료 복원·개인 앱 제어는 하지 않습니다. 앱 초기화는 업무 데이터 갱신·네트워크·공유 OS 인증 저장소 접근과 개인 앱 영향을 일으킬 수 있습니다. 완전한 인증 분리는 보장하지 않습니다. 계정·개인 상태·프로젝트를 확인한 뒤 메뉴의 종료 준비 안내를 따라 해당 업무 앱만 직접 종료하세요. 문제가 있으면 기록을 보존하고 자동 재실행하지 않습니다.", action: "업무 창 열기 1회")
                guard accepted else { NSApplication.shared.terminate(nil); return }
            }
            let consentAt = Date()
            let submitted = try context.coordinator.submit(plan: plan, scope: scope, accepted: true, consentAt: consentAt,
                toolFingerprint: context.toolFingerprint, directories: context.directories, owner: owner,
                bootSession: context.bootSession, inspect: { try context.verify() }, open: { permit in
                    self.attemptID = permit.attemptID
                    var stage: WorkDailyFailureStage = .workspaceVerification
                    do {
                        let bound = try ProductionInitialTrial.openVerifiedGUI(permit, onStage: { stage = $0 }, finalCheck: {
                            try context.lease.validate(requireEmpty: false)
                            guard fileDigest(context.toolPath) == context.toolFingerprint,
                                  try WorkDirectory.snapshot(plan.root) == context.directories else { throw Failure.identityMismatch }
                        })
                        self.adapter = bound
                        return bound.receipt
                    } catch { throw WorkDailyOpeningFailure(stage: stage, error: error) }
                }, bind: { receipt in
                    guard let adapter = self.adapter else { throw Failure.processUnknown }
                    let app = adapter.currentApplicationForObservation
                    let before = try WorkProcess.exact(receipt.pid)
                    guard before.matchesScope(receipt), app.processIdentifier == receipt.pid,
                          app.bundleURL?.path == receipt.plan.bundlePath, app.executableURL?.path == receipt.plan.executablePath,
                          app.launchDate == receipt.launchedAt, !app.isTerminated else { throw Failure.processUnknown }
                    let descriptor = cs_observer_bind(before.pid, before.startSeconds, before.startMicroseconds)
                    guard descriptor >= 0 else { throw Failure.processUnknown }
                    self.descriptor = descriptor
                    let after = try WorkProcess.exact(receipt.pid)
                    guard after == before else { throw Failure.processUnknown }
                    self.generation = before
                    return before
                })
            attemptID = submitted.attemptID; generation = submitted.generation
            failureStage = .initialHeartbeat
            try context.coordinator.transaction { try $0.heartbeat(submitted.attemptID, owner: owner, bootSession: context.bootSession, now: Date()) }
            lastHeartbeat = Date()
            statusItem?.button?.title = scope == .acceptance ? "업무 확인" : "업무"
            beginPolling()
        } catch {
            let diagnostic = failureDiagnostic(error, fallback: failureStage)
            markLost(diagnostic: diagnostic)
            if context == nil && diagnostic.reason == .identityMismatch {
                let update = WorkUpdateInspector.production().inspect()
                if update.status == .reviewRequired {
                    offerAutomaticUpdate(update)
                    closeObservation(); NSApplication.shared.terminate(nil); return
                }
                if update.status != .pinned {
                    message(update.summary + "\n" + WorkUpdateGuide.blockedLaunch)
                    closeObservation(); NSApplication.shared.terminate(nil); return
                }
            }
            if updatePending {
                message("이 런처의 검증된 교체 영수증·호환성 검토 기록 또는 공식 앱 검사를 확인하지 못해 새 수용 구간을 시작하지 않았습니다. 업무 앱을 열지 않았고 이전 기록은 그대로입니다. 설치 영수증과 검토 기록 확인을 요청하세요.\n오류 코드: \(diagnostic.reason.rawValue)")
                closeObservation(); NSApplication.shared.terminate(nil); return
            }
            message("업무 앱 실행이나 귀속을 확인하지 못했습니다. 미해결 기록을 보존하고 자동 재실행하지 않습니다. 다른 창을 종료하거나 로그인·인증 삭제로 고치지 마세요.\n단계: \(diagnostic.stage.korean)\n오류 코드: \(diagnostic.reason.rawValue)")
            if descriptor >= 0 && generation != nil && attemptID != nil { beginPolling() }
            else { closeObservation(); NSApplication.shared.terminate(nil) }
        }
    }
    // Only a signed, identifier-verified change reaches here; the script re-verifies everything itself.
    private func offerAutomaticUpdate(_ update: WorkUpdateReport) {
        if WorkUpdateAutomation.running() {
            message("업데이트 자동 대응이 이미 진행 중입니다. 완료 알림을 받은 뒤 런처를 다시 여세요. 업무 기록은 그대로입니다.")
            return
        }
        guard consent(update.summary + "\n\n자동 대응: 서명·pin 재확인, 업무 저장소 분리 표식 정적 점검, 격리 후보 빌드와 전체 시험(10분 안팎) 뒤 이 런처가 닫혀 있으면 백업을 남기고 런처를 교체합니다. 공식 변경 내역은 사람이 검토하지 않습니다. 교체 뒤 새 수용 시험 두 번과 일상 허용을 다시 받아야 하며, 그동안 업무 앱은 열지 않습니다. 실패하면 기존 런처와 기록을 그대로 둡니다.", action: "자동 대응 시작") else { return }
        do {
            try WorkUpdateAutomation.start(consentedAt: Date())
            message("자동 대응을 시작했습니다. 완료나 중단은 알림으로 알려 드립니다. 이 런처는 닫힙니다.")
        } catch {
            message("자동 대응을 시작하지 못했습니다. 업무 기록과 런처는 그대로입니다.\n" + WorkUpdateGuide.blockedLaunch)
        }
    }
    // A verified replacement receipt plus consent opens a fresh acceptance segment; it grants nothing.
    private func beginUpdate(_ context: WorkDailyContext) throws -> Bool {
        let located = try WorkDailyReplacementEvidence.locateInstalled(launcherSHA256: context.toolFingerprint)
        guard let segmentPlan = try context.coordinator.read().segment?.plan ?? context.store.read().workSetup?.plan else { throw Failure.approvalRequired }
        let plan = AppInitialTrialPlan.workSetup(requestedAt: Date())
        let change = WorkDailyState.sameTarget(segmentPlan, plan)
            ? "업무 런처가 검증된 교체 절차로 바뀌었습니다. 공식 앱 \(plan.appVersion)/\(plan.appBuild)는 그대로입니다."
            : "공식 앱이 \(segmentPlan.appVersion)/\(segmentPlan.appBuild)에서 \(plan.appVersion)/\(plan.appBuild)로 바뀌었고, "
                + (located.automatic ? "자동 대응(서명·pin·정적 분리 표식·전체 시험 통과, 사람의 변경 내역 검토 없음)으로" : "호환성 검토(\(located.reviewID ?? "-"))를 거친")
                + " 런처가 설치됐습니다."
        guard consent(change + " 이전 업무 기록은 변경 없이 보존하고 이 런처·버전은 성공 0회에서 다시 시작합니다. 업무 창 열기·계정/개인 앱/프로젝트 확인·정상 종료 수용 시험 두 번과 별도의 일상 사용 허용이 다시 필요합니다. 이전 성공이나 허용은 이어지지 않습니다. 이 동의만으로 앱을 열지는 않습니다.", action: "새 수용 구간 시작") else { return false }
        try context.verify()
        _ = try context.coordinator.beginUpdate(plan: plan, accepted: true, consentAt: Date(), toolFingerprint: context.toolFingerprint,
            directories: context.directories, reviewID: located.reviewID, replacement: located.evidence,
            replacedToolFingerprint: located.replacedLauncherSHA256, inspect: { try context.verify() })
        return true
    }
    private func requireCurrent(_ context: WorkDailyContext, adapter: AppInitialTrialObjectAdapter<NSRunningApplication>,
                                generation: WorkProcess, id: UUID, frontmost: Bool = false) throws {
        let app = adapter.currentApplicationForObservation
        let state = try context.coordinator.read()
        guard let attempt = state.attempts.last, attempt.id == id, attempt.owner == owner,
              attempt.bootSession == context.bootSession, attempt.generation == generation, state.pending,
              attempt.phase == .bound || attempt.phase == .active,
              app.processIdentifier == adapter.receipt.pid, app.launchDate == adapter.receipt.launchedAt,
              app.bundleURL?.path == adapter.receipt.plan.bundlePath, app.executableURL?.path == adapter.receipt.plan.executablePath,
              !app.isTerminated, try WorkProcess.exact(generation.pid) == generation else { throw Failure.processUnknown }
        try context.lease.validate(requireEmpty: false)
        guard try WorkDirectory.snapshot(context.plan.root) == context.directories else { throw Failure.profilePathConflict }
        if frontmost {
            guard let current = NSWorkspace.shared.frontmostApplication, app.isEqual(current) else { throw Failure.processUnknown }
        }
    }
    private func beginPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .eventTracking)
        self.timer = timer
    }
    private func poll() {
        guard let context, let attemptID, let generation, descriptor >= 0 else { return }
        var stage: WorkDailyFailureStage = .observerPoll
        do {
            let result = cs_observer_poll(descriptor, generation.pid)
            guard result >= 0 else { throw Failure.processUnknown }
            if result == 1 {
                try context.lease.validate(requireEmpty: false)
                guard try WorkDirectory.snapshot(context.plan.root) == context.directories else { throw Failure.profilePathConflict }
                stage = .exitPersistence
                try context.coordinator.transaction { try $0.exit(attemptID, generation: generation, owner: owner, bootSession: context.bootSession, now: Date()) }
                ended = true; self.attemptID = nil
                closeObservation(); NSApplication.shared.terminate(nil); return
            }
            if Date().timeIntervalSince(lastHeartbeat) >= 5 {
                let state = try context.coordinator.read()
                if state.attempts.last?.phase != .blocked {
                    stage = .heartbeatVerification
                    guard let adapter else { throw Failure.processUnknown }
                    try requireCurrent(context, adapter: adapter, generation: generation, id: attemptID)
                    stage = .heartbeatPersistence
                    try context.coordinator.transaction { try $0.heartbeat(attemptID, owner: owner, bootSession: context.bootSession, now: Date()) }
                }
                lastHeartbeat = Date()
            }
        } catch {
            let diagnostic = failureDiagnostic(error, fallback: stage)
            markLost(diagnostic: diagnostic); closeObservation()
            message("업무 앱의 종료 관측이 끊겼습니다. 업무 앱은 종료하지 않았으며 미해결 예약을 보존했습니다. 반복 실행하거나 다른 앱을 대신 종료하지 말고 상태 확인을 요청하세요.\n단계: \(diagnostic.stage.korean)\n오류 코드: \(diagnostic.reason.rawValue)")
        }
    }
    @objc private func showStatus() {
        guard !submitting else { return }
        do {
            guard let context else { throw Failure.processUnknown }
            let state = try context.coordinator.read()
            let current = state.pending ? "현재 업무 실행 또는 미확인 종료 기록이 남아 있습니다. 이 런처를 닫아도 업무 앱을 종료하지 않습니다." : "현재 구간의 미해결 예약이 없습니다. 계정 상태는 공식 업무 UI에서 직접 확인하세요."
            var segment = ""
            if let update = state.update {
                segment = "\n현재 구간: " + (update.versionChanged ? "공식 앱 \(update.fromPlan.appVersion)/\(update.fromPlan.appBuild) → \(update.toPlan.appVersion)/\(update.toPlan.appBuild) 업데이트" : "업무 런처 교체")
                    + " 이후 새 수용 \(state.acceptedCount)/2회, 일상 허용 " + (state.grant == nil ? "없음" : "있음") + ". 이전 구간 기록(과거 미확인 실패 기록이 있으면 그 상태 그대로)은 변경 없이 보존됐습니다."
            }
            message(current + segment)
        } catch { message("상태 기록을 확인할 수 없습니다. 새 실행을 보류하고 기존 기록을 보존하세요.") }
    }
    @objc private func reportUI() {
        guard !submitting, let context, let adapter, let generation, let attemptID else { return }
        do {
            try requireCurrent(context, adapter: adapter, generation: generation, id: attemptID, frontmost: true)
            guard let accountChoice = choose("방금 열린 지정 업무 창의 계정 표시를 확인하세요. 비밀번호·인증번호·토큰은 이 창에 입력하지 마세요.", buttons: ["취소", "의도한 업무 계정", "다른 계정", "로그인 필요"]), accountChoice != 0 else { return }
            let account: AppTrialManualAccount = accountChoice == 1 ? .confirmed : (accountChoice == 2 ? .mismatch : .loginRequired)
            var personal: WorkPersonalReport = .unknown
            var projects = false
            if account == .confirmed {
                guard let choice = choose("기존 개인 앱에서 계정·대화 목록·설정에 관찰 가능한 변화가 없는지 직접 확인하세요. 개인 앱을 종료하거나 로그아웃하지 마세요.", buttons: ["취소", "변화 없음", "변화 있음", "확인 불가"]), choice != 0 else { return }
                personal = choice == 1 ? .unchanged : (choice == 2 ? .changed : .unknown)
                if personal == .unchanged {
                    guard let projectChoice = choose("업무 UI의 프로젝트 목록이 이전 방문과 같게 유지되는지 확인하세요. 처음이거나 프로젝트를 쓰지 않으면 '유지됨·해당 없음'을 고르세요. 자료 이전이나 새 모델 요청은 하지 마세요.", buttons: ["취소", "유지됨·해당 없음", "달라짐·확인 불가"]), projectChoice != 0 else { return }
                    projects = projectChoice == 1
                }
            }
            try requireCurrent(context, adapter: adapter, generation: generation, id: attemptID)
            try context.coordinator.transaction { try $0.report(attemptID, account: account, personal: personal, projectsConnected: projects, now: Date()) }
            if account != .confirmed || personal != .unchanged || !projects {
                message("확인 결과가 수용 조건과 다릅니다. 추가 로그인·종료·재실행으로 고치지 말고 기록을 보존해 보고하세요.")
            } else { message("현재 사용자 확인을 저장했습니다. 업무 창을 선택한 뒤 메뉴의 정상 종료 준비를 사용하세요.") }
        } catch { message("지정 업무 창의 귀속 또는 보고 저장을 확인하지 못했습니다. 그 업무 창을 먼저 선택하고 상태를 확인하세요.") }
    }
    @objc private func prepareQuit() {
        guard !submitting, let context, let adapter, let generation, let attemptID else { return }
        do {
            try requireCurrent(context, adapter: adapter, generation: generation, id: attemptID, frontmost: true)
            try context.coordinator.transaction { try $0.quitIntent(attemptID, owner: owner, bootSession: context.bootSession, now: Date()) }
            // 메뉴 선택은 다른 앱을 활성화하지 않는다. 사용자가 지정 업무 앱에서 직접 Cmd-Q한다.
            let alert = NSAlert()
            alert.messageText = "업무 앱 정상 종료 준비 완료"
            alert.informativeText = "확인한 업무 창을 다시 선택한 뒤 그 앱에서만 Cmd-Q하세요. 런처가 앱에 종료 명령을 보내지는 않습니다."
            alert.addButton(withTitle: "확인")
            alert.runModal()
        } catch { message("업무 계정·개인 무변화·프로젝트 유지 보고와 지정 업무 창 선택이 먼저 필요합니다. 다른 창을 종료하지 마세요.") }
    }
    @objc private func stopObserver() {
        if consent("런처 관측만 종료하면 업무 앱은 계속 열려 있을 수 있고 미해결 기록이 남습니다. 다음 더블클릭으로 자동 재실행하지 않습니다.", action: "관측만 종료") { NSApplication.shared.terminate(nil) }
    }
    private func failureDiagnostic(_ error: Error, fallback: WorkDailyFailureStage) -> WorkDailyDiagnostic {
        if let context, let id = attemptID, let state = try? context.coordinator.read(),
           state.attempts.last?.id == id, let recorded = state.attempts.last?.diagnostic { return recorded }
        return WorkDailyDiagnostic(stage: (error as? WorkDailyOpeningFailure)?.stage ?? fallback, error: error, now: Date())
    }
    private func markLost(diagnostic: WorkDailyDiagnostic? = nil) {
        guard !ended, let context, let attemptID else { return }
        let observedAt = Date()
        let detail = diagnostic ?? WorkDailyDiagnostic(stage: .observerStop, error: Failure.processUnknown, now: observedAt)
        try? context.coordinator.transaction {
            try $0.observerLost(attemptID, owner: owner, bootSession: context.bootSession, now: observedAt, diagnostic: detail)
        }
    }
    private func closeObservation() {
        timer?.invalidate(); timer = nil
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        markLost(); closeObservation()
        return .terminateNow
    }
}

@main
struct CodexSplitWorkDailyApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = WorkDailyDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
