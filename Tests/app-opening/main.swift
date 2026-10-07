import Foundation
import Darwin
let command = try? Command.parse(["app", "work", "--json"])
guard command?.name == "app", command?.profile == .work, command?.json == true else {
    print("FAIL: app work needs a structured launcher response mode")
    exit(1)
}
var checks = 1
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("FAIL: " + label); exit(1) }
}
let fm = FileManager.default, project = fm.currentDirectoryPath
let root = project + "/.test-data/app-open-" + UUID().uuidString
try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: root) }
for name in ["state", "work", "work/codex", "work/desktop", "work/desktop/ipc", "personal", "personal/codex", "personal/desktop", "personal/desktop/ipc"] {
    try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
}
let paths = ProfilePaths(root: root + "/work", codex: root + "/work/codex", sqlite: root + "/work/codex", desktop: root + "/work/desktop", ipc: root + "/work/desktop/ipc")
let config = AppProfileConfiguration(profileId: .work, appBundlePath: root + "/Synthetic.app", paths: paths, cwd: root)
let bytes = try JSONEncoder().encode(config)
check(try AppProfileConfiguration.decode(bytes, for: .work) == config, "location-only configuration round trip")
func invalidConfig(_ change: (inout [String: Any]) -> Void, profile: ProfileID = .work) -> Bool {
    var object = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    change(&object)
    return (try? AppProfileConfiguration.decode(JSONSerialization.data(withJSONObject: object), for: profile)) == nil
}
check(invalidConfig({ $0["schemaVersion"] = 2 }), "future config schema rejected")
check(invalidConfig({ $0["approved"] = true }), "config cannot carry approval bypass")
check(invalidConfig({ $0["profileId"] = "personal" }), "profile binding mismatch rejected")
check(invalidConfig({ $0["cwd"] = "relative" }), "relative cwd rejected")
check(invalidConfig({ $0["appBundlePath"] = paths.root + "/Inside.app" }), "app cannot overlap managed storage")
check(invalidConfig({ $0["appBundlePath"] = "/tmp/.codexuse/Protected.app" }), "existing profile namespace protected")
let duplicated = Data((String(data: bytes, encoding: .utf8)!.dropLast() + ",\"schemaVersion\":1}").utf8)
check((try? AppProfileConfiguration.decode(duplicated, for: .work)) == nil, "duplicate configuration key rejected")
var repeated = false
do { try AppProfileConfiguration.validateSet([config, config]) } catch { repeated = true }
check(repeated, "duplicate profile registration rejected")
var personal = config; personal.profileId = .personal
var collision = false
do { try AppProfileConfiguration.validateSet([config, personal]) } catch { collision = true }
check(collision, "cross-profile storage overlap rejected")
personal.paths = ProfilePaths(root: root + "/personal", codex: root + "/personal/codex", sqlite: root + "/personal/codex", desktop: root + "/personal/desktop", ipc: root + "/personal/desktop/ipc")
try AppProfileConfiguration.validateSet([config, personal])
check(true, "separate profile locations permit same official bundle")
for reversed in [false, true] {
    var cross = config
    cross.appBundlePath = personal.paths.root + "/Other.app"
    var rejected = false
    do { try AppProfileConfiguration.validateSet(reversed ? [personal, cross] : [cross, personal]) } catch { rejected = true }
    check(rejected, "app bundle cannot live in another profile storage in either order")
}
let binary = BinaryIdentity(path: root + "/Synthetic.app/Contents/MacOS/Fake", version: "fake-1", build: "1", fingerprint: "synthetic", provenance: "synthetic")
let identity = Identity(profile: .work, cli: binary, app: binary, bundledCLI: binary, appBundlePath: config.appBundlePath, node: nil, paths: paths, cwd: root, effectiveSettings: "synthetic", authBackend: "synthetic", accountGeneration: "1", platform: "synthetic")
let validation = Validation(identity: identity, source: .supported, restrictedAuth: .supported, execution: .supported, account: .confirmed, observedPaths: true, tests: [.basic: .passed, .extended: .passed, .day: .passed], finalApproval: true, approvedTarget: .app, trialPermission: nil, separation: [])
let coordinator = try Coordinator(store: PrivateStore(root: root + "/state"))
var snapshot = RuntimeSnapshot(identity: identity, process: .notRunning, observationComplete: true, bindingMatches: true, observedPaths: paths)
var launchCount = 0, observeCount = 0, lastPlan: LaunchPlan?
func request(_ selected: AppProfileConfiguration? = config, record: Validation? = validation, capability: Capability = .supported,
             action: ((LaunchPlan) throws -> Void)? = nil) -> AppOpenReply {
    requestAppOpen(profile: .work, configuration: selected, validation: record, coordinator: coordinator,
        adapterCapability: capability, observe: { observeCount += 1; return snapshot },
        launch: { plan in launchCount += 1; lastPlan = plan; try action?(plan) })
}
check(request(nil).reason == .profileUnconfigured && observeCount == 0 && launchCount == 0, "unconfigured click has no runtime effects")
check(request(capability: .unknown).reason == .capabilityUnknown && observeCount == 0 && launchCount == 0, "unverified adapter blocks even synthetic approval")
check(request(record: nil).reason == .approvalRequired && launchCount == 0, "config is not approval")
var badValidation = validation; badValidation.account = .unverified
check(request(record: badValidation).reason == .authUnverified && launchCount == 0, "account gate retained")
snapshot.identity.app.build = "2"
check(request().reason == .approvalStale && launchCount == 0, "changed build requires revalidation")
snapshot.identity = identity; snapshot.observedPaths = nil
check(request().reason == .pathsUnobserved && launchCount == 0, "missing actual path observation blocks")
snapshot.observedPaths = paths; snapshot.process = .runningObserved
check(request().state == .alreadyRunning && launchCount == 0, "existing verified instance is advice only")
snapshot.sessionWriter = true
check(request().reason == .sessionBusy && launchCount == 0, "external session writer blocks click")
snapshot.sessionWriter = false; snapshot.process = .notRunning
var nested: AppOpenReply?
let first = request(action: { _ in nested = request() })
check(first.state == .launchRequested && !first.launchConfirmed && launchCount == 1, "one launch request is not confirmed app startup")
check(nested?.reason == .lockBusy && launchCount == 1, "overlapping click cannot enter locked launch")
check(lastPlan?.executable == "/usr/bin/open" && lastPlan?.arguments.contains(config.appBundlePath) == true, "existing launch plan reused with exact bundle")
check(lastPlan?.environment["CODEX_HOME"] == paths.codex && lastPlan?.environment["CODEX_SQLITE_HOME"] == paths.sqlite && lastPlan?.environment["CODEX_ELECTRON_USER_DATA_PATH"] == paths.desktop, "work paths explicitly forwarded")
check(request().reason == .processUnknown && launchCount == 1, "sequential duplicate cannot bypass durable pending")
let pending = try coordinator.store.read().pending["work"]!
check(try coordinator.complete(pending: pending, observe: { snapshot }) == .allow, "synthetic confirmed absence reconciles owned pending")
let launchError = request(action: { _ in throw Failure.io })
let afterError = try coordinator.store.read()
check(launchError.reason == .io && launchCount == 2 && afterError.pending["work"] != nil, "uncertain launch error retains reservation")
check(request().reason == .processUnknown && launchCount == 2, "failed launch is not retried automatically")
let reply = AppOpenReply(profileId: .work, state: .blocked, reason: .profileUnconfigured)
let replyData = try JSONEncoder().encode(reply)
check(AppOpenReply.decode(replyData, expectedProfile: .work, exitCode: 2) == reply, "launcher receives matching closed reply")
check(AppOpenReply.decode(replyData, expectedProfile: .personal, exitCode: 2) == nil, "wrong profile response rejected")
check(AppOpenReply.decode(replyData, expectedProfile: .work, exitCode: 0) == nil, "exit status mismatch rejected")
var malformed = reply; malformed.schemaVersion = 2
check(AppOpenReply.decode(try JSONEncoder().encode(malformed), expectedProfile: .work, exitCode: 2) == nil, "future reply schema rejected")
malformed = reply; malformed.launchConfirmed = true
check(AppOpenReply.decode(try JSONEncoder().encode(malformed), expectedProfile: .work, exitCode: 2) == nil, "unearned launch confirmation rejected")
let injected = Data((String(data: replyData, encoding: .utf8)!.dropLast() + ",\"message\":\"FAKE-SECRET-TOKEN\"}").utf8)
check(AppOpenReply.decode(injected, expectedProfile: .work, exitCode: 2) == nil, "raw server prose is never a launcher message")
let badReply = Data((String(data: replyData, encoding: .utf8)!.dropLast() + ",\"state\":\"launchRequested\"}").utf8)
check(AppOpenReply.decode(badReply, expectedProfile: .work, exitCode: 2) == nil, "duplicate reply key rejected")
func receipt(_ reads: [LauncherRead], status: Int32? = 2) -> LauncherReceipt {
    var queue = reads, ticks = 0
    return receiveLauncherReply(profile: .work, read: { queue.isEmpty ? .waiting : queue.removeFirst() },
                                exitStatus: { status }, expired: { ticks >= 5 }, pause: { ticks += 1 })
}
if case .reply(let decoded) = receipt([.bytes(replyData.prefix(8)), .bytes(replyData.dropFirst(8)), .eof]) { check(decoded == reply, "split pipe output assembled") }
else { check(false, "split pipe output assembled") }
if case .timedOut = receipt([.waiting]) { check(true, "bounded wait for stalled CLI") } else { check(false, "bounded wait") }
if case .timedOut = receipt([.bytes(replyData), .eof], status: nil) { check(true, "EOF is not child termination") } else { check(false, "EOF termination") }
if case .invalid = receipt([.bytes(Data(repeating: 65, count: 8193))]) { check(true, "oversize child output bounded") } else { check(false, "size bound") }
if case .invalid = receipt([.failed]) { check(true, "read error does not display raw output") } else { check(false, "read error") }
check(!reply.message.contains("FAKE-SECRET") && reply.message.contains("개발용"), "fixed actionable development message")
// Registry and adapter exercise only synthetic paths and injected callbacks.
try fm.createDirectory(atPath: root + "/registry", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let registeredCoordinator = try Coordinator(store: PrivateStore(root: root + "/registry"))
let registry = AppProfileRegistry(store: registeredCoordinator.store)
let registration = try registry.register(config, replacing: nil)
check(try registry.registration(for: .work) == registration, "location registration survives store round trip")
var staleEdit = false
do { _ = try registry.register(config, replacing: nil) } catch Failure.approvalStale { staleEdit = true }
check(staleEdit, "registration compare-and-swap rejects missing current revision")
var originalApproval = validation
originalApproval.appRegistrationRevision = registration.revision // Explicit synthetic approval at the original revision.
try registeredCoordinator.store.transaction { state in
    state.validations["work-app"] = originalApproval
    var otherValidation = validation; otherValidation.identity.profile = .personal
    state.validations["personal-app"] = otherValidation // All cross-profile approvals must invalidate.
}
let replacement = try registry.register(config, replacing: registration.revision)
check(replacement.revision != registration.revision, "replacement rotates revision even for same paths")
check(try registeredCoordinator.store.read().validations.isEmpty, "registration invalidates all prior separation approvals")
var registeredLaunches = 0
func adapter(_ record: AppRegistration, _ capability: Capability = .supported) -> AppRuntimeAdapter {
    AppRuntimeAdapter(registration: record, capability: capability, validation: originalApproval,
        observe: { snapshot }, launch: { _ in registeredLaunches += 1 })
}
check(adapter(registration).open(using: registeredCoordinator).reason == .approvalStale && registeredLaunches == 0, "stale adapter revision cannot launch")
check(adapter(replacement, .unknown).open(using: registeredCoordinator).reason == .capabilityUnknown, "unknown registered adapter remains closed")
snapshot.identity = identity; snapshot.process = .notRunning; snapshot.observedPaths = paths
check(adapter(replacement).open(using: registeredCoordinator).reason == .approvalStale && registeredLaunches == 0, "new registration cannot relabel old approval")
check(AppRuntimeAdapter(registration: replacement, capability: .supported, validation: validation,
    observe: { snapshot }, launch: { _ in registeredLaunches += 1 }).open(using: registeredCoordinator).reason == .approvalStale,
    "legacy approval without registry binding is rejected")
var renewedApproval = validation
renewedApproval.appRegistrationRevision = replacement.revision // Distinct fake evidence/approval after replacement.
check(try JSONDecoder().decode(Validation.self, from: JSONEncoder().encode(renewedApproval)).appRegistrationRevision == replacement.revision,
    "approval revision survives serialization")
var nestedRegistrationBlocked = false
let bound = AppRuntimeAdapter(registration: replacement, capability: .supported, validation: renewedApproval,
    observe: { snapshot }, launch: { _ in
        registeredLaunches += 1
        do { _ = try registry.register(config, replacing: replacement.revision) }
        catch Failure.lockBusy { nestedRegistrationBlocked = true }
    })
check(bound.open(using: registeredCoordinator).state == .launchRequested && registeredLaunches == 1, "persisted registry through bound adapter reaches fake launch")
check(nestedRegistrationBlocked, "registration and launch share one lock")
check(bound.open(using: registeredCoordinator).reason == .processUnknown && registeredLaunches == 1, "registered duplicate keeps durable pending")
var pendingEditBlocked = false
do { _ = try registry.register(config, replacing: replacement.revision) } catch Failure.processUnknown { pendingEditBlocked = true }
check(pendingEditBlocked, "registration cannot move roots while pending exists")
let registeredPending = try registeredCoordinator.store.read().pending["work"]!
check(try registeredCoordinator.complete(pending: registeredPending, observe: { snapshot }) == .allow, "registered fake absence permits reconciliation")
_ = try registry.register(config, replacing: replacement.revision)
check(bound.open(using: registeredCoordinator).reason == .approvalStale, "reconciled replacement invalidates previous bound adapter")
let latest = try registry.registration(for: .work)!
check(requestAppOpen(profile: .work, configuration: config, validation: validation,
    coordinator: registeredCoordinator, adapterCapability: .supported, observe: { snapshot },
    launch: { _ in registeredLaunches += 1 }).reason == .approvalStale, "registered profile rejects legacy unbound callback")
_ = try registry.register(personal, replacing: nil)
check(adapter(latest).open(using: registeredCoordinator).reason == .approvalStale, "other profile edit invalidates cached cross-profile adapter")
let current = try registry.registration(for: .work)!
var overlapConfig = config; overlapConfig.paths = personal.paths
var crossRegistrationRejected = false
do { _ = try registry.register(overlapConfig, replacing: current.revision) }
catch Failure.profilePathConflict { crossRegistrationRejected = true }
check(try crossRegistrationRejected && registry.registration(for: .work) == current, "failed overlapping registration leaves previous revision intact")
var mismatchedValidation = validation; mismatchedValidation.appRegistrationRevision = current.revision
mismatchedValidation.identity.cwd = root + "/other"
check(AppRuntimeAdapter(registration: current, capability: .supported, validation: mismatchedValidation,
    observe: { snapshot }, launch: { _ in registeredLaunches += 1 }).open(using: registeredCoordinator).reason == .approvalStale,
    "bound revision does not authorize mismatched identity")
print("\(checks) app opening/configuration/launcher checks passed (fake launch callback only)")
