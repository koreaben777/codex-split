import Foundation
import Darwin

// Synthetic fixture only: no official app, installed launcher or work profile is read.
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("실패: " + label); exit(1) }
}
func rejected(_ label: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); print("실패: " + label); exit(1) } catch {}
}
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
let (toolA, toolB, toolC) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64))
let owner = UUID(), boot = UUID().uuidString
let roots = Dictionary(uniqueKeysWithValues: ["", "codex", "desktop", "cwd", "control"].enumerated().map {
    ($0.element, WorkDirectory(device: 1, inode: UInt64($0.offset + 1)))
})
func target(_ fingerprint: String, _ at: Date) -> AppInitialTrialPlan {
    AppInitialTrialPlan(requestID: UUID(), requestedAt: at, domain: .synthetic, root: "/synthetic/work",
        bundlePath: "/synthetic/App.app", executablePath: "/synthetic/App.app/Contents/MacOS/App",
        appVersion: fingerprint, appBuild: "1", appFingerprint: fingerprint,
        cliExecutablePath: "/synthetic/App.app/Contents/MacOS/cli", cliVersion: "fake", cliBuild: "1", cliFingerprint: "fake")
}
let fm = FileManager.default
let fixture = fm.currentDirectoryPath + "/.test-data/work-update-transition-" + UUID().uuidString
try fm.createDirectory(atPath: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: fixture) }
let store = try PrivateStore(root: fixture)

// Completed synthetic setup on v1, the same shape the production setup record has.
let setupPlan = target("v1", t0)
let setup = WorkSetupCoordinator.synthetic(store: store, now: { t0 })
try setup.initialize(plan: setupPlan, approvedAt: t0)
for _ in 0..<2 {
    let receipt = try setup.submit(plan: setupPlan, approval: t0, inspect: {
        WorkSetupVerification(plan: setupPlan, checkedAt: t0, toolFingerprint: toolA, strictIdentityAndPinsVerified: true)
    }, open: { AppInitialTrialReceipt(plan: setupPlan, instanceToken: UUID(), pid: 123, launchedAt: t0, source: .newLaunchCompletion) })
    try setup.report(receipt: receipt, account: .confirmed, personal: .unchanged)
    try setup.exit(AppInitialTrialTerminationReceipt(instance: receipt, observedAt: t0, mainAppExitObservedAfterQuitIntent: true))
}
check(try store.read().workSetup?.completed == true, "합성 setup 완료")

var clock = t0.addingTimeInterval(10)
let daily = WorkDailyCoordinator.synthetic(store: store, now: { clock })
func tick() -> Date { clock = clock.addingTimeInterval(1); return clock }
@discardableResult
func visit(_ fingerprint: String, tool: String, finish: Bool = true, account: AppTrialManualAccount = .confirmed) throws -> UUID {
    let plan = target(fingerprint, tick())
    let submitted = try daily.submit(plan: plan, scope: .acceptance, accepted: true, toolFingerprint: tool, directories: roots,
        owner: owner, bootSession: boot, inspect: {},
        open: { _ in AppInitialTrialReceipt(plan: plan, instanceToken: UUID(), pid: 123, launchedAt: clock, source: .newLaunchCompletion) },
        bind: { receipt in WorkProcess(pid: receipt.pid, uid: getuid(), startSeconds: 1, startMicroseconds: 2, executable: receipt.plan.executablePath) })
    let id = submitted.attemptID
    try daily.transaction { try $0.heartbeat(id, owner: owner, bootSession: boot, now: tick()) }
    try daily.transaction { try $0.report(id, account: account, personal: .unchanged, projectsConnected: true, now: tick()) }
    if finish {
        try daily.transaction { try $0.quitIntent(id, owner: owner, bootSession: boot, now: tick()) }
        try daily.transaction { try $0.exit(id, generation: submitted.generation, owner: owner, bootSession: boot, now: tick()) }
    }
    return id
}
func begin(_ fingerprint: String, tool: String, reviewID: String? = nil, consent: Bool = true, consentAge: TimeInterval = 0,
           directories: [String: WorkDirectory] = roots, inspect: () throws -> Void = {}) throws -> WorkDailyUpdateTransition {
    let plan = target(fingerprint, tick().addingTimeInterval(-consentAge))
    return try daily.beginUpdate(plan: plan, accepted: consent, consentAt: plan.requestedAt, toolFingerprint: tool,
        directories: directories, reviewID: reviewID, replacement: nil, inspect: inspect)
}
let review = "work-update-" + String(repeating: "0", count: 32)
let dailyPath = fixture + "/work-daily.json"
func archives() throws -> [String] { try fm.contentsOfDirectory(atPath: fixture).filter { $0.hasPrefix("work-daily-history-") }.sorted() }

try visit("v1", tool: toolA); try visit("v1", tool: toolA)
check(try daily.read().acceptedCount == 2 && daily.read().grant == nil, "기존 구간: 성공 2회, 일상 허용 없음")
let pendingID = try visit("v1", tool: toolA, finish: false)
rejected("미해결 실행 중 전환 차단") { _ = try begin("v1", tool: toolB) }
_ = try daily.transaction { $0.attempts.removeLast() } // fixture only: drop the open visit to continue
check(try daily.read().attempts.allSatisfy { $0.id != pendingID }, "fixture 정리")

let before = try Data(contentsOf: URL(fileURLWithPath: dailyPath))
rejected("동의 취소 시 전환 없음") { _ = try begin("v1", tool: toolB, consent: false) }
rejected("120초 지난 동의 거부") { _ = try begin("v1", tool: toolB, consentAge: 121) }
rejected("같은 런처·같은 버전은 전환 대상 아님") { _ = try begin("v1", tool: toolA) }
rejected("버전 변경 없는 검토 ID 거부") { _ = try begin("v1", tool: toolB, reviewID: review) }
rejected("검토 없는 버전 변경 거부") { _ = try begin("v2", tool: toolB) }
rejected("잘못된 검토 ID 거부") { _ = try begin("v2", tool: toolB, reviewID: "work-update-x") }
var changedRoots = roots; changedRoots["desktop"] = WorkDirectory(device: 1, inode: 99)
rejected("업무 root 교체 시 전환 거부") { _ = try begin("v1", tool: toolB, directories: changedRoots) }
rejected("최종 공식 앱·도구 검사 실패") { _ = try begin("v1", tool: toolB, inspect: { throw Failure.identityMismatch }) }
check(try Data(contentsOf: URL(fileURLWithPath: dailyPath)) == before && archives().isEmpty, "거부된 전환은 기록·archive를 바꾸지 않음")
rejected("합성 coordinator는 실제 plan 거부") {
    let real = AppInitialTrialPlan.workSetup(requestedAt: clock)
    _ = try daily.beginUpdate(plan: real, accepted: true, consentAt: clock, toolFingerprint: toolB, directories: roots,
                              reviewID: nil, replacement: nil, inspect: {})
}

// 1) Launcher-only replacement on the same official target.
let first = try begin("v1", tool: toolB)
var state = try daily.read()
check(state.schemaVersion == 2 && state.attempts.isEmpty && state.acceptedCount == 0 && state.grant == nil, "새 구간은 성공 0회·허용 없음")
check(first.reviewID == nil && !first.versionChanged && first.fromToolFingerprint == toolA && first.setupPlan == setupPlan, "런처만 교체된 전환 기록")
check(try archives().count == 1 && Data(contentsOf: URL(fileURLWithPath: fixture + "/work-daily-history-" + first.previousArchiveID.uuidString + ".json")) == before,
      "이전 구간을 바이트 그대로 불변 보존")
rejected("이전 런처로 새 구간 실행 불가") { try visit("v1", tool: toolA) }
rejected("이전 성공으로 일상 허용 불가") {
    try daily.transaction { try $0.approveNormal(toolFingerprint: toolB, directories: roots, accepted: true, now: clock) }
}
try visit("v1", tool: toolB)
rejected("새 구간 1회 성공으로 일상 허용 불가") {
    try daily.transaction { try $0.approveNormal(toolFingerprint: toolB, directories: roots, accepted: true, now: clock) }
}
try visit("v1", tool: toolB)
try daily.transaction { try $0.approveNormal(toolFingerprint: toolB, directories: roots, accepted: true, now: tick()) }
check(try daily.read().grant != nil, "새 구간 수용 2회 뒤 별도 일상 허용")

// 2) Official update: v1 -> v2 needs a reviewed edge; the grant does not carry over.
let second = try begin("v2", tool: toolC, reviewID: review)
state = try daily.read()
check(second.versionChanged && second.reviewID == review && second.setupPlan == setupPlan && state.grant == nil && state.acceptedCount == 0,
      "버전 업데이트 구간: 검토 ID 기록, 허용 승계 없음")
rejected("이전 버전 target으로 실행 불가") { try visit("v1", tool: toolC) }
rejected("일상 범위 실행 불가") {
    let plan = target("v2", tick())
    _ = try daily.submit(plan: plan, scope: .normal, accepted: true, toolFingerprint: toolC, directories: roots, owner: owner,
        bootSession: boot, inspect: {}, open: { _ in throw Failure.io }, bind: { _ in throw Failure.io })
}
try visit("v2", tool: toolC)
check(try daily.read().acceptedCount == 1, "새 버전 수용 진행")

// Archive integrity is re-verified on every read.
let archivePath = fixture + "/work-daily-history-" + second.previousArchiveID.uuidString + ".json"
let archived = try Data(contentsOf: URL(fileURLWithPath: archivePath))
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivePath)
try Data(archived.dropLast()).write(to: URL(fileURLWithPath: archivePath))
rejected("변조된 이전 구간 archive 거부") { _ = try daily.read() }
try archived.write(to: URL(fileURLWithPath: archivePath))
check(try daily.read().acceptedCount == 1, "원래 archive 복원 시 다시 읽기")
var object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dailyPath))) as! [String: Any]
var update = object["update"] as! [String: Any]
update["inheritedGrant"] = true
object["update"] = update
rejected("전환 기록의 알 수 없는 필드 거부") { _ = try WorkDailyState.decode(JSONSerialization.data(withJSONObject: object), now: clock) }
var schema1 = object; schema1["schemaVersion"] = 1
rejected("schema와 전환 종류 불일치 거부") { _ = try WorkDailyState.decode(JSONSerialization.data(withJSONObject: schema1), now: clock) }

// A rejected account report blocks any further transition.
let mismatch = try visit("v2", tool: toolC, finish: false, account: .mismatch)
rejected("다른 계정 보고 뒤 종료 준비 거부") { try daily.transaction { try $0.quitIntent(mismatch, owner: owner, bootSession: boot, now: tick()) } }
try daily.transaction {
    try $0.exit(mismatch, generation: WorkProcess(pid: 123, uid: getuid(), startSeconds: 1, startMicroseconds: 2,
        executable: "/synthetic/App.app/Contents/MacOS/App"), owner: owner, bootSession: boot, now: tick())
}
check(try !daily.read().pending, "거부 보고 방문도 종료 관측")
rejected("다른 계정 보고 뒤 전환 차단") { _ = try begin("v3", tool: toolA, reviewID: review) }

// Update before the first launcher visit: no work-daily record yet, the completed setup is the segment.
let freshFixture = fixture + "/fresh"
try fm.createDirectory(atPath: freshFixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let freshStore = try PrivateStore(root: freshFixture)
try freshStore.transaction { $0.workSetup = try store.read().workSetup }
let fresh = WorkDailyCoordinator.synthetic(store: freshStore, now: { clock })
func freshBegin(_ replaced: String?) throws -> WorkDailyUpdateTransition {
    let plan = target("v2", tick())
    return try fresh.beginUpdate(plan: plan, accepted: true, consentAt: plan.requestedAt, toolFingerprint: toolC, directories: roots,
                                 reviewID: review, replacement: nil, replacedToolFingerprint: replaced, inspect: {})
}
rejected("교체된 런처를 모르면 첫 방문 전 전환 불가") { _ = try freshBegin(nil) }
let freshUpdate = try freshBegin(toolA)
check(freshUpdate.fromPlan == setupPlan && freshUpdate.fromToolFingerprint == toolA && freshUpdate.versionChanged, "첫 방문 전 업데이트는 setup 대상에서 시작")
check(try fresh.read().acceptedCount == 0 && fresh.read().schemaVersion == 2, "첫 방문 전 전환 뒤 성공 0회")
let freshArchive = try Data(contentsOf: URL(fileURLWithPath: freshFixture + "/work-daily-history-" + freshUpdate.previousArchiveID.uuidString + ".json"))
check(try WorkDailyState.decode(freshArchive, now: clock).attempts.isEmpty, "빈 이전 구간도 불변 보존")
_ = try { () throws -> UUID in
    let plan = target("v2", tick())
    let submitted = try fresh.submit(plan: plan, scope: .acceptance, accepted: true, toolFingerprint: toolC, directories: roots, owner: owner,
        bootSession: boot, inspect: {}, open: { _ in AppInitialTrialReceipt(plan: plan, instanceToken: UUID(), pid: 123, launchedAt: clock, source: .newLaunchCompletion) },
        bind: { receipt in WorkProcess(pid: receipt.pid, uid: getuid(), startSeconds: 1, startMicroseconds: 2, executable: receipt.plan.executablePath) })
    return submitted.attemptID
}()
check(try fresh.read().pending, "새 버전 첫 수용 방문 예약")

// Production pins: only `current` launches; history is read-only.
let now = Date()
let current = AppInitialTrialPlan.workSetup(requestedAt: now)
check(current == .workTarget(WorkAppPins.current, requestedAt: now, requestID: current.requestID) && current.isRecordedWorkPlan, "현재 target")
check(WorkAppPins.history.isEmpty == (WorkAppPins.updateReviewID == nil) && (WorkAppPins.updateEdgeSource == WorkAppPins.history.first || WorkAppPins.updateReviewID == nil),
      "검토 edge는 최신 이력에서만 시작")
let production = WorkDailyUpdateTransition(reviewID: nil, setupPlan: current, fromPlan: current, toPlan: current,
    fromToolFingerprint: toolA, toToolFingerprint: toolB, directories: roots, previousArchiveID: UUID(),
    previousArchiveSHA256: toolC, replacement: nil, approvedAt: now)
check(!production.valid(now: now), "실제 전환에는 검증된 교체 영수증 필수")

// Installed receipt lookup (fixture directory standing in for ~/Applications).
let apps = fixture + "/Applications"
try fm.createDirectory(atPath: apps, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let destination = apps + "/CodexSplit-work.app"
let reviewBytes = Data("{\"schemaVersion\":1}".utf8)
@discardableResult
func workspace(_ launcher: String, binding: [String: Any]?, receiptMode: Int = 0o600, extra: [String: Any] = [:],
               backup: Bool = true, review: Data = reviewBytes) throws -> String {
    let directory = apps + "/.CodexSplit-work-replacement-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if backup { try fm.createDirectory(atPath: directory + "/previous.app", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    try review.write(to: URL(fileURLWithPath: directory + "/REVIEW.json"))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory + "/REVIEW.json")
    var receipt: [String: Any] = ["phase": "verified", "backup": directory + "/previous.app", "staging": directory + "/candidate.app",
        "destination": destination, "oldManifest": ["Contents/MacOS/launcher": [toolA, 493]],
        "newManifest": ["Contents/MacOS/launcher": [launcher, 493]], "stateTransitionPerformed": false,
        "fromManifestSHA256": toolA, "toManifestSHA256": toolB]
    receipt.merge(extra) { $1 }
    try JSONSerialization.data(withJSONObject: receipt).write(to: URL(fileURLWithPath: directory + "/RESULT.json"))
    try fm.setAttributes([.posixPermissions: receiptMode], ofItemAtPath: directory + "/RESULT.json")
    if let binding {
        try JSONSerialization.data(withJSONObject: binding).write(to: URL(fileURLWithPath: directory + "/UPDATE.json"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory + "/UPDATE.json")
    }
    return directory
}
func binding(_ launcher: String, review: Any = NSNull(), mode: String = "reviewed") -> [String: Any] {
    ["schemaVersion": 1, "reviewID": review, "mode": mode, "launcherSHA256": launcher, "toManifestSHA256": toolB, "reviewSHA256": dailyDataDigest(reviewBytes)]
}
func locate(_ launcher: String) throws -> (evidence: WorkDailyReplacementEvidence, reviewID: String?, replacedLauncherSHA256: String, automatic: Bool) {
    try WorkDailyReplacementEvidence.locateInstalled(launcherSHA256: launcher, root: apps, destination: destination)
}
rejected("교체 영수증 없으면 전환 불가") { _ = try locate(toolC) }
try workspace(toolA, binding: binding(toolA)) // the earlier recovery-style receipt for another launcher
try workspace(toolC, binding: binding(toolC), receiptMode: 0o644)
rejected("공개 권한 영수증은 무시") { _ = try locate(toolC) }
try workspace(toolC, binding: binding(toolC), extra: ["rawLog": "x"])
rejected("알 수 없는 영수증 필드는 무시") { _ = try locate(toolC) }
try workspace(toolC, binding: binding(toolC), extra: ["phase": "published"])
rejected("검증 완료 전 영수증은 무시") { _ = try locate(toolC) }
try workspace(toolC, binding: binding(toolC), backup: false)
rejected("백업이 없는 영수증은 무시") { _ = try locate(toolC) }
let restoredWorkspace = try workspace(toolC, binding: binding(toolC))
try Data("{}".utf8).write(to: URL(fileURLWithPath: restoredWorkspace + "/RESTORE.json"))
rejected("복원된 교체 영수증은 무시") { _ = try locate(toolC) }
try workspace(toolC, binding: binding(toolC, review: review))
let found = try locate(toolC)
check(found.reviewID == review && found.evidence.toManifestSHA256 == toolB && found.evidence.receiptPath.hasPrefix(apps)
      && found.replacedLauncherSHA256 == toolA, "정확한 런처의 영수증·검토 ID·교체된 이전 런처")
try workspace(toolC, binding: binding(toolC))
rejected("일치 영수증이 둘이면 차단") { _ = try locate(toolC) }
let reviewed = toolA.replacingOccurrences(of: "a", with: "e")
try workspace(reviewed, binding: binding(reviewed), review: Data("changed".utf8))
rejected("검토 사본 해시 불일치 차단") { _ = try locate(reviewed) }
let boolVersion = toolA.replacingOccurrences(of: "a", with: "f")
var boolBinding = binding(boolVersion); boolBinding["schemaVersion"] = true
try workspace(boolVersion, binding: boolBinding)
rejected("schemaVersion true 거부") { _ = try locate(boolVersion) }
let automaticLauncher = toolB.replacingOccurrences(of: "b", with: "1")
try workspace(automaticLauncher, binding: binding(automaticLauncher, review: review, mode: "automatic"))
check(try locate(automaticLauncher).automatic && !found.automatic, "자동 대응 설치 여부를 구분")
let toolOnlyAutomatic = toolB.replacingOccurrences(of: "b", with: "2")
try workspace(toolOnlyAutomatic, binding: binding(toolOnlyAutomatic, mode: "automatic"))
rejected("런처만 교체는 자동 대응 binding 불가") { _ = try locate(toolOnlyAutomatic) }
let unknownMode = toolB.replacingOccurrences(of: "b", with: "3")
try workspace(unknownMode, binding: binding(unknownMode, mode: "skipped"))
rejected("알 수 없는 검토 방식 거부") { _ = try locate(unknownMode) }
try workspace(toolB, binding: nil)
rejected("binding 없는 교체는 차단") { _ = try locate(toolB) }
let other = toolA.replacingOccurrences(of: "a", with: "d")
try workspace(other, binding: binding(other, review: "work-update-bad"))
rejected("잘못된 검토 ID binding 차단") { _ = try locate(other) }
print("\(checks)개 업데이트 전환 검사 통과 (합성 데이터만 사용)")
