import Foundation
import Darwin
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("FAIL: " + label); exit(1) }
}
let fm = FileManager.default, project = fm.currentDirectoryPath
let root = project + "/.test-data/app-approval-" + UUID().uuidString
try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: root) }
for name in ["state", "work", "work/codex", "work/desktop", "work/desktop/ipc", "personal", "personal/codex", "personal/desktop", "personal/desktop/ipc"] {
    try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
}
let paths = ProfilePaths(root: root + "/work", codex: root + "/work/codex", sqlite: root + "/work/codex", desktop: root + "/work/desktop", ipc: root + "/work/desktop/ipc")
let config = AppProfileConfiguration(profileId: .work, appBundlePath: root + "/Synthetic.app", paths: paths, cwd: root)
let binary = BinaryIdentity(path: root + "/Synthetic.app/Contents/MacOS/Fake", version: "fake-1", build: "1", fingerprint: "synthetic", provenance: "synthetic")
let identity = Identity(profile: .work, cli: binary, app: binary, bundledCLI: binary, appBundlePath: config.appBundlePath, node: nil, paths: paths, cwd: root, effectiveSettings: "synthetic", authBackend: "synthetic", accountGeneration: "1", platform: "synthetic")
let validation = Validation(identity: identity, source: .supported, restrictedAuth: .supported, execution: .supported, account: .confirmed, observedPaths: true, tests: [.basic: .passed, .extended: .passed, .day: .passed], finalApproval: true, approvedTarget: .app, trialPermission: nil, separation: [])

let store = try PrivateStore(root: root + "/state")
let registry = AppProfileRegistry(store: store)
let registration = try registry.register(config, replacing: nil)
var clock = Date(timeIntervalSince1970: 1_700_000_000)
let initialTime = clock
var snapshot = RuntimeSnapshot(identity: identity, process: .notRunning, observationComplete: true, bindingMatches: true, observedPaths: paths)
var source = Capability.supported, account = AccountState.confirmed
var observedDomain = AppEvidenceDomain.synthetic
var observations = 0, answers = 0
func observe() -> AppRuntimeObservation {
    observations += 1
    return AppRuntimeObservation(registration: registration, snapshot: snapshot, source: source,
        restrictedAuth: .supported, execution: .supported, account: account,
        observedAt: initialTime, expiresAt: initialTime.addingTimeInterval(60), domain: observedDomain)
}
let trials = AppTrialEvidence(registrationRevision: registration.revision, identity: identity, domain: .synthetic,
    tests: [.basic: .passed, .extended: .passed, .day: .passed], separation: [],
    recordedAt: initialTime, expiresAt: initialTime.addingTimeInterval(30))
let service = AppApprovalService(store: store, domain: .synthetic, now: { clock })
func answer(_ response: ApprovalAnswer) -> (AppApprovalProposal) -> ApprovalAnswer {
    { _ in answers += 1; return response }
}
for response in [ApprovalAnswer.denied, .cancelled, .interrupted] {
    check(try service.approve(registration: registration, trials: trials, observe: observe, ask: answer(response)) == .blocked(.approvalRequired), "nonaccepted consent remains closed")
    check(try store.read().appApprovals == nil, "nonaccepted consent creates no approval")
}
var locked = false
check(try service.approve(registration: registration, trials: trials, observe: observe, ask: { proposal in
    check(proposal.registration == registration && proposal.identity == identity && proposal.domain == .synthetic, "review binds exact target and domain")
    do { _ = try registry.register(config, replacing: registration.revision) } catch Failure.lockBusy { locked = true } catch {}
    return .accepted
}) == .allow, "explicit synthetic consent records approval")
check(locked, "registration cannot change during consent")
let record = try service.approved(registration: registration, observation: observe())
check(record.validation.finalApproval && record.validation.appRegistrationRevision == registration.revision && record.domain == .synthetic,
    "saved approval retains revision and domain")
let production = AppApprovalService(store: store, domain: .production, now: { clock })
check((try? production.approved(registration: registration, observation: observe())) == nil, "synthetic consent cannot commission production")
check(try production.approve(registration: registration, trials: trials, observe: observe, ask: answer(.accepted)) == .blocked(.capabilityUnknown), "production rejects injected answer callback")
let incomplete = AppTrialEvidence(registrationRevision: registration.revision, identity: identity, domain: .synthetic,
    tests: [.basic: .passed], separation: [], recordedAt: initialTime, expiresAt: initialTime.addingTimeInterval(30))
let previousAnswers = answers
check(try service.approve(registration: registration, trials: incomplete, observe: observe, ask: answer(.accepted)) == .blocked(.testsIncomplete) && answers == previousAnswers,
    "consent cannot fabricate missing trial evidence")
account = .unverified
check((try? service.approve(registration: registration, trials: trials, observe: observe, ask: answer(.accepted))) == nil && answers == previousAnswers,
    "account verification precedes consent")
account = .confirmed
clock = initialTime.addingTimeInterval(31)
check((try? service.approved(registration: registration, observation: observe())) == nil, "expired trial approval cannot be reused")
clock = initialTime
check(try service.approve(registration: registration, trials: trials, observe: observe, ask: { _ in
    clock = initialTime.addingTimeInterval(31); return .accepted
}) == .blocked(.approvalStale), "evidence expiring during consent blocks persistence")
clock = initialTime
check((try? service.approve(registration: registration, trials: trials, observe: observe, ask: { _ in
    snapshot.identity.app.build = "changed"; return .accepted
})) == .blocked(.approvalStale), "identity changing during consent invalidates approval")
snapshot.identity = identity
// Consent lifetime is independent of each short-lived observation sample.
let longTrials = AppTrialEvidence(registrationRevision: registration.revision, identity: identity, domain: .synthetic,
    tests: [.basic: .passed, .extended: .passed, .day: .passed], separation: [],
    recordedAt: initialTime, expiresAt: initialTime.addingTimeInterval(300))
func freshObserve() -> AppRuntimeObservation {
    AppRuntimeObservation(registration: registration, snapshot: snapshot, source: .supported,
        restrictedAuth: .supported, execution: .supported, account: .confirmed,
        observedAt: clock, expiresAt: clock.addingTimeInterval(10), domain: .synthetic)
}
clock = initialTime
var displayedExpiry: Date?
check(try service.approve(registration: registration, trials: longTrials, observe: freshObserve, ask: { proposal in
    displayedExpiry = proposal.expiresAt; return .accepted
}) == .allow, "longer trial validity permits explicit bounded consent")
check(displayedExpiry == longTrials.expiresAt, "consent review displays trial-bound expiry")
let longRecord = try service.approved(registration: registration, observation: freshObserve())
clock = initialTime.addingTimeInterval(61)
check(try service.approved(registration: registration, observation: freshObserve()) == longRecord,
    "fresh sample after original TTL reuses unchanged explicit consent")
check((try? service.approved(registration: registration, observation: observe())) == nil,
    "persistent consent cannot reuse expired observation")
snapshot.identity.accountGeneration = "changed"
check((try? service.approved(registration: registration, observation: freshObserve())) == nil,
    "changed account generation invalidates persistent consent")
snapshot.identity = identity
snapshot.identity.app.fingerprint = "changed"
check((try? service.approved(registration: registration, observation: freshObserve())) == nil,
    "changed binary identity invalidates persistent consent")
snapshot.identity = identity
check(try service.approve(registration: registration, trials: longTrials, observe: freshObserve, ask: { _ in
    clock = clock.addingTimeInterval(15); return .accepted
}) == .allow, "fresh post-consent sample replaces sample that expired while answering")
check(try service.approved(registration: registration, observation: freshObserve()).expiresAt == longTrials.expiresAt,
    "new explicit consent never extends independently verified trial expiry")
clock = initialTime.addingTimeInterval(301)
check((try? service.approved(registration: registration, observation: freshObserve())) == nil,
    "fresh observations cannot renew expired consent")
clock = initialTime
let renewed = try registry.register(config, replacing: registration.revision)
check(try store.read().appApprovals == nil, "registration change removes explicit approvals")
check((try? service.approved(registration: renewed, observation: observe())) == nil, "old observation cannot recover cleared approval")
let cleanState = try store.read()
var staleState = cleanState
staleState.appApprovals = ["work": record]
try store.withLock { try store.writeLocked(staleState) }
check((try? store.read()) == nil, "persisted stale revision approval is rejected on load")
try store.withLock { try store.writeLocked(cleanState) }
check(try store.read().appApprovals == nil, "legacy absent approval field remains unapproved")
print("\(checks) explicit app approval checks passed (synthetic observations only)")
