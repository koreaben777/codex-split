import Foundation
import Darwin
var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? condition()) != true { print("FAIL: " + label); exit(1) }
}
let fm = FileManager.default, project = fm.currentDirectoryPath
let root = project + "/.test-data/app-runtime-" + UUID().uuidString
try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: root) }
for name in ["state", "work", "work/codex", "work/desktop", "work/desktop/ipc"] {
    try fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
}
let paths = ProfilePaths(root: root + "/work", codex: root + "/work/codex", sqlite: root + "/work/codex", desktop: root + "/work/desktop", ipc: root + "/work/desktop/ipc")
let configuration = AppProfileConfiguration(profileId: .work, appBundlePath: root + "/Synthetic.app", paths: paths, cwd: root)
let store = try PrivateStore(root: root + "/state")
let registry = AppProfileRegistry(store: store)
let registration = try registry.register(configuration, replacing: nil)
let bundle = configuration.appBundlePath
let nested = bundle + "/Contents/Resources/codex-cli/CodexCLI.app"
func plist(_ object: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) }
var metadata = [bundle + "/Contents/Info.plist": try plist(["CFBundleIdentifier": "com.openai.codex", "CFBundleExecutable": "Codex", "CFBundleShortVersionString": "26.928.40906", "CFBundleVersion": "12694"]),
                nested + "/Contents/Info.plist": try plist(["CFBundleExecutable": "codex", "CFBundleVersion": "1"]),
                bundle + "/Contents/Resources/codex-cli/codex-package.json": Data(#"{"version":"0.159.2"}"#.utf8)]
var readPaths: [String] = [], signatureState = "valid-openai", alias = false
let files = AppBinaryFiles(read: { path in readPaths.append(path); guard let data = metadata[path] else { throw Failure.io }; return data },
    canonicalPath: { alias ? $0 + "/alias" : $0 }, digest: { _ in String(repeating: "a", count: 64) },
    signature: { _ in SignatureReport(state: signatureState, team: "2DC432GLL2", cdhash: "synthetic") })
let metadataFixture = root + "/metadata-fixture"
try Data("synthetic-metadata".utf8).write(to: URL(fileURLWithPath: metadataFixture))
let localFiles = AppBinaryFiles.localReadOnly()
check(try localFiles.read(metadataFixture) == Data("synthetic-metadata".utf8), "concrete metadata reader handles an ordinary fake file")
try Data(repeating: 0, count: 65537).write(to: URL(fileURLWithPath: metadataFixture))
check((try? localFiles.read(metadataFixture)) == nil, "concrete metadata reader rejects oversize before allocation")
let aliasFixture = root + "/metadata-link"
try fm.createSymbolicLink(atPath: aliasFixture, withDestinationPath: metadataFixture)
check((try? localFiles.read(aliasFixture)) == nil, "concrete metadata reader rejects final symlink")
let fifoFixture = root + "/metadata-fifo"
guard mkfifo(fifoFixture, 0o600) == 0 else { exit(1) }
check((try? localFiles.read(fifoFixture)) == nil, "concrete metadata reader rejects FIFO without blocking")
let binaries = try readAppBinaries(bundle: bundle, files: files)
check(binaries.officialSource == .supported && readPaths.count == 3, "file provider reads only three allowlisted bundle metadata files")
check(readPaths.allSatisfy { $0.hasPrefix(bundle + "/Contents/") && !$0.contains("auth") }, "no profile/auth/config reads")
signatureState = "invalid"
check(try readAppBinaries(bundle: bundle, files: files).officialSource == .unknown, "signature failure is not official support")
signatureState = "valid-openai"; alias = true
check((try? readAppBinaries(bundle: bundle, files: files)) == nil, "bundle alias rejected")
alias = false
let identity = Identity(profile: .work, cli: binaries.server, app: binaries.app, bundledCLI: binaries.server,
    appBundlePath: bundle, node: nil, paths: paths, cwd: root, effectiveSettings: "synthetic-settings", authBackend: "synthetic",
    accountGeneration: "synthetic-generation", platform: "synthetic-platform")
var clock = Date(timeIntervalSince1970: 2_000_000_000)
let expiry = clock.addingTimeInterval(20)
var currentIdentity = identity
var domain = AppEvidenceDomain.synthetic
func stamp() -> AppEvidenceStamp { AppEvidenceStamp(registration: registration, identity: currentIdentity, domain: domain, observedAt: clock, expiresAt: expiry) }
var includeStorage = true, includeAccount = true, includeProcesses = true, complete = true
var writer: Bool? = false, other: [Identity]? = [], accountBinding = AppAccountBinding.application
var actualPaths = paths, beforeCount = 0, replaceIdentity = false
let io = AppObservationIO(identity: { _ in
    beforeCount += 1
    if replaceIdentity && beforeCount % 2 == 0 { currentIdentity.app.build = "changed" }
    return AppIdentityReading(stamp: stamp(), officialSource: .supported)
}, storage: { _ in includeStorage ? AppStorageReading(stamp: stamp(), actualPaths: actualPaths) : nil },
account: { _ in includeAccount ? AppAccountReading(stamp: stamp(), state: .confirmed, binding: accountBinding) : nil },
processes: { _ in includeProcesses ? AppProcessReading(stamp: stamp(), recordedMain: nil, candidates: [], servers: [], complete: complete, sessionWriter: writer, otherProfiles: other, expectedUID: getuid()) : nil })
let provider = AppObservationProvider(domain: .synthetic, contract: .synthetic(identity: identity), io: io, now: { clock })
let observed = try provider.observe(registration)
check(observed.execution == .supported && observed.account == .confirmed && observed.snapshot.process == .notRunning, "complete fresh synthetic facts are usable")
includeStorage = false
check(try provider.observe(registration).snapshot.observedPaths == nil, "configured paths do not replace storage observation")
includeStorage = true; actualPaths.sqlite = paths.codex + "/different"
check(try provider.observe(registration).snapshot.observedPaths == nil, "effective sqlite mismatch remains unknown")
actualPaths = paths; accountBinding = .cliOnly
check(try provider.observe(registration).account == .unverified, "CLI account match is not app account binding")
accountBinding = .application; writer = nil
check(try provider.observe(registration).snapshot.process == .unknown, "unobserved writer is not absent")
writer = false; other = nil
check(try provider.observe(registration).snapshot.process == .unknown, "unobserved other profiles are not absent")
other = []; complete = false
check(try provider.observe(registration).snapshot.process == .unknown, "incomplete census stays unknown")
complete = true; replaceIdentity = true; beforeCount = 0
check((try? provider.observe(registration)) == nil, "binary update between reads invalidates observation")
replaceIdentity = false; currentIdentity = identity
clock = expiry
check((try? provider.observe(registration)) == nil, "expired observation rejected")
clock = expiry.addingTimeInterval(-20); domain = .production
let production = AppObservationProvider(domain: .production, contract: .historicalReference, io: io, now: { clock })
check(try production.observe(registration).execution == .unknown, "current official contract cannot certify desktop isolation")
check((try? provider.observe(registration)) == nil, "production/synthetic evidence domains never mix")
currentIdentity.app.version = "1.2.3"; currentIdentity.app.build = "45"; currentIdentity.bundledCLI.version = "0.160.0"
check(!AppVersionContract.historicalReference.matches(currentIdentity), "newly observed installed version cannot reuse historical contract")
check(try production.observe(registration).execution == .unknown, "a current-version metadata reading never updates support automatically")
currentIdentity = identity
domain = .synthetic
// New backend must never have a callable real-process default.
check(AppLaunchBackend.uncommissioned.domain == .production, "production backend starts disabled")
var launches = 0, submitted: LaunchPlan?
let backend = AppLaunchBackend.synthetic(identity: identity, submit: { launches += 1; submitted = $0 })
let application = AppApplicationService(store: store, domain: .synthetic, provider: provider, backend: backend, now: { clock })
check(application.open(.work).reason == .approvalStale && launches == 0, "registered app cannot open without persisted user consent")
check(application.open(.personal).reason == .profileUnconfigured, "missing profile cannot reuse other profile registration")
let trial = AppTrialEvidence(registrationRevision: registration.revision, identity: identity, domain: .synthetic,
    tests: [.basic: .passed, .extended: .passed, .day: .passed], separation: [], recordedAt: clock,
    expiresAt: clock.addingTimeInterval(3600))
let approvals = AppApprovalService(store: store, domain: .synthetic, now: { clock })
check(try approvals.approve(registration: registration, trials: trial, observe: { try provider.observe(registration) }, ask: { _ in .denied }) == .blocked(.approvalRequired), "explicit denial does not commission backend")
check(application.open(.work).reason == .approvalStale && launches == 0, "denied consent leaves no executable approval")
check(try approvals.approve(registration: registration, trials: trial, observe: { try provider.observe(registration) }, ask: { _ in .accepted }) == .allow, "independent fake trial and explicit fake consent store approval")
let approvedObservation = try provider.observe(registration)
let record = try approvals.approved(registration: registration, observation: approvedObservation)
check((try? AppLaunchBackend.production(contract: .historicalReference)) == nil, "unknown official desktop contract cannot construct real executor")
check((try? AppLaunchBackend.production(contract: .synthetic(identity: identity))) == nil, "synthetic contract cannot construct real executor")
let commands = AppCommandContext.prepared(service: application, trials: { _ in trial })
check(AppCommandContext.uncommissioned.open(.work).reason == .profileUnconfigured, "shipped CLI context has no operational dependencies")
let first = commands.open(.work)
check(first.state == .launchRequested && !first.launchConfirmed && launches == 1, "registration observation consent backend complete fake path")
check(submitted?.executable == "/usr/bin/open" && submitted?.arguments.first == "-n", "exact official launch mechanism planned without executing it")
check(submitted?.environment["CODEX_HOME"] == paths.codex && submitted?.environment["CODEX_ELECTRON_USER_DATA_PATH"] == paths.desktop,
      "registered environment reaches only fake backend")
check(application.open(.work).reason == .processUnknown && launches == 1, "saved pending blocks a second click")
let pending = try store.read().pending["work"]!
check(try Coordinator(store: store).complete(pending: pending, observe: { try provider.observe(registration).snapshot }) == .allow, "fake authoritative absence reconciles exact pending")
var contaminated = submitted!; contaminated.environment["OPENAI_API_KEY"] = "FAKE-SECRET"
check((try? backend.launch(contaminated, approval: record, observation: approvedObservation, now: clock)) == nil && launches == 1,
      "backend rejects plan/environment mutation after approval")
let foreign = AppApprovalRecord(validation: record.validation, domain: .production, approvedAt: record.approvedAt, expiresAt: record.expiresAt)
check((try? backend.launch(submitted!, approval: foreign, observation: approvedObservation, now: clock)) == nil && launches == 1,
      "backend never mixes synthetic and production approval")
let expires = record.expiresAt
check((try? backend.launch(submitted!, approval: record, observation: approvedObservation, now: expires)) == nil && launches == 1,
      "backend checks consent and observation expiry immediately before submission")
let disabled = AppApplicationService(store: store, domain: .synthetic, provider: provider, backend: .uncommissioned, now: { clock })
check(disabled.open(.work).reason == .capabilityUnknown && launches == 1, "disabled production backend cannot be replaced by development evidence")
let failing = AppApplicationService(store: store, domain: .synthetic, provider: provider,
    backend: .synthetic(identity: identity, submit: { _ in throw Failure.io }), now: { clock })
check(try failing.open(.work).reason == .io && store.read().pending["work"] != nil, "backend uncertainty preserves durable pending")
let wrongCwd = try Command.parse(["approve", "work", "--target", "app", "--stage", "day", "--cwd", root + "/other"])
check(try commands.approve(wrongCwd) == .blocked(.approvalStale), "CLI approval cannot silently change requested cwd")
let syntheticCLI = try Command.parse(["approve", "work", "--target", "app", "--stage", "day", "--cwd", root])
check(try commands.approve(syntheticCLI) == .blocked(.capabilityUnknown), "synthetic service cannot enter production terminal consent")
print("\(checks) runtime provider/backend checks passed (fake files and callbacks only)")
