import Foundation

// Supplied by the trial verifier, never inferred from a consent answer or location file.
struct AppTrialEvidence {
    let registrationRevision: UUID
    let identity: Identity
    let domain: AppEvidenceDomain
    let tests: [Stage: TestResult]
    let separation: [Identity]
    let recordedAt: Date
    let expiresAt: Date
}
struct AppApprovalRecord: Codable, Equatable {
    let validation: Validation
    let domain: AppEvidenceDomain
    let approvedAt: Date
    let expiresAt: Date
}
struct AppApprovalProposal {
    let registration: AppRegistration
    let identity: Identity
    let domain: AppEvidenceDomain
    let expiresAt: Date
}
struct AppApprovalService {
    let store: PrivateStore
    let domain: AppEvidenceDomain
    var now: () -> Date = { Date() }

    // Injection is a development-only boundary. Production cannot accept a fake answer closure.
    func approve(registration: AppRegistration, trials: AppTrialEvidence,
                 observe: () throws -> AppRuntimeObservation,
                 ask: (AppApprovalProposal) -> ApprovalAnswer) throws -> Decision {
        guard domain == .synthetic else { return .blocked(.capabilityUnknown) }
        return try consent(registration: registration, trials: trials, observe: observe, ask: ask)
    }
    func approveInTerminal(registration: AppRegistration, trials: AppTrialEvidence,
                           observe: () throws -> AppRuntimeObservation) throws -> Decision {
        guard domain == .production else { return .blocked(.capabilityUnknown) }
        return try consent(registration: registration, trials: trials, observe: observe, ask: appTerminalApproval)
    }
    private func consent(registration: AppRegistration, trials: AppTrialEvidence,
                         observe: () throws -> AppRuntimeObservation,
                         ask: (AppApprovalProposal) -> ApprovalAnswer) throws -> Decision {
        try store.withLock {
            var state = try store.readLocked()
            guard state.pending.isEmpty, !state.launchUnresolved else { return .blocked(.processUnknown) }
            guard state.appRegistrations?[registration.configuration.profileId.rawValue] == registration else { return .blocked(.approvalStale) }
            let before = try observe()
            try check(before, registration: registration, at: now())
            guard trials.registrationRevision == registration.revision, trials.identity == before.snapshot.identity,
                  trials.domain == domain, trials.recordedAt <= now(), now() < trials.expiresAt else { return .blocked(.approvalStale) }
            var validation = Validation(identity: before.snapshot.identity, source: before.source,
                restrictedAuth: before.restrictedAuth, execution: before.execution, account: before.account,
                observedPaths: before.snapshot.observedPaths == registration.configuration.paths,
                tests: trials.tests, finalApproval: false, approvedTarget: .app, trialPermission: nil,
                separation: trials.separation, appRegistrationRevision: registration.revision)
            let request = Request(profile: registration.configuration.profileId, target: .app, operation: .run, cwd: registration.configuration.cwd)
            let eligible = evaluate(request: request, validation: validation, runtime: before.snapshot)
            guard eligible == .blocked(.approvalRequired) else { return eligible }
            // Consent persists only for the independently verified trial lifetime.
            // Each use still requires a fresh observation; a sample TTL is not consent TTL.
            let expiry = trials.expiresAt
            guard ask(AppApprovalProposal(registration: registration, identity: validation.identity, domain: domain, expiresAt: expiry)) == .accepted else { return .blocked(.approvalRequired) }
            let after = try observe(), approvedAt = now()
            try check(after, registration: registration, at: approvedAt)
            guard after.snapshot.identity == before.snapshot.identity,
                  after.source == before.source, after.restrictedAuth == before.restrictedAuth,
                  after.execution == before.execution, after.account == before.account,
                  approvedAt < expiry else { return .blocked(.approvalStale) }
            validation.finalApproval = true // Only after an explicit accepted answer.
            let checked = evaluate(request: request, validation: validation, runtime: after.snapshot)
            guard checked == .allow else { return checked }
            try inspectPaths(after.snapshot.identity.paths)
            state.appApprovals = state.appApprovals ?? [:]
            state.appApprovals?[request.profile.rawValue] = AppApprovalRecord(validation: validation, domain: domain,
                approvedAt: approvedAt, expiresAt: expiry)
            try store.writeLocked(state)
            return .allow
        }
    }
    private func check(_ observation: AppRuntimeObservation, registration: AppRegistration, at date: Date) throws {
        guard observation.registration == registration, observation.domain == domain,
              observation.observedAt <= date, date < observation.expiresAt,
              registration.configuration.matches(observation.snapshot.identity) else { throw Failure.approvalStale }
        guard observation.source == .supported, observation.restrictedAuth == .supported,
              observation.execution == .supported else { throw Failure.capabilityUnknown }
        guard observation.account == .confirmed else { throw Failure.authUnverified }
        guard observation.snapshot.observedPaths == registration.configuration.paths else { throw Failure.pathsUnobserved }
    }
    func approved(registration: AppRegistration, observation: AppRuntimeObservation) throws -> AppApprovalRecord {
        try store.withLock {
            try approvedLocked(registration: registration, observation: observation, state: store.readLocked())
        }
    }
    // Caller must hold this store's lock. Reuses its snapshot without nested locking.
    func approvedLocked(registration: AppRegistration, observation: AppRuntimeObservation, state: SavedState) throws -> AppApprovalRecord {
        let date = now()
        try check(observation, registration: registration, at: date)
        guard state.appRegistrations?[registration.configuration.profileId.rawValue] == registration,
              let record = state.appApprovals?[registration.configuration.profileId.rawValue],
              record.domain == domain, record.approvedAt <= date, date < record.expiresAt,
              record.validation.appRegistrationRevision == registration.revision,
              record.validation.identity == observation.snapshot.identity,
              record.validation.finalApproval else { throw Failure.approvalStale }
        return record
    }

}
private func appTerminalApproval(_ proposal: AppApprovalProposal) -> ApprovalAnswer {
    // JSON string encoding escapes terminal control characters in binary metadata.
    func quoted(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
    let identity = proposal.identity
    print("App approval / " + proposal.domain.rawValue + " / " + identity.profile.rawValue)
    print("Registration revision: " + proposal.registration.revision.uuidString)
    print("App: " + quoted(identity.appBundlePath))
    for (name, binary) in [("app", identity.app), ("CLI", identity.cli), ("bundled CLI", identity.bundledCLI)] {
        print(name + ": " + [binary.path, binary.version, binary.build, binary.fingerprint].map(quoted).joined(separator: " / "))
    }
    print("Paths: " + [identity.paths.root, identity.paths.codex, identity.paths.sqlite, identity.paths.desktop, identity.paths.ipc].map(quoted).joined(separator: " / "))
    print("Consent / trial evidence expires: " + ISO8601DateFormatter().string(from: proposal.expiresAt))
    // cs_answer requires the foreground terminal; EOF/interruption cannot approve.
    return terminalApproval(Request(profile: identity.profile, target: .app, operation: .run, cwd: identity.cwd))
}
