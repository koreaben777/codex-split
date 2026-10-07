import Foundation
import Darwin

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("실패: " + label); exit(1) }
}
func rejected(_ label: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); print("실패: " + label); exit(1) } catch {}
}
let time = Date(timeIntervalSince1970: 1_790_000_000)
let hash = String(repeating: "a", count: 64)
let owner = UUID()
let boot = UUID().uuidString
let roots = Dictionary(uniqueKeysWithValues: ["", "codex", "desktop", "cwd", "control"].enumerated().map {
    ($0.element, WorkDirectory(device: 1, inode: UInt64($0.offset + 1)))
})
func plan(_ at: Date = time) -> AppInitialTrialPlan {
    AppInitialTrialPlan(requestID: UUID(), requestedAt: at, domain: .synthetic, root: "/synthetic/work",
        bundlePath: "/synthetic/App.app", executablePath: "/synthetic/App.app/Contents/MacOS/App",
        appVersion: "fake", appBuild: "1", appFingerprint: "fake",
        cliExecutablePath: "/synthetic/App.app/Contents/MacOS/cli", cliVersion: "fake", cliBuild: "1", cliFingerprint: "fake")
}
func reserve(_ state: inout WorkDailyState, _ p: AppInitialTrialPlan, _ consent: Bool = true, _ scope: WorkDailyScope = .acceptance) throws -> UUID {
    try state.reserve(plan: p, scope: scope, consentAccepted: consent, toolFingerprint: hash, directories: roots,
                      owner: owner, bootSession: boot, now: p.requestedAt)
}
func bind(_ state: inout WorkDailyState, _ id: UUID, _ p: AppInitialTrialPlan) throws -> WorkProcess {
    let receipt = AppInitialTrialReceipt(plan: p, instanceToken: UUID(), pid: 123, launchedAt: p.requestedAt, source: .newLaunchCompletion)
    let generation = WorkProcess(pid: 123, uid: getuid(), startSeconds: 1, startMicroseconds: 2, executable: p.executablePath)
    try state.bind(id, receipt: receipt, generation: generation, owner: owner, bootSession: boot, now: p.requestedAt)
    return generation
}
var state = WorkDailyState()
let p = plan()
rejected("취소는 예약을 만들지 않음") { _ = try reserve(&state, p, false) }
check(state.attempts.isEmpty, "취소 후 빈 기록")
let id = try reserve(&state, p)
check(state.pending, "실행 전 영속 예약 필요")
rejected("중복 클릭 차단") { _ = try reserve(&state, plan()) }
rejected("승인 없는 일상 실행 차단") { var fresh = WorkDailyState(); _ = try reserve(&fresh, plan(), true, .normal) }
let generation = try bind(&state, id, p)
check(state.pending, "완료 객체 바인딩만으로 예약 해제 안 함")
try state.heartbeat(id, owner: owner, bootSession: boot, now: time)
check(state.isFresh(owner: owner, bootSession: boot, now: time.addingTimeInterval(14)), "현재 관측 세션")
check(!state.isFresh(owner: owner, bootSession: boot, now: time.addingTimeInterval(16)), "heartbeat 만료")
check(!state.isFresh(owner: owner, bootSession: UUID().uuidString, now: time), "재부팅 뒤 관측 미확인")
check(!state.isFresh(owner: UUID(), bootSession: boot, now: time), "다른 관측 세션")
rejected("다른 세대 종료 차단") {
    let wrong = WorkProcess(pid: 123, uid: getuid(), startSeconds: 9, startMicroseconds: 2, executable: p.executablePath)
    try state.exit(id, generation: wrong, owner: owner, bootSession: boot, now: time)
}
try state.report(id, account: .confirmed, personal: .unchanged, projectsConnected: true, now: time)
try state.quitIntent(id, owner: owner, bootSession: boot, now: time)
try state.exit(id, generation: generation, owner: owner, bootSession: boot, now: time.addingTimeInterval(1))
check(!state.pending, "정확한 메인 종료 뒤 예약 해제")
check(state.acceptedCount == 1, "첫 GUI 수용 보고")
rejected("한 번의 수용으로 일상 승인 불가") { try state.approveNormal(toolFingerprint: hash, directories: roots, accepted: true, now: time.addingTimeInterval(2)) }
var changedAcceptance = roots
changedAcceptance["desktop"] = WorkDirectory(device: 1, inode: 88)
rejected("수용 시험 사이 디렉터리 교체 차단") {
    _ = try state.reserve(plan: plan(time.addingTimeInterval(2)), scope: .acceptance, consentAccepted: true,
        toolFingerprint: hash, directories: changedAcceptance, owner: owner, bootSession: boot, now: time.addingTimeInterval(2))
}
rejected("수용 시험 사이 도구 교체 차단") {
    _ = try state.reserve(plan: plan(time.addingTimeInterval(2)), scope: .acceptance, consentAccepted: true,
        toolFingerprint: String(repeating: "b", count: 64), directories: roots, owner: owner, bootSession: boot, now: time.addingTimeInterval(2))
}
let p2 = plan(time.addingTimeInterval(3))
let id2 = try reserve(&state, p2)
let generation2 = try bind(&state, id2, p2)
try state.heartbeat(id2, owner: owner, bootSession: boot, now: p2.requestedAt)
try state.report(id2, account: .confirmed, personal: .unchanged, projectsConnected: true, now: p2.requestedAt)
try state.quitIntent(id2, owner: owner, bootSession: boot, now: p2.requestedAt)
try state.exit(id2, generation: generation2, owner: owner, bootSession: boot, now: p2.requestedAt.addingTimeInterval(1))
check(state.acceptedCount == 2, "두 번째 GUI 수용 보고")
var lostCredit = state
lostCredit.attempts[0].observerLostAt = time
check(lostCredit.acceptedCount == 1, "관측 소실 기록은 수용 성공에 포함하지 않음")
var noHeartbeatCredit = state
noHeartbeatCredit.attempts[1].heartbeatAt = nil
check(noHeartbeatCredit.acceptedCount == 1, "관측 준비 없는 기록은 수용 성공에 포함하지 않음")
rejected("일상 승인 취소") { try state.approveNormal(toolFingerprint: hash, directories: roots, accepted: false, now: time.addingTimeInterval(5)) }
check(state.grant == nil, "취소 후 승인 없음")
try state.approveNormal(toolFingerprint: hash, directories: roots, accepted: true, now: time.addingTimeInterval(5))
check(state.grant != nil, "수용 뒤 별도 일상 승인")
let normal = plan(time.addingTimeInterval(6))
let normalID = try reserve(&state, normal, true, .normal)
let normalGeneration = try bind(&state, normalID, normal)
try state.observerLost(normalID, owner: owner, bootSession: boot, now: normal.requestedAt)
check(state.pending, "관측 세션 소실 뒤 예약 보존")
rejected("소실 뒤 자동 재실행 차단") { _ = try reserve(&state, plan(time.addingTimeInterval(7)), true, .normal) }
try state.exit(normalID, generation: normalGeneration, owner: owner, bootSession: boot, now: time.addingTimeInterval(8))
check(!state.pending, "바인딩된 실제 종료만 해제")
var changed = roots
changed[""] = WorkDirectory(device: 1, inode: 77)
rejected("root 교체 시 승인 차단") {
    _ = try state.reserve(plan: plan(time.addingTimeInterval(9)), scope: .normal, consentAccepted: true,
        toolFingerprint: hash, directories: changed, owner: owner, bootSession: boot, now: time.addingTimeInterval(9))
}
rejected("도구 교체 시 승인 차단") {
    _ = try state.reserve(plan: plan(time.addingTimeInterval(9)), scope: .normal, consentAccepted: true,
        toolFingerprint: String(repeating: "b", count: 64), directories: roots, owner: owner, bootSession: boot, now: time.addingTimeInterval(9))
}
var unknown = WorkDailyState()
let unknownP = plan()
let unknownID = try reserve(&unknown, unknownP)
try unknown.observerLost(unknownID, owner: owner, bootSession: boot, now: time)
check(unknown.pending, "실행 결과 불명확 시 예약 보존")
rejected("바인딩 없는 종료 기록 차단") { try unknown.exit(unknownID, generation: generation, owner: owner, bootSession: boot, now: time) }
// 관측 없이 끝난 실행: 커널 증명이 있을 때만 '종료 미관측'으로 닫고, 수용 성공으로 세지 않는다.
var stale = WorkDailyState()
let staleP = plan()
let staleID = try reserve(&stale, staleP)
let staleGeneration = try bind(&stale, staleID, staleP)
try stale.heartbeat(staleID, owner: owner, bootSession: boot, now: time)
try stale.report(staleID, account: .confirmed, personal: .unchanged, projectsConnected: true, now: time)
try stale.quitIntent(staleID, owner: owner, bootSession: boot, now: time)
check(stale.unobservedExit(bootSession: boot, exited: { _ in false }) == nil, "실행 중인 세대는 닫지 않음")
check(stale.unobservedExit(bootSession: boot, exited: { _ in nil }) == nil, "확인 불가 세대는 닫지 않음")
check(stale.unobservedExit(bootSession: UUID().uuidString, exited: { _ in nil }) == .otherBoot, "다른 부팅이면 종료 증명")
check(stale.unobservedExit(bootSession: UUID().uuidString, exited: { _ in false }) == nil, "부팅 ID가 달라도 같은 세대가 살아 있으면 닫지 않음")
rejected("증명 없는 닫기 거부") { var copy = stale; try copy.closeUnobserved(staleID, bootSession: boot, exited: { _ in nil }, now: time.addingTimeInterval(1)) }
rejected("다른 실행 닫기 거부") { var copy = stale; try copy.closeUnobserved(UUID(), bootSession: boot, exited: { _ in true }, now: time.addingTimeInterval(1)) }
try stale.closeUnobserved(staleID, bootSession: boot, exited: { $0 == staleGeneration }, now: time.addingTimeInterval(1))
check(!stale.pending && stale.attempts[0].resolution == .processGone && stale.acceptedCount == 0, "닫힌 실행은 미해결도 수용 성공도 아님")
rejected("닫힌 실행을 종료 관측으로 바꾸지 않음") { try stale.exit(staleID, generation: staleGeneration, owner: owner, bootSession: boot, now: time.addingTimeInterval(2)) }
let staleNext = try reserve(&stale, plan(time.addingTimeInterval(2)))
check(stale.attempts.last?.id == staleNext, "닫은 뒤 다음 수용 예약 가능")
let staleJSON = try JSONEncoder().encode(stale)
check(try WorkDailyState.decode(staleJSON, now: time.addingTimeInterval(3)).attempts[0].phase == .exitUnobserved, "종료 미관측 기록 왕복")
var staleObject = try JSONSerialization.jsonObject(with: staleJSON) as! [String: Any]
var staleEntries = staleObject["attempts"] as! [[String: Any]]
staleEntries[0]["resolution"] = nil
staleObject["attempts"] = staleEntries
rejected("근거 없는 종료 미관측 거부") { _ = try WorkDailyState.decode(JSONSerialization.data(withJSONObject: staleObject), now: time.addingTimeInterval(3)) }
var forged = stale
forged.attempts[0].generation = nil; forged.attempts[0].phase = .exitUnobserved
check(!forged.valid(now: time.addingTimeInterval(3)), "세대 없는 processGone 기록 거부")
forged = stale
forged.attempts[0].resolvedAt = time.addingTimeInterval(-1)
check(!forged.valid(now: time.addingTimeInterval(3)), "실행 전 시각의 종료 미관측 거부")
var unbound = WorkDailyState()
let unboundID = try reserve(&unbound, plan())
try unbound.observerLost(unboundID, owner: owner, bootSession: boot, now: time)
check(unbound.unobservedExit(bootSession: boot, exited: { _ in true }) == nil, "세대 연결 전 실패는 같은 부팅에서 닫지 않음")
check(unbound.unobservedExit(bootSession: UUID().uuidString, exited: { _ in nil }) == .otherBoot, "세대 연결 전 실패도 재시동 뒤 닫기 가능")
var refusedReport = WorkDailyState()
let refusedP = plan()
let refusedID = try reserve(&refusedReport, refusedP)
_ = try bind(&refusedReport, refusedID, refusedP)
try refusedReport.report(refusedID, account: .mismatch, personal: .unknown, projectsConnected: false, now: time)
check(refusedReport.unobservedExit(bootSession: UUID().uuidString, exited: { _ in true }) == nil, "거부된 보고는 닫기로 우회하지 않음")
let me = try WorkProcess.exact(getpid())
check(me.exited == false, "살아 있는 세대는 종료로 보지 않음")
check(WorkProcess(pid: me.pid, uid: me.uid, startSeconds: me.startSeconds + 1, startMicroseconds: me.startMicroseconds, executable: me.executable).exited == true,
      "같은 pid의 다른 시작 시각은 이전 세대 종료 증명")
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
try child.run(); child.waitUntilExit()
check(WorkProcess(pid: child.processIdentifier, uid: me.uid, startSeconds: 1, startMicroseconds: 0, executable: "/usr/bin/true").exited == true, "회수된 프로세스는 종료 증명")
let encoded = try JSONEncoder().encode(state)
check(try WorkDailyState.decode(encoded, now: time.addingTimeInterval(10)).grant != nil, "별도 기록 왕복")
var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
var entries = object["attempts"] as! [[String: Any]]
entries[0]["unexpected"] = "비공개 값"
object["attempts"] = entries
rejected("중첩 알 수 없는 필드 거부") { _ = try WorkDailyState.decode(JSONSerialization.data(withJSONObject: object), now: time.addingTimeInterval(10)) }
let duplicate = Data("{\"schemaVersion\":1,\"schemaVersion\":1,\"attempts\":[]}".utf8)
rejected("중복 JSON 키 거부") { _ = try WorkDailyState.decode(duplicate, now: time) }
var wrongGrant = state
wrongGrant.attempts[2] = WorkDailyAttempt(id: UUID(), plan: normal, scope: .normal, approvedAt: normal.requestedAt,
    toolFingerprint: String(repeating: "b", count: 64), directories: roots, owner: owner, bootSession: boot)
check(!wrongGrant.valid(now: time.addingTimeInterval(10)), "일상 기록과 승인 binding 일치")
let fm = FileManager.default
let fixture = fm.currentDirectoryPath + "/.test-data/work-daily-" + UUID().uuidString
try fm.createDirectory(atPath: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: fixture) }
let store = try PrivateStore(root: fixture)
try store.withLock { try store.writeLocked(SavedState()) }
let original = try Data(contentsOf: URL(fileURLWithPath: fixture + "/state.json"))
let coordinator = WorkDailyCoordinator.synthetic(store: store, now: { time.addingTimeInterval(10) })
try coordinator.transaction { $0 = state }
check(try coordinator.read().grant != nil, "별도 저장소 기록 읽기")
check(try Data(contentsOf: URL(fileURLWithPath: fixture + "/state.json")) == original, "원래 시험 기록 바이트 보존")
rejected("같은 control 잠금 경합") { try store.withLock { _ = try coordinator.read() } }
let production = WorkDailyCoordinator.production(store: store)
rejected("production에서 합성 기록 거부") { _ = try production.read() }
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture + "/work-daily.json")
rejected("잘못된 별도 기록 권한") { _ = try coordinator.read() }
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture + "/work-daily.json")
try fm.removeItem(atPath: fixture + "/work-daily.json")
try fm.createSymbolicLink(atPath: fixture + "/work-daily.json", withDestinationPath: fixture + "/state.json")
rejected("별도 기록 심볼릭 링크 거부") { _ = try coordinator.read() }
check(try Data(contentsOf: URL(fileURLWithPath: fixture + "/state.json")) == original, "링크 거부 후 원래 기록 보존")
try fm.removeItem(atPath: fixture + "/work-daily.json")
var opened = 0
rejected("실행 취소 시 callback 없음") {
    _ = try coordinator.submit(plan: plan(), scope: .acceptance, accepted: false, toolFingerprint: hash,
        directories: roots, owner: owner, bootSession: boot, inspect: {}, open: { _ in opened += 1; throw Failure.io }, bind: { _ in generation })
}
check(try (opened == 0 && coordinator.read().attempts.isEmpty), "취소 후 기록 없음")
rejected("최종 실행 검사 실패 시 예약 보존") {
    var inspection = 0
    _ = try coordinator.submit(plan: plan(time.addingTimeInterval(10)), scope: .acceptance, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {
            inspection += 1; if inspection == 2 { throw Failure.identityMismatch }
        }, open: { _ in opened += 1; throw Failure.io }, bind: { _ in generation })
}
check(try (opened == 0 && coordinator.read().pending), "검사 오류는 자동 재실행 허가가 아님")
try fm.removeItem(atPath: fixture + "/work-daily.json")
let submittedPlan = plan(time.addingTimeInterval(10))
let submitted = try coordinator.submit(plan: submittedPlan, scope: .acceptance, accepted: true,
    toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {}, open: { permit in
        opened += 1
        let stored = try WorkDailyState.decode(Data(contentsOf: URL(fileURLWithPath: fixture + "/work-daily.json")), now: time.addingTimeInterval(10))
        check(stored.pending && stored.attempts.last?.id == permit.attemptID, "실제 callback 전에 예약 저장")
        rejected("합성 permit은 실제 GUI 실행에 사용 불가") { try permit.validateProduction(now: time.addingTimeInterval(10)) }
        rejected("실제 GUI leaf도 합성 permit 거부") { _ = try ProductionInitialTrial.openVerifiedGUI(permit, finalCheck: {}) }
        return AppInitialTrialReceipt(plan: submittedPlan, instanceToken: UUID(), pid: 123, launchedAt: time.addingTimeInterval(10), source: .newLaunchCompletion)
    }, bind: { receipt in
        WorkProcess(pid: receipt.pid, uid: getuid(), startSeconds: 1, startMicroseconds: 2, executable: receipt.plan.executablePath)
    })
check(submitted.receipt.plan == submittedPlan && opened == 1, "정확한 완료 객체와 실행 1회")
rejected("순차 중복 클릭 callback 차단") {
    _ = try coordinator.submit(plan: plan(time.addingTimeInterval(10)), scope: .acceptance, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {}, open: { _ in opened += 1; throw Failure.io }, bind: { _ in generation })
}
check(opened == 1, "두 번째 공식 실행 없음")
var expired = WorkDailyState()
let expiredPlan = plan(time.addingTimeInterval(-130))
rejected("GUI 동의는 120초 이후 실행 허가가 아님") {
    _ = try expired.reserve(plan: expiredPlan, scope: .acceptance, consentAccepted: true, consentAt: time.addingTimeInterval(-121),
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, now: time)
}
check(expired.attempts.isEmpty, "만료된 동의로 예약 생성 안 함")
// 실제 프로필과 무관한 fixture에서 256회 이후에도 종료 증거를 보존한다.
try fm.removeItem(atPath: fixture + "/work-daily.json")
var clock = time.addingTimeInterval(20)
let repeated = WorkDailyCoordinator.synthetic(store: store, now: { clock })
try repeated.transaction { $0 = state }
for _ in 0..<270 {
    let next = plan(clock)
    let submission = try repeated.submit(plan: next, scope: .normal, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {},
        open: { _ in AppInitialTrialReceipt(plan: next, instanceToken: UUID(), pid: 123, launchedAt: clock, source: .newLaunchCompletion) },
        bind: { receipt in WorkProcess(pid: receipt.pid, uid: getuid(), startSeconds: 1, startMicroseconds: 2, executable: receipt.plan.executablePath) })
    clock = clock.addingTimeInterval(1)
    try repeated.transaction { try $0.exit(submission.attemptID, generation: submission.generation, owner: owner, bootSession: boot, now: clock) }
}
let finalDaily = try repeated.read()
check(!finalDaily.pending && finalDaily.attempts.count < 128, "270회 이후에도 안전한 일상 실행 가능")
check(finalDaily.acceptedCount == 2 && finalDaily.grant != nil, "정리 후 수용 증거와 승인 보존")
let archives = try fm.contentsOfDirectory(atPath: fixture).filter { $0.hasPrefix("work-daily-history-") }
check(archives.count == 2, "완료 기록은 두 불변 묶음으로 보존")
let archiveData = try Data(contentsOf: URL(fileURLWithPath: fixture + "/" + archives[0]))
let archiveState = try WorkDailyState.decode(archiveData, now: clock)
check(!archiveState.pending && archiveState.attempts.count == 128, "보존 묶음에도 정확한 종료 증거 유지")
let archiveID = archiveState.attempts.last!.id
try store.withLock { try store.archiveWorkDailyLocked(archiveData, id: archiveID) }
rejected("보존 기록을 다른 내용으로 교체하지 않음") {
    try store.withLock { try store.archiveWorkDailyLocked(Data("{}".utf8), id: archiveID) }
}
check(try Data(contentsOf: URL(fileURLWithPath: fixture + "/state.json")) == original, "270회 실행 뒤 원래 시험 기록 보존")
try repeated.transaction { $0 = archiveState }
let archivePath = fixture + "/work-daily-history-" + archiveID.uuidString + ".json"
try Data("{}".utf8).write(to: URL(fileURLWithPath: archivePath))
var failedOpenCount = 0
rejected("보존 충돌 시 새 실행 전 차단") {
    _ = try repeated.submit(plan: plan(clock), scope: .normal, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {},
        open: { _ in failedOpenCount += 1; throw Failure.io }, bind: { _ in generation })
}
check(try failedOpenCount == 0 && repeated.read().attempts.count == 128, "보존 실패 뒤 현재 기록과 실행 횟수 유지")
try Data(archiveData).write(to: URL(fileURLWithPath: archivePath))
try repeated.transaction { $0 = WorkDailyState() }
let failedBindPlan = plan(clock)
rejected("실행 완료 후 관측 등록 실패") {
    _ = try repeated.submit(plan: failedBindPlan, scope: .acceptance, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {},
        open: { _ in AppInitialTrialReceipt(plan: failedBindPlan, instanceToken: UUID(), pid: 123, launchedAt: clock, source: .newLaunchCompletion) },
        bind: { _ in throw Failure.io })
}
let failedBindState = try repeated.read()
check(failedBindState.pending && failedBindState.attempts.last?.receipt != nil && failedBindState.attempts.last?.phase == .blocked, "관측 등록 실패 뒤 완료 객체와 예약 보존")
let failedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(failedBindState)) as! [String: Any]
let failedAttemptJSON = (failedJSON["attempts"] as! [[String: Any]]).last!
let bindDiagnostic = failedAttemptJSON["diagnostic"] as? [String: Any]
check(bindDiagnostic?["stage"] as? String == "kernelBinding" && bindDiagnostic?["reason"] as? String == Failure.io.rawValue, "관측 등록 실패 단계와 허용 오류 코드 저장")
clock = clock.addingTimeInterval(1)
try repeated.transaction {
    try $0.observerLost(failedBindState.attempts.last!.id, owner: owner, bootSession: boot, now: clock,
        diagnostic: WorkDailyDiagnostic(stage: .observerStop, error: Failure.processUnknown, now: clock))
}
check(try repeated.read().attempts.last?.diagnostic?.stage == .kernelBinding, "런처 종료가 최초 실패 단계를 덮어쓰지 않음")
var badDiagnosticJSON = failedJSON
var badAttempts = badDiagnosticJSON["attempts"] as! [[String: Any]]
var badDiagnostic = badAttempts[0]["diagnostic"] as! [String: Any]
badDiagnostic["rawMessage"] = "원시 오류 메시지"
badAttempts[0]["diagnostic"] = badDiagnostic
badDiagnosticJSON["attempts"] = badAttempts
rejected("진단 허용목록 밖 원시 메시지 거부") {
    _ = try WorkDailyState.decode(JSONSerialization.data(withJSONObject: badDiagnosticJSON), now: clock)
}
try repeated.transaction { $0 = WorkDailyState() }
rejected("완료 콜백 단계 오류 회귀") {
    _ = try repeated.submit(plan: plan(clock), scope: .acceptance, accepted: true,
        toolFingerprint: hash, directories: roots, owner: owner, bootSession: boot, inspect: {},
        open: { _ in throw WorkDailyOpeningFailure(stage: .workspaceCompletion, error: NSError(domain: "synthetic", code: 7, userInfo: [NSLocalizedDescriptionKey: "원시 오류 메시지"])) },
        bind: { _ in generation })
}
let completionFailure = try repeated.read()
check(completionFailure.pending && completionFailure.attempts.last?.receipt == nil && completionFailure.attempts.last?.diagnostic?.stage == .workspaceCompletion, "완료 실패 시 예약·단계 보존, PID 추정 없음")
check(completionFailure.attempts.last?.diagnostic?.reason == .processUnknown, "외부 오류 내용 대신 허용 enum만 저장")
check(!String(data: try JSONEncoder().encode(completionFailure), encoding: .utf8)!.contains("원시 오류 메시지"), "원시 외부 오류는 기록에 포함하지 않음")
let legacyBlocked = try WorkDailyState.decode(JSONEncoder().encode(unknown), now: clock)
check(legacyBlocked.pending && legacyBlocked.attempts.last?.diagnostic == nil && legacyBlocked.attempts.last?.receipt == nil, "기존 진단 없는 blocked 기록을 변경 없이 읽기")
let sourceName = "publish-source.tmp"
let destinationName = "publish-final.json"
try Data("first".utf8).write(to: URL(fileURLWithPath: fixture + "/" + sourceName))
let directoryFD = open(fixture, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
guard directoryFD >= 0 else { throw Failure.io }
defer { close(directoryFD) }
check(cs_rename_exclusive(directoryFD, sourceName, destinationName) == 0, "불변 기록을 배타적 원자 이동으로 게시")
var publishedInfo = stat()
check(lstat(fixture + "/" + destinationName, &publishedInfo) == 0 && publishedInfo.st_nlink == 1 && !fm.fileExists(atPath: fixture + "/" + sourceName), "게시 직후 단일 링크만 존재")
try Data("second".utf8).write(to: URL(fileURLWithPath: fixture + "/" + sourceName))
check(cs_rename_exclusive(directoryFD, sourceName, destinationName) != 0, "배타 게시 충돌은 기존 파일을 교체하지 않음")
check(try Data(contentsOf: URL(fileURLWithPath: fixture + "/" + destinationName)) == Data("first".utf8), "게시 충돌 뒤 기존 내용 보존")
print("\(checks)개 업무 GUI 상태 전이 검사 통과 (합성 데이터만 사용)")
