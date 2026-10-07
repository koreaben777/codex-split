import Foundation
import Darwin

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    checks += 1
    if (try? condition()) != true { failures += 1; print("FAIL: \(name)") }
}

let base = FileManager.default.currentDirectoryPath + "/.test-data/policy"
func identity(_ profile: ProfileID = .work) -> Identity {
    let root = base + "/" + profile.rawValue
    let binary = BinaryIdentity(path: "/synthetic/codex", version: "1", build: "10",
                                fingerprint: "code-a", provenance: "synthetic-verified")
    return Identity(profile: profile, cli: binary, app: binary, bundledCLI: binary, appBundlePath: "/synthetic/ChatGPT.app",
                    node: nil, paths: ProfilePaths(root: root, codex: root + "/codex",
                    sqlite: root + "/codex", desktop: root + "/desktop", ipc: root + "/desktop/ipc"),
                    cwd: base, effectiveSettings: "synthetic-settings", authBackend: "synthetic",
                    accountGeneration: "account-1", platform: "synthetic-os-arm64")
}
let original = identity()
func idle(_ identity: Identity) -> RuntimeSnapshot {
    var snapshot = RuntimeSnapshot(identity: identity)
    snapshot.process = .notRunning; snapshot.observationComplete = true; snapshot.bindingMatches = true
    return snapshot
}
func validated() -> Validation {
    Validation(identity: original, source: .supported, restrictedAuth: .supported,
               execution: .supported, account: .confirmed, observedPaths: true,
               tests: [.basic: .passed, .extended: .passed, .day: .passed],
               finalApproval: true, approvedTarget: .cli, trialPermission: nil,
               separation: [])
}
let request = Request(profile: .work, target: .cli, operation: .run, cwd: base)
func decide(_ validation: Validation, _ runtime: RuntimeSnapshot = idle(original)) -> Decision {
    evaluate(request: request, validation: validation, runtime: runtime)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--race" {
    let root = CommandLine.arguments[2]
    do {
        let coordinator = Coordinator(store: try PrivateStore(root: root))
        _ = try coordinator.start(request: request, validation: validated(), observe: { idle(original) }, launch: {
            let marker = root + "/launch-marker"
            let previous = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
            try Data((previous + "launched\n").utf8).write(to: URL(fileURLWithPath: marker))
            usleep(150_000)
        })
    } catch Failure.lockBusy {} catch { print("race fixture error: \(error), errno: \(errno)"); exit(2) }
    exit(0)
}

// Removing the account gate must allow a forbidden workload and fail this check.
var validation = validated()
validation.account = .unverified
check(decide(validation) == .blocked(.authUnverified), "unverified workload blocked")
let auth = Request(profile: .work, target: .cli, operation: .authCheck, cwd: base)
validation.finalApproval = false
validation.observedPaths = false
validation.tests = [:]
check(evaluate(request: auth, validation: validation, runtime: idle(original)) == .allow,
      "restricted auth does not require final approval or existing DB")
validation.restrictedAuth = .unknown
check(evaluate(request: auth, validation: validation, runtime: idle(original)) == .blocked(.capabilityUnknown),
      "unknown auth capability is not permission")
check(decide(validated()) == .allow, "fully evidenced synthetic CLI allowed")
validation = validated(); validation.finalApproval = false
check(decide(validation) == .blocked(.approvalRequired), "tests are not user approval")
for result in [TestResult.failed, .notRun, .inconclusive] {
    validation = validated(); validation.tests[.extended] = result
    check(decide(validation) == .blocked(.testsIncomplete), "non-passing trial blocks use: \(result)")
}
validation = validated(); validation.observedPaths = false
check(decide(validation) == .blocked(.pathsUnobserved), "expected paths do not prove actual paths")
validation = validated(); validation.approvedTarget = .app
check(decide(validation) == .blocked(.approvalStale), "app approval cannot authorize CLI")

for state in [ProcessState.starting, .launchUnconfirmed, .unknown, .runningObserved] {
    var runtime = idle(original); runtime.process = state
    check(decide(validated(), runtime).isBlocked, "same profile busy or uncertain: \(state)")
}
var runtime = idle(original)
runtime.sessionWriter = true
check(decide(validated(), runtime) == .blocked(.sessionBusy), "same conversation single writer")
runtime = idle(original); runtime.otherProfiles = [identity(.personal)]
check(decide(validated(), runtime) == .blocked(.concurrencyUnverified), "different profiles still require separation proof")
validation = validated(); validation.separation = runtime.otherProfiles
check(decide(validation, runtime) == .allow, "exact separated pair allowed")
runtime.otherProfiles[0].accountGeneration = "changed"
check(decide(validation, runtime) == .blocked(.concurrencyUnverified), "separation evidence binds other identity")

// Version text alone is never the identity key.
let changes: [(String, (inout Identity) -> Void)] = [
    ("version", { $0.cli.version = "2" }), ("build", { $0.cli.build = "11" }),
    ("code", { $0.cli.fingerprint = "code-b" }), ("signature", { $0.cli.provenance = "other" }),
    ("executable path", { $0.cli.path = "/synthetic/other" }),
    ("cwd", { $0.cwd += "/other" }), ("settings", { $0.effectiveSettings = "changed" }),
    ("backend", { $0.authBackend = "changed" }), ("account", { $0.accountGeneration = "changed" }),
    ("SQLite", { $0.paths.sqlite += "/other" }), ("OS", { $0.platform = "changed" })
]
for (name, change) in changes {
    var current = original; change(&current)
    check(decide(validated(), idle(current)).isBlocked, "identity change blocked: \(name)")
}
var changed = original; changed.app.build = "11"
check(invalidated(previous: original, current: changed) == [.app, .crossProfile, .connection], "shared app invalidation is scoped")
check(decide(validated(), idle(changed)) == .allow, "unrelated app change preserves standalone CLI approval")
changed = original; changed.bundledCLI.fingerprint = "other"
check(invalidated(previous: original, current: changed).contains(.app), "bundled engine change invalidates app")
changed = original; changed.cli.version = "1"; changed.cli.fingerprint = "different"
check(decide(validated(), idle(changed)).isBlocked, "same version cannot mask replaced code")

for path in ["relative", "/tmp/../escape", "/tmp/.codex/work", "/tmp/.codexuse/work", "/tmp/control\n"] {
    var paths = original.paths; paths.root = path
    check(!pathsAreValid(paths), "unsafe root rejected: \(path.debugDescription)")
}
var paths = original.paths; paths.sqlite = paths.desktop
check(!pathsAreValid(paths), "SQLite override cannot overlap desktop")
paths = original.paths; paths.desktop = paths.codex + "/nested"
check(!pathsAreValid(paths), "nested storage rejected")
check(pathsAreValid(original.paths), "codex and SQLite may intentionally share root")

for args in [["cli"], ["cli", "work", "--cwd", base, "exec"], ["app", "../work"],
             ["login", "work", "--with-api-key"], ["approve", "work", "--yes"],
             ["exec", "work"], ["cli", "work", "--cwd", "relative"]] {
    check((try? Command.parse(args)) == nil, "parser rejects bypass: \(args.first ?? "")")
}
check((try? Command.parse(["cli", "work", "--cwd", base]))?.profile == .work, "explicit CLI selection")
check((try? Command.parse(["status", "personal", "--json"]))?.json == true, "status JSON accepted")
check((try? Command.parse(["verify", "work", "--target", "cli", "--stage", "basic", "--cwd", base])) != nil,
      "verification scope explicit")
check((try? Command.parse(["approve", "work"])) == nil, "approval cannot infer target or scope")

// Removing durable pending or exchanging the locked inode permits a second launch.
let fm = FileManager.default
let storageRoot = fm.currentDirectoryPath + "/.test-data/runtime-" + UUID().uuidString
try fm.createDirectory(atPath: storageRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
let store = try PrivateStore(root: storageRoot)
check(try store.read().schemaVersion == 1, "missing state starts empty, unapproved")
try store.transaction { $0.validations["work-cli"] = validated() }
check(try store.read().validations["work-cli"] == validated(), "private state round trip")
let statePath = storageRoot + "/state.json"
let attrs = try? fm.attributesOfItem(atPath: statePath)
check((attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private state permissions")
var innerRejected = false
try store.withLock { innerRejected = rejected { try store.withLock {} } }
check(innerRejected, "independent lock descriptor cannot enter held lock")
check(fm.fileExists(atPath: storageRoot + "/state.lock"), "lock inode retained after unlock")
let previousBytes = try? Data(contentsOf: URL(fileURLWithPath: statePath))
check(rejected { try store.transaction { _ in throw Failure.io } }, "interrupted transaction fails")
check((try? Data(contentsOf: URL(fileURLWithPath: statePath))) == previousBytes, "failed transaction preserves previous bytes")
try Data("{broken".utf8).write(to: URL(fileURLWithPath: statePath))
check(rejected { _ = try store.read() }, "corrupt state is not approved")
check(rejected { try store.transaction { $0.pending = [:] } }, "corrupt state cannot be silently overwritten")
try Data("{\"schemaVersion\":99,\"pending\":{},\"validations\":{}}".utf8).write(to: URL(fileURLWithPath: statePath))
check(rejected { _ = try store.read() }, "future schema preserved and rejected")
try fm.removeItem(atPath: statePath)

var launches = 0
let coordinator = Coordinator(store: store)
let launched = try coordinator.start(request: request, validation: validated(),
    observe: { idle(original) }, launch: { launches += 1 })
check(launched == .allow && launches == 1, "durable start reaches runner once")
let repeated = try coordinator.start(request: request, validation: validated(),
    observe: { idle(original) }, launch: { launches += 1 })
check(repeated.isBlocked && launches == 1, "pending blocks delayed launch and wrapper restart")
let restarted = Coordinator(store: try PrivateStore(root: storageRoot))
_ = try restarted.start(request: request, validation: validated(),
    observe: { idle(original) }, launch: { launches += 1 })
check(launches == 1, "new coordinator cannot discard orphaned pending")
check(try store.read().pending["work"] != nil, "launch acceptance is not completion")

try store.transaction { $0.pending = [:] } // Synthetic reset only; no product reset command exists.
var observations = 0
let raced = try coordinator.start(request: request, validation: validated(), observe: {
    observations += 1
    var snapshot = idle(original)
    if observations > 1 { snapshot.identity.cli.fingerprint = "replaced" }
    return snapshot
}, launch: { launches += 1 })
check(raced.isBlocked && launches == 1, "identity replacement between checks never reaches runner")

let alias = storageRoot + "/alias"
try fm.createSymbolicLink(atPath: alias, withDestinationPath: storageRoot)
check(rejected { _ = try PrivateStore(root: alias) }, "store symlink root rejected")
check(rejected { try inspectPaths(ProfilePaths(root: storageRoot, codex: alias + "/codex", sqlite: alias + "/codex",
                                             desktop: storageRoot + "/desktop", ipc: storageRoot + "/desktop/ipc")) },
      "symlink storage escape rejected before launch")

// Account evidence and capability belong to one target, including the restricted path.
validation = validated()
let appAuth = Request(profile: .work, target: .app, operation: .authCheck, cwd: base)
check(evaluate(request: appAuth, validation: validation, runtime: idle(original)).isBlocked,
      "CLI restricted capability cannot authorize app authentication")
let trial = Request(profile: .work, target: .cli, operation: .trial(.basic), cwd: base)
validation.tests = [:]; validation.finalApproval = false; validation.trialPermission = .basic
check(evaluate(request: trial, validation: validation, runtime: idle(original)) == .allow,
      "explicit basic trial permission avoids final approval cycle")
validation.account = .unverified
check(evaluate(request: trial, validation: validation, runtime: idle(original)).isBlocked,
      "trial permission never bypasses account check")

let mainProcess = ProcessEvidence(pid: 123, startedAt: 100, uid: 501, executable: original.app.path,
    fingerprint: original.app.fingerprint, profile: .work, paths: original.paths, parentPID: 1)
var server = ProcessEvidence(pid: 124, startedAt: 101, uid: 501, executable: original.bundledCLI.path,
    fingerprint: original.bundledCLI.fingerprint, profile: .work, paths: original.paths, parentPID: 123)
func appObservation(_ candidates: [ProcessEvidence], _ servers: [ProcessEvidence] = [], _ pending: Bool = false) -> RuntimeSnapshot {
    observeApp(identity: original, recordedMain: mainProcess, candidates: candidates, servers: servers,
               complete: true, pending: pending, expectedUID: 501)
}
check(appObservation([mainProcess], [server]).process == .runningObserved, "bound main and child observed")
server.pid = 125; server.startedAt = 110
check(appObservation([mainProcess], [server]).process == .runningObserved, "server PID replacement needs valid ancestry and paths")
server.parentPID = 999
check(appObservation([mainProcess], [server]).process == .unknown, "wrong server ancestry not accepted")
server.parentPID = 123; server.paths = identity(.personal).paths
check(appObservation([mainProcess], [server]).process == .unknown, "wrong server storage not accepted")
var reused = mainProcess; reused.startedAt = 200
check(appObservation([reused]).process == .unknown, "PID reuse is not main continuity")
reused = mainProcess; reused.uid = 502
check(appObservation([reused]).process == .unknown, "different user is not profile owner")
check(appObservation([mainProcess, mainProcess]).process == .unknown, "multiple candidates remain ambiguous")
check(appObservation([], [], true).process == .launchUnconfirmed, "absence with pending does not authorize retry")
check(appObservation([]).process == .notRunning, "complete absence without pending")
check(observeApp(identity: original, recordedMain: nil, candidates: [mainProcess], servers: [],
                 complete: true, pending: false, expectedUID: 501).process == .unknown, "external instance not adopted")

let hostile = ["CODEX_HOME": "CANARY", "OPENAI_API_KEY": "CANARY", "CODEX_ACCESS_TOKEN": "CANARY",
               "NODE_OPTIONS": "CANARY", "DYLD_INSERT_LIBRARIES": "CANARY", "BUN_OPTIONS": "CANARY",
               "PATH": "CANARY", "HOME": "/synthetic/home", "LANG": "ko_KR.UTF-8", "HTTPS_PROXY": "https://proxy.invalid"]
let env = childEnvironment(identity: original, inherited: hostile)
check(env["CODEX_HOME"] == original.paths.codex && env["CODEX_SQLITE_HOME"] == original.paths.sqlite,
      "child paths belong only to selected profile")
check(!env.values.contains("CANARY"), "credentials and execution injection not inherited")
check(env["HOME"] == "/synthetic/home" && env["HTTPS_PROXY"] == "https://proxy.invalid", "home and explicit network policy preserved")
let appPlan = try launchPlan(request: Request(profile: .work, target: .app, operation: .run, cwd: base),
                         identity: original, inherited: hostile)
check(appPlan.executable == "/usr/bin/open" && appPlan.arguments.prefix(2) == ["-n", original.appBundlePath],
      "GUI plan selects exact bundle and new instance")
check(appPlan.arguments.contains("--user-data-dir=" + original.paths.desktop), "GUI userData is explicit")
check(!appPlan.arguments.contains(where: { $0.contains("CANARY") }), "no inherited secret in launch arguments")

let raceRoot = storageRoot + "/race"
try fm.createDirectory(atPath: raceRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
func contender() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fm.currentDirectoryPath + "/.build/check")
    process.arguments = ["--race", raceRoot]
    process.environment = ["PATH": "/usr/bin:/bin"]
    try process.run()
    return process
}
let first = try contender(), second = try contender()
first.waitUntilExit(); second.waitUntilExit()
check(first.terminationStatus == 0 && second.terminationStatus == 0, "two real processes contend safely")
check((try? String(contentsOfFile: raceRoot + "/launch-marker", encoding: .utf8)) == "launched\n", "concurrent start has one durable launch")
check(try PrivateStore(root: raceRoot).read().pending.count == 1, "one pending survives both wrapper exits")

let fake = storageRoot + "/한글 공백 $()' cli"
let fakeCWD = storageRoot + "/작업 ; $(not-a-command)"
try fm.createDirectory(atPath: fakeCWD, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
try fm.copyItem(atPath: fm.currentDirectoryPath + "/.build/fake-cli", toPath: fake)
var fakeIdentity = original; fakeIdentity.cli.path = fake; fakeIdentity.cwd = fakeCWD
let fakeRequest = Request(profile: .work, target: .cli, operation: .authCheck, cwd: fakeCWD)
let fakePlan = try launchPlan(request: fakeRequest, identity: fakeIdentity, inherited: hostile)
check(try runCLI(fakePlan) == 7, "fake CLI exit code preserved")
let received = (try? Data(contentsOf: URL(fileURLWithPath: fakeCWD + "/received.json"))).flatMap {
    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
}
check(received?["arguments"] as? [String] == ["login", "status"], "fake receives argv as array")
check(received?["cwd"] as? String == fakeCWD, "shell metacharacters and Korean cwd preserved")
check((received?["environment"] as? [String: String])?["CODEX_HOME"] == original.paths.codex, "fake receives selected home")
let receivedBytes = (try? String(contentsOfFile: fakeCWD + "/received.json", encoding: .utf8)) ?? "missing"
check(!receivedBytes.contains("CANARY"), "fake sees no inherited credential canary")
var interruptedPlan = fakePlan; interruptedPlan.arguments = ["--interrupt-self"]
check(try runCLI(interruptedPlan) == 130, "child SIGINT mapped to 130")

check(decide(validated(), RuntimeSnapshot(identity: original)).isBlocked, "default snapshot is not absence evidence")
let unknownStatus = profileStatus(profile: .personal, validation: nil, runtime: nil)
check(unknownStatus.process.state == .unknown && unknownStatus.localConnection.state == "unknown", "unconfigured status invents no running or connection state")
check(unknownStatus.account["app"] == "unverified", "unconfigured account remains unverified")
let liveStatus = profileStatus(profile: .work, validation: validated(), runtime: appObservation([mainProcess]))
check(liveStatus.process.state == .runningObserved && liveStatus.localConnection.state == "unknown", "process liveness does not prove a local connection")
check(liveStatus.account["cli"] == "user-confirmed" && liveStatus.account["app"] == "unverified", "CLI account does not propagate to app")
let expectedOnly = profileStatus(profile: .work, validation: nil, runtime: idle(original))
check(expectedOnly.paths["sqlite"]?.state == "unknown" && expectedOnly.paths["sqlite"]?.observed == nil, "expected paths never copied into observations")
let statusData = try JSONEncoder().encode(liveStatus)
let statusJSON = try JSONSerialization.jsonObject(with: statusData) as! [String: Any]
check(Set(statusJSON.keys) == Set(["schemaVersion", "profileId", "observedAt", "process", "paths", "profileBinding", "account", "compatibility", "localConnection", "nextAction"]), "status JSON separates its evidence axes")

// Independent review regressions: unresolved starts must cross profile boundaries.
let otherRoot = storageRoot + "/other-pending"
try fm.createDirectory(atPath: otherRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let otherStore = try PrivateStore(root: otherRoot)
var otherLaunches = 0
for operation in [Operation.run, .login] {
    try otherStore.transaction {
        $0.pending = ["personal": Pending(identity: identity(.personal), createdAt: Date())]
    }
    let otherRequest = Request(profile: .work, target: .cli, operation: operation, cwd: base)
    let result = try Coordinator(store: otherStore).start(request: otherRequest, validation: validated(),
        observe: { idle(original) }, launch: { otherLaunches += 1 })
    check(result.isBlocked, "other-profile pending blocks \(operation)")
}
check(otherLaunches == 0, "other-profile pending invokes no runner")

var caseAlias = original.paths
caseAlias.desktop = caseAlias.root + "/CODEX"; caseAlias.ipc = caseAlias.desktop + "/ipc"
check(!pathsAreValid(caseAlias), "case-insensitive storage aliases cannot split profiles")
check(!safeAbsolutePath("/tmp/.CoDeXuSe/work"), "protected home check is case-insensitive")
check(overlap("/synthetic/caf\u{00e9}", "/synthetic/cafe\u{0301}"), "Unicode normalization aliases overlap")
check(overlap("/synthetic/Work", "/synthetic/work"), "case-insensitive profile roots overlap")
validation = validated(); validation.approvedTarget = .app; validation.account = .unverified
for operation in [Operation.authCheck, .login] {
    let restrictedApp = Request(profile: .work, target: .app, operation: operation, cwd: base)
    check(evaluate(request: restrictedApp, validation: validation, runtime: idle(original)).isBlocked,
          "unsupported restricted app route rejected by policy")
    check(rejected { _ = try launchPlan(request: restrictedApp, identity: original, inherited: [:]) },
          "restricted app route never creates full-app plan")
}

let unsafeRoot = storageRoot + "/unsafe"
let unsafePaths = ProfilePaths(root: unsafeRoot, codex: unsafeRoot + "/codex", sqlite: unsafeRoot + "/codex",
                               desktop: unsafeRoot + "/desktop", ipc: unsafeRoot + "/desktop/ipc")
try fm.createDirectory(atPath: unsafeRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
chmod(unsafeRoot, 0o777)
check(rejected { try inspectPaths(unsafePaths) }, "world-writable profile root rejected")
chmod(unsafeRoot, 0o755)
check(rejected { try inspectPaths(unsafePaths) }, "non-private profile root rejected")
chmod(unsafeRoot, 0o700)
try fm.createDirectory(atPath: unsafePaths.codex, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
chmod(unsafePaths.codex, 0o777)
check(rejected { try inspectPaths(unsafePaths) }, "world-writable storage child rejected")
chmod(unsafePaths.codex, 0o700)
let exposedParent = storageRoot + "/exposed"
let privateChild = exposedParent + "/private"
try fm.createDirectory(atPath: privateChild, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
chmod(exposedParent, 0o777)
check(rejected { _ = try PrivateStore(root: privateChild) }, "writable ancestor rejected")

print("\(checks - failures)/\(checks) checks passed")
try fm.removeItem(atPath: storageRoot)
exit(failures == 0 ? 0 : 1)
