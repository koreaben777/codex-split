import Foundation

func profileStatus(profile: ProfileID, validation: Validation?, runtime: RuntimeSnapshot?, manualConnection: ManualConnection? = nil) -> ProfileStatus {
    let snapshot = runtime?.identity.profile == profile ? runtime : nil
    let record = validation?.identity.profile == profile ? validation : nil
    let expected = snapshot?.identity.paths, observed = snapshot?.observedPaths
    var paths: [String: ProfileStatus.PathStatus] = [:]
    for (key, wanted, actual) in [
        ("codex", expected?.codex, observed?.codex), ("sqlite", expected?.sqlite, observed?.sqlite),
        ("desktop", expected?.desktop, observed?.desktop), ("ipc", expected?.ipc, observed?.ipc)
    ] {
        paths[key] = .init(expected: wanted, observed: actual,
                          state: wanted == nil || actual == nil ? "unknown" : (wanted == actual ? "matched" : "mismatch"))
    }
    var account = ["cli": "unverified", "app": "unverified"]
    var compatibility = ["capability": "unknown", "approval": "unapproved",
                         "basic": "not-run", "extended": "not-run", "day": "not-run"]
    if let record, let snapshot {
        let scope: ValidationScope = record.approvedTarget == .cli ? .cli : .app
        let stale = invalidated(previous: record.identity, current: snapshot.identity).contains(scope)
        account[record.approvedTarget.rawValue] = stale ? "stale" : (record.account == .confirmed ? "user-confirmed" : record.account.rawValue)
        compatibility["capability"] = stale ? "unknown" : record.execution.rawValue
        compatibility["approval"] = stale ? "stale" : (record.finalApproval ? "user-approved-record" : "unapproved")
        for stage in Stage.allCases { compatibility[stage.rawValue] = stale ? "not-run" : (record.tests[stage]?.rawValue ?? "not-run") }
    }
    let running = snapshot?.process == .runningObserved && snapshot?.bindingMatches == true
    var status = ProfileStatus(profileId: profile, process: .init(state: snapshot?.process ?? .unknown, identity: snapshot?.mainProcess),
                         paths: paths, profileBinding: snapshot?.bindingMatches == true ? "matched" : "unknown",
                         account: account, compatibility: compatibility,
                         nextAction: running ? "use-existing-instance" : "revalidate")
    if let manualConnection, manualConnection.identity.profile == profile {
        status.localConnection.manualRecord = manualConnection.status(current: snapshot?.identity)
    }
    return status
}

func observeApp(identity: Identity, recordedMain: ProcessEvidence?, candidates: [ProcessEvidence],
                servers: [ProcessEvidence], complete: Bool, pending: Bool, expectedUID: UInt32) -> RuntimeSnapshot {
    var result = RuntimeSnapshot(identity: identity)
    result.process = .unknown; result.observationComplete = complete; result.bindingMatches = false
    guard complete else { return result }
    if candidates.isEmpty && servers.isEmpty {
        result.process = pending ? .launchUnconfirmed : .notRunning
        result.bindingMatches = !pending
        return result
    }
    guard candidates.count == 1, let main = candidates.first, let recorded = recordedMain,
          main == recorded, main.pid > 0, main.startedAt > 0, main.uid == expectedUID,
          main.profile == identity.profile, main.paths == identity.paths,
          main.executable == identity.app.path, main.fingerprint == identity.app.fingerprint else { return result }
    guard servers.allSatisfy({ $0.pid > 0 && $0.pid != main.pid && $0.startedAt >= main.startedAt
        && $0.uid == expectedUID && $0.parentPID == main.pid && $0.profile == identity.profile
        && $0.paths == identity.paths && $0.executable == identity.bundledCLI.path
        && $0.fingerprint == identity.bundledCLI.fingerprint }) else { return result }
    result.process = .runningObserved; result.bindingMatches = true
    result.observedPaths = main.paths; result.mainProcess = main
    return result
}
func childEnvironment(identity: Identity, inherited: [String: String]) -> [String: String] {
    let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM",
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE", "NODE_EXTRA_CA_CERTS"])
    var environment = inherited.filter { allowed.contains($0.key) }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["CODEX_HOME"] = identity.paths.codex
    environment["CODEX_SQLITE_HOME"] = identity.paths.sqlite
    environment["CODEX_ELECTRON_USER_DATA_PATH"] = identity.paths.desktop
    return environment
}
func launchPlan(request: Request, identity: Identity, inherited: [String: String]) throws -> LaunchPlan {
    let environment = childEnvironment(identity: identity, inherited: inherited)
    if request.target == .app {
        guard request.operation != .authCheck && request.operation != .login else { throw Failure.capabilityUnknown }
        let forwarded = ["CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]
            .flatMap { ["--env", $0 + "=" + environment[$0]!] }
        return LaunchPlan(executable: "/usr/bin/open", arguments: ["-n", identity.appBundlePath] + forwarded
            + ["--args", "--user-data-dir=" + identity.paths.desktop], environment: environment, cwd: request.cwd)
    }
    let args: [String]
    switch request.operation {
    case .authCheck: args = ["login", "status"]
    case .login: args = ["login"]
    case .run, .trial: args = []
    }
    return LaunchPlan(executable: identity.cli.path, arguments: args, environment: environment, cwd: request.cwd)
}

func safeAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && path != "/" && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        && !path.split(separator: "/").contains(where: { [".", "..", ".codex", ".codexuse"].contains($0.lowercased()) })
        && URL(fileURLWithPath: path).standardizedFileURL.path == path
}
// Conservatively reject aliases even on case-sensitive volumes; no claim of filesystem canonicalization.
func foldedPath(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
func inside(_ path: String, _ parent: String) -> Bool { foldedPath(path).hasPrefix(foldedPath(parent) + "/") }
func overlap(_ lhs: String, _ rhs: String) -> Bool { foldedPath(lhs) == foldedPath(rhs) || inside(lhs, rhs) || inside(rhs, lhs) }
func pathsAreValid(_ paths: ProfilePaths) -> Bool {
    [paths.root, paths.codex, paths.sqlite, paths.desktop, paths.ipc].allSatisfy(safeAbsolutePath)
        && inside(paths.codex, paths.root) && inside(paths.desktop, paths.root)
        && (paths.sqlite == paths.codex || inside(paths.sqlite, paths.codex))
        && inside(paths.ipc, paths.desktop) && !overlap(paths.codex, paths.desktop)
}
func invalidated(previous: Identity, current: Identity) -> Set<ValidationScope> {
    var scopes = Set<ValidationScope>()
    if previous.cli != current.cli || previous.node != current.node { scopes.formUnion([.cli, .crossProfile]) }
    if previous.app != current.app || previous.appBundlePath != current.appBundlePath || previous.bundledCLI != current.bundledCLI {
        scopes.formUnion([.app, .crossProfile, .connection])
    }
    if previous.paths != current.paths || previous.cwd != current.cwd || previous.profile != current.profile
        || previous.effectiveSettings != current.effectiveSettings || previous.platform != current.platform {
        scopes.formUnion([.cli, .app, .crossProfile, .connection])
    }
    if previous.authBackend != current.authBackend || previous.accountGeneration != current.accountGeneration {
        scopes.formUnion([.cli, .app, .account, .crossProfile, .connection])
    }
    return scopes
}
func evaluate(request: Request, validation: Validation, runtime: RuntimeSnapshot) -> Decision {
    let current = runtime.identity
    guard request.profile == current.profile, request.cwd == current.cwd,
          pathsAreValid(current.paths), safeAbsolutePath(current.cwd) else { return .blocked(.profilePathConflict) }
    guard runtime.observationComplete, runtime.bindingMatches else { return .blocked(.processUnknown) }
    guard !runtime.sessionWriter else { return .blocked(.sessionBusy) }
    switch runtime.process {
    case .runningObserved: return .blocked(.profileBusy)
    case .starting, .launchUnconfirmed, .unknown: return .blocked(.processUnknown)
    case .notRunning: break
    }
    guard validation.source == .supported else { return .blocked(.identityMismatch) }
    guard validation.approvedTarget == request.target else { return .blocked(.approvalStale) }
    let stale = invalidated(previous: validation.identity, current: current)
    let scope: ValidationScope = request.target == .cli ? .cli : .app
    guard !stale.contains(scope) else { return .blocked(.approvalStale) }
    // Authentication is a separate restricted path; it must not require general-use approval.
    if request.operation == .authCheck || request.operation == .login {
        guard request.target == .cli else { return .blocked(.capabilityUnknown) }
        guard validation.restrictedAuth == .supported else { return .blocked(.capabilityUnknown) }
        guard runtime.otherProfiles.isEmpty else { return .blocked(.concurrencyUnverified) }
        return .allow
    }
    guard validation.account == .confirmed else { return .blocked(.authUnverified) }
    guard validation.execution == .supported else { return .blocked(.capabilityUnknown) }
    guard validation.observedPaths else { return .blocked(.pathsUnobserved) }
    for other in runtime.otherProfiles {
        guard other.profile != current.profile, pathsAreValid(other.paths),
              !overlap(other.paths.root, current.paths.root), !stale.contains(.crossProfile),
              validation.separation.contains(other) else { return .blocked(.concurrencyUnverified) }
    }
    if case .trial(let stage) = request.operation {
        guard validation.trialPermission == stage else { return .blocked(.approvalRequired) }
        let prerequisites: [Stage] = stage == .basic ? [] : (stage == .extended ? [.basic] : [.basic, .extended])
        guard prerequisites.allSatisfy({ validation.tests[$0] == .passed }) else { return .blocked(.testsIncomplete) }
        return .allow
    }
    guard Stage.allCases.allSatisfy({ validation.tests[$0] == .passed }) else { return .blocked(.testsIncomplete) }
    guard validation.finalApproval else { return .blocked(.approvalRequired) }
    return .allow
}
