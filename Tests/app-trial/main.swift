import Foundation
import Darwin
// Terminal answer EOF regression entry (driven by Tests/terminal_eof.py through a PTY).
if CommandLine.arguments.dropFirst() == ["--eof"] {
    do {
        _ = try ProductionInitialTrial.answer("TEST EOF", onEOF: { print("EOF_RECORDED"); fflush(stdout) })
        print("EOF_UNEXPECTED_ANSWER"); exit(1)
    } catch { print("EOF_STOPPED"); exit(0) }
}
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("FAIL: " + label); exit(1) }
}
let time = Date(timeIntervalSince1970: 1_700_000_000)
let production = AppInitialTrialPlan.workSetup(requestedAt: time)
func synthetic(_ root: String = "/synthetic/new-trial", fingerprint: String = "fake") -> AppInitialTrialPlan {
    AppInitialTrialPlan(requestID: UUID(), requestedAt: time, domain: .synthetic, root: root,
        bundlePath: "/synthetic/App.app", executablePath: "/synthetic/App.app/Contents/MacOS/App",
        appVersion: "fake", appBuild: "1", appFingerprint: fingerprint,
        cliExecutablePath: "/synthetic/App.app/Contents/MacOS/cli", cliVersion: "fake", cliBuild: "1", cliFingerprint: "fake")
}
let plan = synthetic()
var launches = 0
func launch(_ target: AppInitialTrialPlan) -> AppInitialTrialReceipt {
    launches += 1
    return AppInitialTrialReceipt(plan: target, instanceToken: UUID(), pid: 123, launchedAt: time, source: .newLaunchCompletion)
}
var session = AppInitialTrialSession(receipt: launch(plan))
check(launches == 1 && session.state == .submitted, "backend receipt alone never reports visible UI or trial success")
check(!session.loginAuthorized && !session.normalUseAuthorized, "UI trial does not authorize login or general use")
check((try? session.reportAccount(.confirmed, for: session.receipt)) == nil && session.manualAccount == nil,
    "account report requires observed owned UI")
let unrelated = launch(plan)
check((try? session.observeOwnedUI(unrelated, now: time)) == nil, "another instance token cannot supply UI evidence")
try session.observeOwnedUI(session.receipt, now: time)
try session.reportAccount(.loginRequired, for: session.receipt)
check(session.manualAccount == .loginRequired && !session.loginAuthorized, "login-required report is separate from login consent")
check((try? session.recordObservedMainAppExit(AppInitialTrialTerminationReceipt(instance: session.receipt, observedAt: time,
    mainAppExitObservedAfterQuitIntent: false), now: time)) == nil && session.state == .accountReported,
    "window closure or termination request without completion cannot mark termination")
check((try? session.recordObservedMainAppExit(AppInitialTrialTerminationReceipt(instance: unrelated, observedAt: time,
    mainAppExitObservedAfterQuitIntent: true), now: time)) == nil, "termination must identify the exact owned instance")
try session.recordObservedMainAppExit(AppInitialTrialTerminationReceipt(instance: session.receipt, observedAt: time,
    mainAppExitObservedAfterQuitIntent: true), now: time)
check(session.state == .mainAppExitedAfterQuitIntent && !session.normalUseAuthorized, "observed main-app exit is limited trial lifecycle evidence")
check(try JSONDecoder().decode(AppInitialTrialSession.self, from: JSONEncoder().encode(session)) == session, "durable session representation round-trips without account identifiers")
for (pid, launchedAt) in [(Int32(0), time), (Int32(123), time.addingTimeInterval(-1)), (Int32(123), time.addingTimeInterval(1))] {
    check(!AppInitialTrialReceipt(plan: plan, instanceToken: UUID(), pid: pid, launchedAt: launchedAt,
        source: .newLaunchCompletion).matches(plan, now: time), "receipt rejects invalid pid or launch time")
}
let fm = FileManager.default
let fixture = fm.currentDirectoryPath + "/.test-data/initial-trial-" + UUID().uuidString
try fm.createDirectory(atPath: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: fixture) }
final class FakeTrialApplication: AppTrialApplicationObject {
    let identity: UUID
    var trialBundlePath: String? = plan.bundlePath
    var trialExecutablePath: String? = plan.executablePath
    var trialLaunchDate: Date? = time
    var trialPID: Int32 = 888
    var trialIsTerminated = false
    init(identity: UUID = UUID()) { self.identity = identity }
    func isSameApplication(as other: FakeTrialApplication) -> Bool { identity == other.identity }
}
let completedApp = FakeTrialApplication()
let objectAdapter = try AppInitialTrialObjectAdapter(syntheticCompletion: completedApp, plan: plan, now: time)
let samePIDOtherApp = FakeTrialApplication()
check((try? objectAdapter.observeOwnedUI(frontmost: samePIDOtherApp, userConfirmed: true, now: time)) == nil,
      "same PID and paths cannot substitute another app object")
check((try? objectAdapter.observeOwnedUI(frontmost: nil, userConfirmed: true, now: time)) == nil,
      "absent frontmost object cannot establish owned UI")
check((try? objectAdapter.observeOwnedUI(frontmost: completedApp, userConfirmed: false, now: time)) == nil,
      "frontmost object alone cannot supply user's UI confirmation")
check((try? objectAdapter.recordUserQuitIntent(frontmost: completedApp, now: time)) == nil,
      "normal Quit intent requires prior owned UI confirmation")
let equivalentObject = FakeTrialApplication(identity: completedApp.identity)
check(try objectAdapter.observeOwnedUI(frontmost: equivalentObject, userConfirmed: true, now: time) == objectAdapter.receipt,
      "application equality accepts equivalent wrappers without relying on pointer or PID equality")
check((try? objectAdapter.recordUserQuitIntent(frontmost: samePIDOtherApp, now: time)) == nil,
      "focus switching to another app prevents Quit intent attribution")
try objectAdapter.recordUserQuitIntent(frontmost: completedApp, now: time)
check(try objectAdapter.observeTermination(now: time) == nil, "Quit intent is not app exit")
samePIDOtherApp.trialIsTerminated = true
check(try objectAdapter.observeTermination(now: time) == nil, "another app exit never completes this trial")
check((try? objectAdapter.observeTermination(now: time.addingTimeInterval(31))) == nil,
      "timeout cannot produce termination evidence")
completedApp.trialIsTerminated = true
completedApp.trialBundlePath = nil
completedApp.trialExecutablePath = nil
completedApp.trialLaunchDate = nil
let objectTermination = try objectAdapter.observeTermination(now: time.addingTimeInterval(1))
check(objectTermination?.instance == objectAdapter.receipt && objectTermination?.mainAppExitObservedAfterQuitIntent == true,
      "same retained object exit remains observable when post-exit metadata disappears")
check((try? AppInitialTrialObjectAdapter(syntheticCompletion: FakeTrialApplication(), plan: production, now: time)) == nil,
      "fake object adapter rejects production even before any receipt is made")
for wrong in 0..<5 {
    let app = FakeTrialApplication()
    switch wrong {
    case 0: app.trialBundlePath = "/synthetic/Other.app"
    case 1: app.trialExecutablePath = "/synthetic/Other.app/Contents/MacOS/App"
    case 2: app.trialLaunchDate = time.addingTimeInterval(-1)
    case 3: app.trialLaunchDate = nil
    default: app.trialIsTerminated = true
    }
    check((try? AppInitialTrialObjectAdapter(syntheticCompletion: app, plan: plan, now: time)) == nil,
          "completion cannot bind wrong path, old/missing launch date, or an exited app")
}
let unrequestedExit = FakeTrialApplication()
let unrequestedAdapter = try AppInitialTrialObjectAdapter(syntheticCompletion: unrequestedExit, plan: plan, now: time)
unrequestedExit.trialIsTerminated = true
check((try? unrequestedAdapter.observeTermination(now: time)) == nil, "exit without user Quit intent is not normal-stop evidence")
let leasedPlan = synthetic(fixture + "/exclusive-root")
let lease = try AppTrialRootLease.synthetic(leasedPlan)
check((try? lease.validate()) != nil, "fresh lease owns empty private root and children")
check((try? AppTrialRootLease.synthetic(leasedPlan)) == nil, "second creation cannot reuse an existing trial root")
let leaseStore = try PrivateStore(root: leasedPlan.root + "/control")
try leaseStore.transaction { $0.workSetup = WorkSetupRecord(plan: leasedPlan, approvedAt: time) }
check((try? lease.validate()) != nil, "durable control reservation does not contaminate empty app directories")
try Data("synthetic".utf8).write(to: URL(fileURLWithPath: leasedPlan.root + "/codex/config.toml"))
check((try? lease.validate()) == nil, "foreign prelaunch configuration is not accepted as a fresh profile")
let swappedPlan = synthetic(fixture + "/swapped-root")
let swappedLease = try AppTrialRootLease.synthetic(swappedPlan)
try fm.moveItem(atPath: swappedPlan.root + "/desktop", toPath: swappedPlan.root + "/old-desktop")
try fm.createDirectory(atPath: swappedPlan.root + "/desktop", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
check((try? swappedLease.validate()) == nil, "same-permission child replacement loses lease identity")
let symlinkPlan = synthetic(fixture + "/symlink-root")
try fm.createSymbolicLink(atPath: symlinkPlan.root, withDestinationPath: leasedPlan.root)
check((try? AppTrialRootLease.synthetic(symlinkPlan)) == nil, "existing symlink root cannot be used for first launch")
check((try? AppTrialRootLease.synthetic(production)) == nil, "synthetic root factory cannot touch production root")
func workCoordinator(_ name: String) throws -> WorkSetupCoordinator {
    let path = fixture + "/" + name
    try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return .synthetic(store: try PrivateStore(root: path), now: { time })
}
func workVerification(_ verified: Bool = true) -> WorkSetupVerification {
    WorkSetupVerification(plan: plan, checkedAt: time, toolFingerprint: String(repeating: "a", count: 64), strictIdentityAndPinsVerified: verified)
}
let work = try workCoordinator("work-setup")
check((try? work.initialize(plan: .workSetup(requestedAt: time), approvedAt: time)) == nil,
      "synthetic work wiring rejects production scope before creating a record")
try work.initialize(plan: plan, approvedAt: time)
var workLaunches = 0
func workLaunch() -> AppInitialTrialReceipt { workLaunches += 1; return launch(plan) }
check((try? work.submit(plan: plan, approval: time, inspect: { workVerification(false) }, open: workLaunch)) == nil && workLaunches == 0,
      "failed strict evidence cannot launch setup")
check(try work.store.read().workSetup?.pending == false, "pre-verification denial leaves no launch reservation")
let workFirst = try work.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)
check(try work.store.read().workSetup?.verifications.count == 1 && work.store.read().workSetup?.verifications.first?.toolFingerprint.count == 64,
      "setup persists exact plan verification and tool fingerprint before opening")
check(try work.store.read().launchUnresolved, "active work setup blocks normal operations")
check((try? work.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)) == nil && workLaunches == 1,
      "open setup cannot spawn duplicate work instance")
try work.report(receipt: workFirst, account: .confirmed, personal: .unchanged)
check(try work.store.read().workSetup?.canRestart == false, "account reports alone never authorize a restart")
try work.exit(AppInitialTrialTerminationReceipt(instance: workFirst, observedAt: time, mainAppExitObservedAfterQuitIntent: true))
check(try work.store.read().workSetup?.canRestart == true, "same main exit plus both manual reports allows only one restart")
let workSecond = try work.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)
try work.report(receipt: workSecond, account: .confirmed, personal: .unchanged)
try work.exit(AppInitialTrialTerminationReceipt(instance: workSecond, observedAt: time, mainAppExitObservedAfterQuitIntent: true))
check(try work.store.read().workSetup?.completed == true && workLaunches == 2, "two exact object lifecycles complete limited setup")
check((try? work.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)) == nil && workLaunches == 2,
      "completed setup cannot automatically become repeatable routine opening")
check(try work.store.read().appApprovals == nil && work.store.read().validations.isEmpty,
      "manual login setup does not mint routine approval")
for (name,account,personal) in [("login-required",AppTrialManualAccount.loginRequired,WorkPersonalReport.unchanged),
                              ("mismatch",.mismatch,.unchanged),("personal-changed",.confirmed,.changed),("personal-unknown",.confirmed,.unknown)] {
    let c = try workCoordinator(name)
    try c.initialize(plan: plan, approvedAt: time)
    let r = try c.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)
    try c.report(receipt: r, account: account, personal: personal)
    try c.exit(AppInitialTrialTerminationReceipt(instance: r, observedAt: time, mainAppExitObservedAfterQuitIntent: true))
    check(try c.store.read().workSetup?.canRestart == false && c.store.read().workSetup?.completed == false,
          "mismatch/login required/personal change or unknown prevents restart and success")
}
let unknownWork = try workCoordinator("work-unknown")
try unknownWork.initialize(plan: plan, approvedAt: time)
check((try? unknownWork.submit(plan: plan, approval: time, inspect: { workVerification() }, open: { throw Failure.io })) == nil,
      "unknown opening result is not retried")
check(try unknownWork.store.read().workSetup?.pending == true && unknownWork.store.read().workSetup?.visits.isEmpty == true,
      "unknown opening keeps recorded verification and pending")
let changedWork = try workCoordinator("work-verification-change")
try changedWork.initialize(plan: plan, approvedAt: time)
var workReads = 0
let priorWorkLaunches = workLaunches
check((try? changedWork.submit(plan: plan, approval: time, inspect: { workReads += 1; return workVerification(workReads == 1) }, open: workLaunch)) == nil,
      "post-reservation verification failure stops real submission")
check(try changedWork.store.read().workSetup?.pending == true && workLaunches == priorWorkLaunches,
      "changed verification preserves reservation without calling opener")
check(AppInitialTrialPlan.workSetup(requestedAt: time).root == CodexSplitPaths.home + "/Library/Application Support/CodexSplit/profiles/work"
      && !CodexSplitPaths.workRoot.lowercased().contains("/.codex"),
      "stable work storage lives under the account's own Application Support, apart from existing Codex profiles")
var lateClock = time
var lateSubmissions = 0
check((try? submitWithinConsent(expiresAt: time.addingTimeInterval(120), now: { lateClock }, finalCheck: {
    lateClock = time.addingTimeInterval(121)
}, submit: { lateSubmissions += 1 })) == nil && lateSubmissions == 0,
      "slow final verification cannot submit after consent expires")
lateClock = time
check((try? submitWithinConsent(expiresAt: time.addingTimeInterval(120), now: { lateClock }, finalCheck: {
    throw Failure.profilePathConflict
}, submit: { lateSubmissions += 1 })) == nil && lateSubmissions == 0,
      "last root check failure prevents actual submission")
try submitWithinConsent(expiresAt: time.addingTimeInterval(120), now: { lateClock }, finalCheck: {}, submit: { lateSubmissions += 1 })
check(lateSubmissions == 1, "valid final check submits once within unchanged deadline")
// Deferred-login resume keeps old evidence and changes only the current attempt under lock.
func renewed(_ original: AppInitialTrialPlan) -> AppInitialTrialPlan {
    AppInitialTrialPlan(requestID: UUID(), requestedAt: time, domain: original.domain, root: original.root,
        bundlePath: original.bundlePath, executablePath: original.executablePath, appVersion: original.appVersion,
        appBuild: original.appBuild, appFingerprint: original.appFingerprint,
        cliExecutablePath: original.cliExecutablePath, cliVersion: original.cliVersion,
        cliBuild: original.cliBuild, cliFingerprint: original.cliFingerprint)
}
let resumed = WorkSetupCoordinator.synthetic(store: try PrivateStore(root: fixture + "/login-required"), now: { time })
let nextPlan = renewed(plan)
let oldData = try JSONEncoder().encode(resumed.store.read().workSetup!)
check((try? resumed.resume(expectedPriorPlan: plan, plan: plan, approvedAt: time)) == nil,
      "resume requires distinct request ID")
check((try? resumed.resume(expectedPriorPlan: plan, plan: synthetic("/synthetic/other-root"), approvedAt: time)) == nil,
      "resume cannot change storage target")
check((try? resumed.resume(expectedPriorPlan: plan, plan: nextPlan, approvedAt: time.addingTimeInterval(1))) == nil,
      "resume cannot use future consent")
let staleConsent = WorkSetupCoordinator.synthetic(store: resumed.store, now: { time.addingTimeInterval(121) })
check((try? staleConsent.resume(expectedPriorPlan: plan, plan: nextPlan, approvedAt: time)) == nil,
      "resume refuses expired consent")

try resumed.resume(expectedPriorPlan: plan, plan: nextPlan, approvedAt: time)
let resumedRecord = try resumed.store.read().workSetup!
check(resumedRecord.plan == nextPlan && resumedRecord.visits.isEmpty && !resumedRecord.pending,
      "explicit resume starts a distinct empty attempt")
check(resumedRecord.previousAttempts?.count == 1 && resumedRecord.previousAttempts?.first?.plan == plan
      && resumedRecord.previousAttempts?.first?.visits[0].session.manualAccount == .loginRequired,
      "resume archives prior login-required receipt, reports and verification")
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
let oldDecoded = try JSONDecoder().decode(WorkSetupRecord.self, from: oldData)
check(try encoder.encode(resumedRecord.previousAttempts![0]) == encoder.encode(oldDecoded),
      "archived evidence is unchanged byte-for-byte after canonical encoding")
check((try? resumed.resume(expectedPriorPlan: plan, plan: renewed(plan), approvedAt: time)) == nil,
      "stale prior request cannot replace current attempt")
let resumedReceipt = try resumed.submit(plan: nextPlan, approval: time, inspect: {
    WorkSetupVerification(plan: nextPlan, checkedAt: time, toolFingerprint: String(repeating: "b", count: 64), strictIdentityAndPinsVerified: true)
}, open: { launch(nextPlan) })
check(try resumed.store.read().workSetup?.pending == true && resumed.store.read().workSetup?.previousAttempts?.count == 1,
      "resumed submission retains archive and reserves before launch")
check((try? resumed.resume(expectedPriorPlan: nextPlan, plan: renewed(nextPlan), approvedAt: time)) == nil,
      "pending resumed launch cannot be reset")
try resumed.report(receipt: resumedReceipt, account: .confirmed, personal: .unchanged)
try resumed.exit(AppInitialTrialTerminationReceipt(instance: resumedReceipt, observedAt: time, mainAppExitObservedAfterQuitIntent: true))
check(try resumed.store.read().workSetup?.canRestart == true, "resumed confirmed login permits one persistence check")
for name in ["mismatch", "personal-changed", "personal-unknown", "work-unknown", "work-verification-change", "work-setup"] {
    let c = WorkSetupCoordinator.synthetic(store: try PrivateStore(root: fixture + "/" + name), now: { time })
    check((try? c.resume(expectedPriorPlan: plan, plan: renewed(plan), approvedAt: time)) == nil,
          "resume rejects mismatch, personal uncertainty, pending or completed setup: \(name)")
}
let noExit = try workCoordinator("resume-no-exit")
try noExit.initialize(plan: plan, approvedAt: time)
let noExitReceipt = try noExit.submit(plan: plan, approval: time, inspect: { workVerification() }, open: workLaunch)
try noExit.report(receipt: noExitReceipt, account: .loginRequired, personal: .unchanged)
check((try? noExit.resume(expectedPriorPlan: plan, plan: renewed(plan), approvedAt: time)) == nil,
      "login-required manual reports without observed same-instance exit cannot resume")
var tampered = resumedRecord
var nested = oldDecoded; nested.previousAttempts = [oldDecoded]
tampered.previousAttempts = [nested]
check(!tampered.valid(now: time), "nested archive is rejected without recursive validation")
tampered.previousAttempts = [oldDecoded, oldDecoded]
check(!tampered.valid(now: time), "duplicate archived request IDs rejected")
let attached = try AppTrialRootLease.syntheticExisting(leasedPlan)
check((try? attached.validate(requireEmpty: false)) != nil && fm.fileExists(atPath: leasedPlan.root + "/codex/config.toml"),
      "resume attachment preserves nonempty profile data")
check((try? AppTrialRootLease.syntheticExisting(synthetic(fixture + "/absent-resume"))) == nil
      && !fm.fileExists(atPath: fixture + "/absent-resume"), "resume does not create missing root")
check((try? AppTrialRootLease.syntheticExisting(symlinkPlan)) == nil, "resume rejects symlink root")
check((try? AppTrialRootLease.syntheticExisting(production)) == nil, "synthetic attachment rejects production scope")
try fm.moveItem(atPath: leasedPlan.root + "/cwd", toPath: leasedPlan.root + "/old-cwd")
try fm.createDirectory(atPath: leasedPlan.root + "/cwd", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
check((try? attached.validate(requireEmpty: false)) == nil, "resume detects child replacement during invocation")
print("\(checks) work setup and launch lifecycle checks passed (pure synthetic backend and private fixture only)")
