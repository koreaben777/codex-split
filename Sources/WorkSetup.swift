import Foundation
import AppKit
import Darwin

// Human reports contain no account identifiers or credentials.
enum WorkPersonalReport: String, Codable { case unchanged, changed, unknown }
struct WorkSetupVerification: Codable {
    let plan: AppInitialTrialPlan
    let checkedAt: Date
    let toolFingerprint: String
    let strictIdentityAndPinsVerified: Bool
}
struct WorkSetupVisit: Codable {
    var session: AppInitialTrialSession
    var personal: WorkPersonalReport?
}
struct WorkSetupRecord: Codable {
    let plan: AppInitialTrialPlan
    let approvedAt: Date
    var launchApprovals: [Date] = []
    var verifications: [WorkSetupVerification] = []
    var visits: [WorkSetupVisit] = []
    var pending = false
    // Flat, immutable prior attempts. Optional preserves decoding of the original record.
    var previousAttempts: [WorkSetupRecord]?
    // Present when an existing profile was moved in by `--adopt`; nil for a fresh setup.
    var adoption: WorkSetupAdoption?
    var canResumeDeferredLogin: Bool {
        !pending && visits.count == 1 && verifications.count == 1 && launchApprovals.count == 1
            && visits[0].session.state == .mainAppExitedAfterQuitIntent
            && visits[0].session.manualAccount == .loginRequired && visits[0].personal == .unchanged
    }
    func sameTarget(as other: AppInitialTrialPlan) -> Bool {
        AppInitialTrialPlan(requestID: other.requestID, requestedAt: other.requestedAt, domain: plan.domain,
            root: plan.root, bundlePath: plan.bundlePath, executablePath: plan.executablePath,
            appVersion: plan.appVersion, appBuild: plan.appBuild, appFingerprint: plan.appFingerprint,
            cliExecutablePath: plan.cliExecutablePath, cliVersion: plan.cliVersion,
            cliBuild: plan.cliBuild, cliFingerprint: plan.cliFingerprint) == other
    }
    var canRestart: Bool { !pending && visits.count == 1 && accepted(visits[0]) }
    var completed: Bool { !pending && visits.count == 2 && visits.allSatisfy(accepted) }
    private func accepted(_ visit: WorkSetupVisit) -> Bool {
        visit.session.state == .mainAppExitedAfterQuitIntent && visit.session.manualAccount == .confirmed && visit.personal == .unchanged
    }
    func valid(now: Date) -> Bool { valid(now: now, archived: false) }
    private func valid(now: Date, archived: Bool) -> Bool {
        guard approvedAt >= plan.requestedAt, approvedAt <= now, safeAbsolutePath(plan.root),
              visits.count <= 2, verifications.count <= 2, launchApprovals.count == verifications.count,
              visits.count <= verifications.count, verifications.count <= visits.count + (pending ? 1 : 0),
              verifications.enumerated().allSatisfy({ i,v in v.plan == plan && v.strictIdentityAndPinsVerified
                  && v.checkedAt >= launchApprovals[i] && v.checkedAt <= now && v.toolFingerprint.count == 64
                  && v.toolFingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) }),
              launchApprovals.allSatisfy({ $0 >= approvedAt && $0 <= now }),
              visits.enumerated().allSatisfy({ i,v in v.session.receipt.plan == plan && v.session.validRecord(now: now)
                  && v.session.receipt.launchedAt >= verifications[i].checkedAt }) else { return false }
        if plan.domain == .production && !plan.isRecordedWorkPlan { return false }
        if let adoption, !adoption.valid(root: plan.root, approvedAt: approvedAt, now: now) || previousAttempts != nil { return false }
        if visits.count == 2 && !accepted(visits[0]) { return false }
        if !pending && visits.contains(where: { $0.session.state != .mainAppExitedAfterQuitIntent }) { return false }
        let history = previousAttempts ?? []
        var ids = Set<UUID>([plan.requestID])
        for (index, prior) in history.enumerated() {
            guard prior.previousAttempts == nil, prior.canResumeDeferredLogin, prior.valid(now: now, archived: true),
                  ids.insert(prior.plan.requestID).inserted else { return false }
            let next = index + 1 < history.count ? history[index + 1] : self
            guard prior.sameTarget(as: next.plan), let ended = prior.visits[0].session.terminationReceipt?.observedAt,
                  next.plan.requestedAt >= ended, next.approvedAt >= prior.approvedAt else { return false }
        }
        return true
    }
}
struct WorkSetupCoordinator {
    let store: PrivateStore
    let now: () -> Date
    private let domain: AppEvidenceDomain
    private init(store: PrivateStore, now: @escaping () -> Date, domain: AppEvidenceDomain) {
        self.store = store; self.now = now; self.domain = domain
    }
    static func synthetic(store: PrivateStore, now: @escaping () -> Date) -> Self { Self(store: store, now: now, domain: .synthetic) }
    fileprivate static func production(store: PrivateStore, now: @escaping () -> Date) -> Self { Self(store: store, now: now, domain: .production) }
    func initialize(plan: AppInitialTrialPlan, approvedAt: Date, adoption: WorkSetupAdoption? = nil) throws {
        guard plan.domain == domain, approvedAt >= plan.requestedAt, approvedAt <= now() else { throw Failure.approvalRequired }
        if domain == .production && plan != .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID) { throw Failure.identityMismatch }
        try store.transaction { state in
            guard state.workSetup == nil, state.pending.isEmpty else { throw Failure.processUnknown }
            var record = WorkSetupRecord(plan: plan, approvedAt: approvedAt)
            record.adoption = adoption
            guard record.valid(now: now()) else { throw Failure.stateInvalid }
            state.workSetup = record
        }
    }
    func resume(expectedPriorPlan: AppInitialTrialPlan, plan: AppInitialTrialPlan, approvedAt: Date) throws {
        guard plan.domain == domain, plan.requestID != expectedPriorPlan.requestID,
              approvedAt >= plan.requestedAt, approvedAt <= now(), now().timeIntervalSince(approvedAt) < 120 else { throw Failure.approvalRequired }
        if domain == .production && plan != .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID) { throw Failure.identityMismatch }
        try store.transaction { state in
            guard var prior = state.workSetup, prior.plan == expectedPriorPlan,
                  prior.canResumeDeferredLogin, prior.valid(now: now()),
                  prior.sameTarget(as: plan), state.pending.isEmpty, (state.appApprovals ?? [:]).isEmpty else { throw Failure.approvalRequired }
            var history = prior.previousAttempts ?? []
            prior.previousAttempts = nil
            history.append(prior)
            var next = WorkSetupRecord(plan: plan, approvedAt: approvedAt)
            next.previousAttempts = history
            guard next.valid(now: now()) else { throw Failure.stateInvalid }
            state.workSetup = next
        }
    }
    // Production supplies real verification/open closures; tests supply only synthetic plans.
    func submit(plan: AppInitialTrialPlan, approval: Date, inspect: () throws -> WorkSetupVerification,
                open: () throws -> AppInitialTrialReceipt) throws -> AppInitialTrialReceipt {
        try store.withLock {
            guard plan.domain == domain else { throw Failure.capabilityUnknown }
            var state = try store.readLocked()
            guard var record = state.workSetup, record.plan == plan, !record.pending,
                  record.visits.isEmpty || record.canRestart,
                  approval >= record.approvedAt, approval <= now(), now().timeIntervalSince(approval) < 120 else { throw Failure.approvalRequired }
            func verified() throws -> WorkSetupVerification {
                let v = try inspect()
                guard v.plan == plan, v.strictIdentityAndPinsVerified, v.checkedAt >= approval,
                      v.checkedAt <= now(), now().timeIntervalSince(v.checkedAt) < 30,
                      v.toolFingerprint.count == 64, v.toolFingerprint.allSatisfy({ "0123456789abcdef".contains($0) }),
                      now().timeIntervalSince(approval) < 120 else { throw Failure.identityMismatch }
                return v
            }
            let before = try verified()
            record.pending = true
            record.launchApprovals.append(approval)
            record.verifications.append(before)
            state.workSetup = record
            try store.writeLocked(state)
            let after = try verified()
            guard before.toolFingerprint == after.toolFingerprint else { throw Failure.identityMismatch }
            record.verifications[record.verifications.count - 1] = after
            state.workSetup = record
            try store.writeLocked(state)
            let receipt = try open()
            guard receipt.matches(plan, now: now()), receipt.launchedAt >= after.checkedAt,
                  !record.visits.contains(where: { $0.session.receipt.instanceToken == receipt.instanceToken }) else { throw Failure.processUnknown }
            record.visits.append(WorkSetupVisit(session: AppInitialTrialSession(receipt: receipt)))
            state.workSetup = record
            try store.writeLocked(state)
            return receipt
        }
    }
    func report(receipt: AppInitialTrialReceipt, account: AppTrialManualAccount, personal: WorkPersonalReport) throws {
        try edit(receipt) { visit in
            try visit.session.observeOwnedUI(receipt, now: now())
            try visit.session.reportAccount(account, for: receipt)
            visit.personal = personal
        }
    }
    func exit(_ termination: AppInitialTrialTerminationReceipt) throws {
        try edit(termination.instance, ended: true) { visit in
            try visit.session.recordObservedMainAppExit(termination, now: now())
        }
    }
    private func edit(_ receipt: AppInitialTrialReceipt, ended: Bool = false, body: (inout WorkSetupVisit) throws -> Void) throws {
        try store.transaction { state in
            guard var record = state.workSetup, record.pending, let last = record.visits.indices.last,
                  record.visits[last].session.receipt == receipt else { throw Failure.processUnknown }
            try body(&record.visits[last])
            if ended { record.pending = false }
            state.workSetup = record
        }
    }
}

enum ProductionWorkSetup {
    enum Mode: Equatable { case setup, resume, adopt(from: String) }
    static func run(_ mode: Mode = .setup) throws {
        let resume = mode == .resume
        try ProductionInitialTrial.requireTerminal()
        let plan = AppInitialTrialPlan.workSetup(requestedAt: Date())
        print("업무 로그인 및 재실행 1회 수용 시험. 일상 사용/설치/모델 요청 승인은 아닙니다.")
        print("업무 저장소: \(plan.root). 재개 시 기존 저장소와 모든 시도 기록을 보존합니다. 개인 자료는 복사하지 않습니다.")
        print("공식 UI에서 사용자가 직접 업무 로그인하며 persistent credential이 저장될 수 있습니다.")
        print("OS 공유 인증 backend/브라우저/네트워크/자동 갱신 및 개인 앱 영향 가능성이 있습니다. 저장이 모두 새 root 안에 한정된다고 보장하지 않습니다.")
        print("기존 계정이 예상 밖으로 나타나면 로그인/로그아웃하지 말고 mismatch로 보고하세요.")
        try ProductionInitialTrial.checkBinaries(plan)
        // Private parent folders for a new profile root; the root itself is created exclusively below.
        for directory in [CodexSplitPaths.support, CodexSplitPaths.support + "/profiles"] where mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw Failure.io
        }
        let lease: AppTrialRootLease
        let store: PrivateStore
        let coordinator: WorkSetupCoordinator
        let approvedAt: Date
        if case .adopt(let source) = mode {
            print("기존 업무 프로필 채택: \(source) → \(plan.root)")
            print("같은 디스크 안에서 이름만 바꿔 옮깁니다(복사·삭제 없음). 이전 control 기록은 \(CodexSplitPaths.support)/legacy에 그대로 보존합니다.")
            print("공식 앱이 내부에 예전 경로를 저장했다면 대화 목록·로그인이 달라질 수 있습니다. 문제가 있으면 기록을 보존하고 docs의 되돌리기 절차를 따르세요.")
            print("업무 앱·런처·관련 helper가 모두 종료돼 있어야 합니다. 실행 중이면 이동하지 않습니다.")
            guard try ProductionInitialTrial.answer("기존 프로필을 옮기고 로그인 유지 확인 방문 2회를 승인하려면 ADOPT work 입력:") == "ADOPT work" else { throw Failure.approvalRequired }
            approvedAt = Date()
            let adoption = try WorkProfileAdopter.production().adopt(from: source, to: plan.root, legacy: CodexSplitPaths.support + "/legacy")
            lease = try AppTrialRootLease.resumeWork(plan)
            store = try PrivateStore(root: plan.root + "/control")
            coordinator = WorkSetupCoordinator.production(store: store, now: Date.init)
            try coordinator.initialize(plan: plan, approvedAt: approvedAt, adoption: adoption)
            print("이동 완료. 이전 기록: \(adoption.legacyControl ?? "없음"). 이전 위치는 새 위치를 가리키는 링크로 남겼습니다(이동 전 대화용, 지우지 마세요).")
        } else if resume {
            lease = try AppTrialRootLease.resumeWork(plan)
            store = try PrivateStore(root: plan.root + "/control")
            coordinator = WorkSetupCoordinator.production(store: store, now: Date.init)
            guard let prior = try store.read().workSetup, prior.canResumeDeferredLogin, prior.sameTarget(as: plan) else { throw Failure.approvalRequired }
            print("조직의 로그인 정책을 우회하지 않습니다. 정상 로그인이 가능한 환경에서만 진행하세요.")
            guard try ProductionInitialTrial.answer("기존 업무 저장소에서 새 로그인·종료·재실행 시험을 승인하려면 RESUME LOGIN work 입력:") == "RESUME LOGIN work" else { throw Failure.approvalRequired }
            approvedAt = Date()
            try lease.validate(requireEmpty: false)
            try coordinator.resume(expectedPriorPlan: prior.plan, plan: plan, approvedAt: approvedAt)
        } else {
            guard try ProductionInitialTrial.answer("이 범위의 사용자 직접 로그인·종료·재실행 1회를 승인하려면 LOGIN work 입력:") == "LOGIN work" else { throw Failure.approvalRequired }
            approvedAt = Date()
            lease = try AppTrialRootLease.production(plan)
            store = try PrivateStore(root: plan.root + "/control")
            coordinator = WorkSetupCoordinator.production(store: store, now: Date.init)
            try coordinator.initialize(plan: plan, approvedAt: approvedAt)
        }
        let toolPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        guard let toolHash = fileDigest(toolPath) else { throw Failure.identityMismatch }
        for index in 0..<2 {
            let approval: Date
            if index == 0 { approval = approvedAt }
            else {
                guard try store.read().workSetup?.canRestart == true else { throw Failure.approvalRequired }
                guard try ProductionInitialTrial.answer("업무 계정 확인·개인 계정 유지·첫 메인 앱 종료 기록됨. 같은 새 업무 저장소 재실행 1회는 REOPEN work 입력:") == "REOPEN work" else { throw Failure.approvalRequired }
                approval = Date()
            }
            var adapter: AppInitialTrialObjectAdapter<NSRunningApplication>?
            let receipt = try coordinator.submit(plan: plan, approval: approval, inspect: {
                try ProductionInitialTrial.requireTerminal()
                try lease.validate(requireEmpty: mode == .setup && index == 0)
                try ProductionInitialTrial.checkBinaries(plan)
                guard fileDigest(toolPath) == toolHash else { throw Failure.identityMismatch }
                try lease.validate(requireEmpty: mode == .setup && index == 0)
                return WorkSetupVerification(plan: plan, checkedAt: Date(), toolFingerprint: toolHash, strictIdentityAndPinsVerified: true)
            }, open: {
                try lease.validate(requireEmpty: mode == .setup && index == 0)
                let bound = try ProductionInitialTrial.openVerified(plan, consentExpiresAt: approval.addingTimeInterval(120), finalCheck: {
                    try lease.validate(requireEmpty: mode == .setup && index == 0)
                    guard fileDigest(toolPath) == toolHash else { throw Failure.identityMismatch }
                })
                adapter = bound
                return bound.receipt
            })
            guard let adapter else { throw Failure.processUnknown }
            print("새 업무 객체 PID \(receipt.pid). 30초 안에 새 창을 클릭해 귀속을 확인하세요."); fflush(stdout)
            try ProductionInitialTrial.pump(until: { adapter.matchesFrontmost(NSWorkspace.shared.frontmostApplication, now: Date()) }, seconds: 30)
            if index == 0 {
                print(mode == .setup ? "LOGIN READY — 식별된 업무 창의 공식 UI에서 직접 업무 로그인하세요. 암호/토큰은 Terminal에 입력하지 마세요."
                    : "READY — 식별된 업무 창에서 기존 업무 로그인·대화·프로젝트가 유지되는지 확인하세요. 로그인이 풀렸다면 이 창의 공식 UI에서 직접 로그인할 수 있습니다. 암호/토큰은 Terminal에 입력하지 마세요.")
            } else { print("재실행 계정 유지 확인만 하세요. 재로그인이 필요하면 loginRequired; 여기서 재로그인하지 마세요.") }
            print("업무 앱 계정 표시를 확인하고 기존 개인 앱도 직접 확인하세요. 개인 앱을 종료/로그아웃하지 마세요.")
            let accountText = try ProductionInitialTrial.answer("업무 창 확인 결과: confirmed / mismatch / loginRequired:")
            guard let account = AppTrialManualAccount(rawValue: accountText) else { throw Failure.approvalRequired }
            guard account != .mismatch else {
                print("업무 계정 mismatch: 즉시 중단합니다. 추가 로그인/종료/재실행 없이 pending과 저장소를 보존합니다.")
                throw Failure.approvalRequired
            }
            let personalText = try ProductionInitialTrial.answer("개인 앱의 기존 계정·대화 목록·설정에 관찰 가능한 변화가 없는지 직접 확인: unchanged / changed / unknown:")
            guard let personal = WorkPersonalReport(rawValue: personalText), personal == .unchanged else {
                print("개인 앱 changed/unknown: 즉시 중단합니다. 앱 조작 없이 pending과 저장소를 보존합니다.")
                throw Failure.approvalRequired
            }
            print("30초 안에 방금 확인한 업무 창을 다시 선택하세요."); fflush(stdout)
            try ProductionInitialTrial.pump(until: { adapter.matchesFrontmost(NSWorkspace.shared.frontmostApplication, now: Date()) }, seconds: 30)
            let owned = try adapter.observeOwnedUI(frontmost: NSWorkspace.shared.frontmostApplication, userConfirmed: true, now: Date())
            try coordinator.report(receipt: owned, account: account, personal: personal)
            guard try ProductionInitialTrial.answer("Terminal을 보이게 둡니다. QUIT 입력 → 업무 창 클릭 → READY까지 대기. 아직 Cmd-Q 금지:") == "QUIT" else { throw Failure.approvalRequired }
            try ProductionInitialTrial.pump(until: { adapter.matchesFrontmost(NSWorkspace.shared.frontmostApplication, now: Date()) }, seconds: 30)
            try adapter.recordUserQuitIntent(frontmost: NSWorkspace.shared.frontmostApplication, now: Date())
            print("\u{7}READY — 이제 식별된 업무 창에서 Cmd-Q. 같은 메인 앱 종료를 30초 관측합니다."); fflush(stdout)
            var exitReceipt: AppInitialTrialTerminationReceipt?
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while exitReceipt == nil {
                exitReceipt = try adapter.observeTermination(now: Date())
                if exitReceipt != nil { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.processUnknown }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            try coordinator.exit(exitReceipt!)
            guard account == .confirmed, personal == .unchanged else {
                print("보고가 성공 기준과 다릅니다. 자동 재실행/로그아웃/삭제 없이 기록과 업무 저장소를 보존합니다.")
                throw Failure.approvalRequired
            }
        }
        guard try store.read().workSetup?.completed == true else { throw Failure.stateInvalid }
        print("업무 계정/개인 계정 유지의 사용자 보고 및 두 메인 앱 종료를 기록했습니다. 저장소는 보존합니다. 설치/일상 사용/완전 격리 승인은 아닙니다.")
    }
}
