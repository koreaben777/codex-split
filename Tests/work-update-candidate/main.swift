import Foundation
import Darwin

// Compiled only inside a copy staged by scripts/update-work.py (see work_update_candidate_stage.py).
// No official app, installed launcher or work profile is read: every rejection happens before I/O.
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("실패: " + label); exit(1) }
}
func rejected(_ label: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); print("실패: " + label); exit(1) } catch {}
}
let now = Date()
// Also holds when the pipeline re-runs this suite inside an already staged candidate.
check(!WorkAppPins.history.contains(WorkAppPins.current) && !WorkAppPins.history.isEmpty
      && WorkAppPins.updateEdgeSource == WorkAppPins.history.first && WorkAppPins.updateReviewID.map(WorkDailyUpdateTransition.validReviewID) == true,
      "후보는 직전 target을 이력으로 옮기고 검토 edge 하나만 가짐")
let old = AppInitialTrialPlan.workTarget(WorkAppPins.history.first!, requestedAt: now)
let current = AppInitialTrialPlan.workSetup(requestedAt: now)
check(old.isHistoricalWorkPlan && old.isRecordedWorkPlan && !old.isPinnedProductionPlan && current.isPinnedProductionPlan,
      "이전 target은 기록 읽기 전용, 현재 target만 실행 대상")
rejected("이전 target 공식 앱 검사 거부") { try ProductionInitialTrial.checkBinaries(old) }
rejected("이전 target으로 업무 root 재사용 거부") { _ = try AppTrialRootLease.resumeWork(old) }
let roots = Dictionary(uniqueKeysWithValues: ["", "codex", "desktop", "cwd", "control"].enumerated().map {
    ($0.element, WorkDirectory(device: 1, inode: UInt64($0.offset + 1)))
})
let attempt = WorkDailyAttempt(id: UUID(), plan: old, scope: .acceptance, approvedAt: now,
    toolFingerprint: String(repeating: "a", count: 64), directories: roots, owner: UUID(), bootSession: UUID().uuidString)
check(attempt.valid(now: now), "이전 버전 일상 기록을 후보가 읽을 수 있음")
let foreign = AppInitialTrialPlan(requestID: UUID(), requestedAt: now, domain: .production, root: old.root, bundlePath: old.bundlePath,
    executablePath: old.executablePath, appVersion: "unreviewed", appBuild: "0", appFingerprint: String(repeating: "f", count: 64),
    cliExecutablePath: old.cliExecutablePath, cliVersion: old.cliVersion, cliBuild: old.cliBuild, cliFingerprint: old.cliFingerprint)
check(!WorkDailyAttempt(id: UUID(), plan: foreign, scope: .acceptance, approvedAt: now, toolFingerprint: String(repeating: "a", count: 64),
    directories: roots, owner: UUID(), bootSession: UUID().uuidString).valid(now: now), "검토되지 않은 target 기록 거부")
let evidence = WorkDailyReplacementEvidence(receiptPath: CodexSplitPaths.replacementPrefix + String(repeating: "0", count: 32) + "/RESULT.json",
    receiptSHA256: String(repeating: "1", count: 64), fromManifestSHA256: String(repeating: "2", count: 64), toManifestSHA256: String(repeating: "3", count: 64))
let transition = WorkDailyUpdateTransition(reviewID: WorkAppPins.updateReviewID, setupPlan: old, fromPlan: old, toPlan: current,
    fromToolFingerprint: String(repeating: "a", count: 64), toToolFingerprint: String(repeating: "b", count: 64), directories: roots,
    previousArchiveID: UUID(), previousArchiveSHA256: String(repeating: "c", count: 64), replacement: evidence, approvedAt: now)
check(transition.valid(now: now) && transition.versionChanged, "검토된 이전 버전→후보 전환 기록 형식")
let unreviewed = WorkDailyUpdateTransition(reviewID: nil, setupPlan: old, fromPlan: old, toPlan: current,
    fromToolFingerprint: String(repeating: "a", count: 64), toToolFingerprint: String(repeating: "b", count: 64), directories: roots,
    previousArchiveID: UUID(), previousArchiveSHA256: String(repeating: "c", count: 64), replacement: evidence, approvedAt: now)
check(!unreviewed.valid(now: now), "검토 ID 없는 버전 전환 거부")
// Records shaped like a real profile on the previous target (no live file is read): a completed
// setup, a segment with two accepted visits, and the schema-2 update segment built on top of it.
let t = now.addingTimeInterval(-7200)
let previous = AppInitialTrialPlan.workTarget(WorkAppPins.history.first!, requestedAt: t)
var setupRecord = WorkSetupRecord(plan: previous, approvedAt: t)
for _ in 0..<2 {
    let receipt = AppInitialTrialReceipt(plan: previous, instanceToken: UUID(), pid: 456, launchedAt: t, source: .newLaunchCompletion)
    var session = AppInitialTrialSession(receipt: receipt)
    try session.observeOwnedUI(receipt, now: t)
    try session.reportAccount(.confirmed, for: receipt)
    try session.recordObservedMainAppExit(AppInitialTrialTerminationReceipt(instance: receipt, observedAt: t, mainAppExitObservedAfterQuitIntent: true), now: t)
    setupRecord.launchApprovals.append(t)
    setupRecord.verifications.append(WorkSetupVerification(plan: previous, checkedAt: t, toolFingerprint: String(repeating: "a", count: 64), strictIdentityAndPinsVerified: true))
    setupRecord.visits.append(WorkSetupVisit(session: session, personal: .unchanged))
}
check(setupRecord.valid(now: now) && setupRecord.completed && !setupRecord.sameTarget(as: current),
      "후보가 이전 버전의 완료 setup을 유효하게 읽음")
let toolA = String(repeating: "a", count: 64), toolB = String(repeating: "b", count: 64)
var segment = WorkDailyState()
var clock = t.addingTimeInterval(60)
for _ in 0..<2 {
    let plan = AppInitialTrialPlan.workTarget(WorkAppPins.history.first!, requestedAt: clock)
    var visit = WorkDailyAttempt(id: UUID(), plan: plan, scope: .acceptance, approvedAt: clock, toolFingerprint: toolA,
        directories: roots, owner: UUID(), bootSession: UUID().uuidString)
    visit.receipt = AppInitialTrialReceipt(plan: plan, instanceToken: UUID(), pid: 300, launchedAt: clock, source: .newLaunchCompletion)
    visit.generation = WorkProcess(pid: 300, uid: getuid(), startSeconds: UInt64(clock.timeIntervalSince1970), startMicroseconds: 0, executable: plan.executablePath)
    visit.heartbeatAt = clock.addingTimeInterval(1); visit.reportAt = clock.addingTimeInterval(2)
    visit.account = .confirmed; visit.personal = .unchanged; visit.projectsConnected = true
    visit.quitIntentAt = clock.addingTimeInterval(3); visit.endedAt = clock.addingTimeInterval(4); visit.phase = .exitObserved
    segment.attempts.append(visit)
    clock = clock.addingTimeInterval(60)
}
let segmentData = try JSONEncoder().encode(segment)
let decodedSegment = try? WorkDailyState.decode(segmentData, now: now)
check(decodedSegment?.acceptedCount == 2 && decodedSegment?.pending == false, "후보가 이전 버전의 수용 구간을 읽음")
var updated = WorkDailyState(); updated.schemaVersion = 2
updated.update = WorkDailyUpdateTransition(reviewID: WorkAppPins.updateReviewID, setupPlan: setupRecord.plan,
    fromPlan: segment.attempts.last!.plan, toPlan: AppInitialTrialPlan.workSetup(requestedAt: clock), fromToolFingerprint: toolA,
    toToolFingerprint: toolB, directories: roots, previousArchiveID: UUID(),
    previousArchiveSHA256: dailyDataDigest(segmentData), replacement: evidence, approvedAt: clock)
let decodedUpdate = try? WorkDailyState.decode(JSONEncoder().encode(updated), now: now)
check(decodedUpdate?.acceptedCount == 0 && decodedUpdate?.grant == nil && decodedUpdate?.update?.versionChanged == true,
      "그 위의 새 버전 구간은 성공 0회·허용 없음으로 시작")
print("\(checks)개 업데이트 후보 pin 검사 통과 (공식 앱·프로필 읽기 없음)")
