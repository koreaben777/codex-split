import Foundation
import Darwin

let project = FileManager.default.currentDirectoryPath
func fixtureIdentity(_ root: String) -> Identity {
    let binary = BinaryIdentity(path: project + "/.build/fake-cli", version: "fake-1", build: "1", fingerprint: "fake-hash", provenance: "synthetic")
    return Identity(profile: .work, cli: binary, app: binary, bundledCLI: binary, appBundlePath: root + "/Fake.app", node: nil,
        paths: ProfilePaths(root: root, codex: root + "/codex", sqlite: root + "/codex", desktop: root + "/desktop", ipc: root + "/desktop/ipc"),
        cwd: root, effectiveSettings: "synthetic", authBackend: "synthetic", accountGeneration: "1", platform: "synthetic")
}
func fixtureValidation(_ identity: Identity) -> Validation {
    Validation(identity: identity, source: .supported, restrictedAuth: .supported, execution: .supported, account: .confirmed, observedPaths: true,
               tests: [.basic: .passed, .extended: .passed, .day: .passed], finalApproval: true, approvedTarget: .cli, trialPermission: nil, separation: [])
}
func fixtureIdle(_ identity: Identity) -> RuntimeSnapshot {
    RuntimeSnapshot(identity: identity, process: .notRunning, observationComplete: true, bindingMatches: true, observedPaths: identity.paths)
}
if CommandLine.arguments.count > 1 {
    let mode = CommandLine.arguments[1]
    if mode == "--prompt" {
        let answer = terminalApproval(Request(profile: .work, target: .cli, operation: .run, cwd: project))
        print("ANSWER:\(answer)")
        exit(answer == .accepted ? 0 : 2)
    }
    if mode == "--run", CommandLine.arguments.count == 3 {
        let cwd = CommandLine.arguments[2]
        guard inside(cwd, project + "/.test-data") else { exit(64) }
        do {
            let store = try PrivateStore(root: cwd), identity = fixtureIdentity(cwd)
            let coordinator = Coordinator(store: store)
            var result: Int32 = 70
            let decision = try coordinator.start(request: Request(profile: .work, target: .cli, operation: .run, cwd: cwd), validation: fixtureValidation(identity), observe: { fixtureIdle(identity) }, launch: {
                result = try runCLI(LaunchPlan(executable: project + "/.build/fake-cli", arguments: ["--wait"], environment: ["PATH": "/usr/bin:/bin"], cwd: cwd))
            })
            guard decision == .allow, let pending = try store.read().pending["work"] else { exit(71) }
            // This fake has no descendants; wait from runCLI proves this synthetic process ended.
            let cleanup = try coordinator.complete(pending: pending, observe: { fixtureIdle(identity) })
            let empty = try store.read().pending.isEmpty
            print("CLEANED:\(cleanup == .allow && empty)")
            var terminal = termios()
            let restored = tcgetattr(STDIN_FILENO, &terminal) == 0 && terminal.c_lflag & tcflag_t(ECHO) != 0
            print("TERMINAL_RESTORED:\(tcgetpgrp(STDIN_FILENO) == getpgrp() && restored)")
            exit(result)
        }
        catch { exit(70) }
    }
    exit(64)
}
var count = 0
func check(_ value: @autoclosure () throws -> Bool, _ name: String) {
    count += 1
    guard (try? value()) == true else { print("FAIL: \(name)"); exit(1) }
}
func account(_ email: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["id": 1, "result": ["account": ["type": "chatgpt", "email": email], "requiresOpenaiAuth": true]])
}
check(accountObservation(account("work@example.test"), expectedEmail: "work@example.test") == .confirmed, "official email match")
check(accountObservation(account("personal@example.test"), expectedEmail: "work@example.test") == .mismatch, "account mismatch")
check(accountObservation(Data("{\"id\":1,\"result\":{\"account\":null}}".utf8), expectedEmail: "work@example.test") == .unverified, "logged out")
check(accountObservation(Data(String(data: account("work@example.test"), encoding: .utf8)!.replacingOccurrences(of: "\"id\":1", with: "\"id\":true").utf8), expectedEmail: "work@example.test") == .unverified, "boolean id is not response correlation")
check(accountObservation(Data("{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"work@example.test\"}}}".utf8), expectedEmail: "work@example.test") == .unverified, "response correlation required")
check(accountObservation(Data("{\"id\":1,\"result\":{\"account\":{\"type\":\"apiKey\",\"email\":\"work@example.test\"}}}".utf8), expectedEmail: "work@example.test") == .unverified, "API key not email identity")
check(approvalAnswer("yes") == .accepted, "explicit approval")
check(approvalAnswer("no") == .denied, "refusal")
check(approvalAnswer("cancel") == .cancelled, "cancel")
check(approvalAnswer("") == .cancelled && approvalAnswer("y") == .cancelled, "no implicit approval")
let lines = " 123 1 501 Fri Oct  2 10:11:12 2026 /Applications/ChatGPT.app/Contents/MacOS/Codex\n"
check(parseProcesses(lines)?.first?.pid == 123, "ps metadata parser")
check(parseProcesses(lines.replacingOccurrences(of: "2026 /", with: "2026     /"))?.first?.executable == "/Applications/ChatGPT.app/Contents/MacOS/Codex", "ps padded executable column")
check(parseProcesses("permission denied") == nil, "query failure not absence")
check(databasePaths("p123\nn/a/state.sqlite\nn/a/auth.json\nn/a/chat.jsonl\n", pid: 123) == ["/a/state.sqlite"], "metadata filtered")
check(databasePaths("p124\nn/a/state.sqlite\n", pid: 123) == nil, "PID mismatch")
let fm = FileManager.default
let root = project + "/.test-data/readiness-" + UUID().uuidString
try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: root) }
let identity = fixtureIdentity(root)
let binary = identity.cli
var validation = fixtureValidation(identity)
validation.finalApproval = false
let request = Request(profile: .work, target: .cli, operation: .run, cwd: root)
func idle(_ value: Identity = identity) -> RuntimeSnapshot {
    fixtureIdle(value)
}
let store = try PrivateStore(root: root)
for answer in [ApprovalAnswer.denied, .cancelled, .interrupted] {
    check(try approve(store: store, request: request, validation: validation, observe: { idle() }, ask: { answer }).isBlocked, "declined approval blocks")
    check(try store.read().validations.isEmpty, "declined approval writes nothing")
}
var changed = identity
changed.cli.fingerprint = "changed-at-same-version"
var observations = 0
check(try approve(store: store, request: request, validation: validation, observe: {
    observations += 1; return idle(observations == 1 ? identity : changed)
}, ask: { .accepted }) == .blocked(.approvalStale), "identity changes during prompt")
check(try store.read().validations.isEmpty, "stale approval not persisted")
check(try approve(store: store, request: request, validation: validation, observe: { idle() }, ask: { .accepted }) == .allow, "explicit current approval stored")
validation = try store.read().validations["work-cli"]!
let coordinator = Coordinator(store: store)
var launches = 0
for bad in [AccountState.unverified, .mismatch] {
    var invalid = validation; invalid.account = bad
    check(try coordinator.start(request: request, validation: invalid, observe: { idle() }, launch: { launches += 1 }).isBlocked, "wrong account invokes no executor")
}
changed = identity; changed.paths.sqlite += "/changed"
check(try coordinator.start(request: request, validation: validation, observe: { idle(changed) }, launch: { launches += 1 }).isBlocked, "storage mismatch invokes no executor")
changed = identity; changed.cli.version = "fake-2"
check(try coordinator.start(request: request, validation: validation, observe: { idle(changed) }, launch: { launches += 1 }).isBlocked, "version change invokes no executor")
check(launches == 0, "all mismatches blocked before fake")
observations = 0
check(try coordinator.start(request: request, validation: validation, observe: {
    observations += 1; return idle(observations == 1 ? identity : changed)
}, launch: { launches += 1 }).isBlocked, "change immediately before launch")
check(try store.read().pending.isEmpty, "prelaunch failure clears own reservation")
let plan = LaunchPlan(executable: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"], cwd: root)
var exitCode: Int32 = 0
check(try coordinator.start(request: request, validation: validation, observe: { idle() }, launch: { exitCode = try runCLI(plan) }) == .allow, "fake start")
check(exitCode == 7, "nonzero normal exit preserved")
let pending = try store.read().pending["work"]!
check(try coordinator.start(request: request, validation: validation, observe: { idle() }, launch: { launches += 1 }).isBlocked, "duplicate pending start")
check(try coordinator.complete(pending: pending, observe: { RuntimeSnapshot(identity: identity) }).isBlocked, "unknown exit retains reservation")
check(try store.read().pending["work"] == pending, "unknown exit remains durable")
check(try coordinator.complete(pending: pending, observe: { idle(changed) }).isBlocked, "changed identity cannot clear reservation")
check(try coordinator.complete(pending: pending, observe: { idle() }) == .allow, "confirmed absence clears reservation after failure")
check(try store.read().pending.isEmpty, "failure cleaned")
try store.transaction { $0.pending["work"] = Pending(identity: identity, createdAt: pending.createdAt) }
check(try coordinator.complete(pending: pending, observe: { idle() }).isBlocked, "old owner cannot clear new reservation")
let record = ManualConnection(identity: identity, recordedAt: Date(), report: .connected)
check(record.status(current: identity)["actual"] == "unknown", "manual connection is never live confirmation")
check(record.status(current: changed)["freshness"] == "stale", "identity change invalidates manual record")
try store.transaction { $0.manualConnections = ["work": record] }
check(try store.read().manualConnections?["work"]?.status(current: identity)["actual"] == "unknown", "manual record persists separately")
let status = profileStatus(profile: .work, validation: validation, runtime: idle(), manualConnection: record)
check(status.localConnection.state == "unknown" && status.localConnection.manualRecord?["manualReport"] == "connected", "status separates manual from actual connection")
check(profileStatus(profile: .personal, validation: nil, runtime: nil, manualConnection: record).localConnection.manualRecord == nil, "manual record cannot cross profiles")
let file = root + "/fake-executable"
try Data("one".utf8).write(to: URL(fileURLWithPath: file))
let firstDigest = fileDigest(file)
try Data("two".utf8).write(to: URL(fileURLWithPath: file))
check(fileDigest(file) != firstDigest, "byte changes produce different fingerprint")
check(inspectSignature(file).state != "valid-openai", "unsigned fake is not official")
var invalidPlan = plan; invalidPlan.arguments = ["safe\0hidden"]
var rejected = false
do { _ = try runCLI(invalidPlan) } catch { rejected = true }
check(rejected, "NUL arguments rejected before spawn")
try store.transaction { $0.pending = [:] }
let lockRejected = try store.withLock { () -> Bool in
    do { _ = try approve(store: store, request: request, validation: validation, observe: { idle() }, ask: { .accepted }); return false }
    catch Failure.lockBusy { return true }
}
check(lockRejected, "approval competes for the same state mutex")
var badPlan = plan; badPlan.executable = root + "/missing-fake"
var failedToSpawn = false
do { _ = try coordinator.start(request: request, validation: validation, observe: { idle() }, launch: { _ = try runCLI(badPlan) }) }
catch { failedToSpawn = true }
check(failedToSpawn, "spawn failure propagated")
let failedPending = try store.read().pending["work"]!
check(try coordinator.complete(pending: failedPending, observe: { idle() }) == .allow, "absence reconciles spawn failure")
check(try coordinator.start(request: request, validation: validation, observe: { idle() }, launch: { _ = try runCLI(plan) }) == .allow, "retry allowed after confirmed cleanup")
print("\(count) readiness checks passed")
