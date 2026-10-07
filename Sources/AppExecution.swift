import Foundation

// No public initializer with a real-process default. Synthetic callbacks cannot be
// attached to a production backend, and the current reference contract is uncommissioned.
struct AppLaunchBackend {
    let domain: AppEvidenceDomain
    private let contract: AppVersionContract?
    private let submit: ((LaunchPlan) throws -> Void)?
    private init(domain: AppEvidenceDomain, contract: AppVersionContract?, submit: ((LaunchPlan) throws -> Void)?) {
        self.domain = domain; self.contract = contract; self.submit = submit
    }
    static let uncommissioned = AppLaunchBackend(domain: .production, contract: nil, submit: nil)
    static func synthetic(identity: Identity, submit: @escaping (LaunchPlan) throws -> Void) -> Self {
        Self(domain: .synthetic, contract: .synthetic(identity: identity), submit: submit)
    }
    static func production(contract: AppVersionContract) throws -> Self {
        guard contract.domain == .production, contract.desktopIsolation == .supported else { throw Failure.capabilityUnknown }
        let opener = OfficialAppOpener()
        return Self(domain: .production, contract: contract, submit: opener.submit)
    }
    func launch(_ plan: LaunchPlan, approval: AppApprovalRecord, observation: AppRuntimeObservation, now: Date) throws {
        guard let contract, let submit, contract.domain == domain,
              contract.desktopIsolation == .supported, contract.matches(observation.snapshot.identity) else { throw Failure.capabilityUnknown }
        let registration = observation.registration, validation = approval.validation
        guard observation.domain == domain, approval.domain == domain,
              approval.approvedAt <= now, now < approval.expiresAt,
              observation.observedAt <= now, now < observation.expiresAt,
              validation.identity == observation.snapshot.identity,
              validation.appRegistrationRevision == registration.revision,
              registration.configuration.matches(validation.identity) else { throw Failure.approvalStale }
        guard observation.source == .supported, observation.execution == .supported,
              observation.restrictedAuth == .supported else { throw Failure.capabilityUnknown }
        guard observation.account == .confirmed else { throw Failure.authUnverified }
        guard observation.snapshot.observedPaths == registration.configuration.paths else { throw Failure.pathsUnobserved }
        let request = Request(profile: registration.configuration.profileId, target: .app, operation: .run, cwd: registration.configuration.cwd)
        let decision = evaluate(request: request, validation: validation, runtime: observation.snapshot)
        if case .blocked(let failure) = decision { throw failure }
        let expected = try launchPlan(request: request, identity: validation.identity, inherited: [:])
        guard plan == expected else { throw Failure.invalidArguments }
        try submit(expected)
    }
}

// Real execution leaf, reachable only through the production factory and all launch gates.
// No shell, login, installation, signal forwarding, kill, automatic retry or GUI-close hook.
private final class OfficialAppOpener {
    private var outstanding: Process?
    func submit(_ plan: LaunchPlan) throws {
        guard outstanding == nil, plan.executable == "/usr/bin/open" else { throw Failure.processUnknown }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments; process.environment = plan.environment
        process.currentDirectoryURL = URL(fileURLWithPath: plan.cwd)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        outstanding = process
        do { try process.run() } catch { outstanding = nil; throw Failure.io }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.processUnknown }
            Thread.sleep(forTimeInterval: 0.01)
        }
        outstanding = nil
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.io }
        // open exit 0 means only request acceptance. Coordinator keeps durable pending.
    }
}

struct AppApplicationService {
    let store: PrivateStore
    let domain: AppEvidenceDomain
    let provider: AppObservationProvider
    let backend: AppLaunchBackend
    var now: () -> Date = { Date() }

    func open(_ profile: ProfileID) -> AppOpenReply {
        func blocked(_ failure: Failure) -> AppOpenReply { AppOpenReply(profileId: profile, state: .blocked, reason: failure) }
        do {
            guard domain == provider.domain, domain == backend.domain else { return blocked(.capabilityUnknown) }
            guard let registration = try AppProfileRegistry(store: store).registration(for: profile) else { return blocked(.profileUnconfigured) }
            let approvals = AppApprovalService(store: store, domain: domain, now: now)
            let first = try provider.observe(registration)
            let record = try approvals.approved(registration: registration, observation: first)
            // Invoked only by Coordinator while its store lock is held. Revalidate the
            // persisted explicit consent on every observation and immediately before submit.
            func current() throws -> AppRuntimeObservation {
                let observation = try provider.observe(registration)
                let latest = try approvals.approvedLocked(registration: registration, observation: observation, state: store.readLocked())
                guard latest == record else { throw Failure.approvalStale }
                return observation
            }
            return requestAppOpen(profile: profile, configuration: registration.configuration,
                validation: record.validation, coordinator: Coordinator(store: store), adapterCapability: first.execution,
                observe: { try current().snapshot }, launch: { plan in
                    try backend.launch(plan, approval: record, observation: current(), now: now())
                }, registration: registration)
        } catch let failure as Failure { return blocked(failure) }
        catch { return blocked(.io) }
    }

    func approveInTerminal(_ profile: ProfileID, trials: AppTrialEvidence) throws -> Decision {
        guard domain == .production, provider.domain == .production, backend.domain == .production else { return .blocked(.capabilityUnknown) }
        guard let registration = try AppProfileRegistry(store: store).registration(for: profile) else { return .blocked(.profileUnconfigured) }
        return try AppApprovalService(store: store, domain: domain, now: now).approveInTerminal(
            registration: registration, trials: trials, observe: { try provider.observe(registration) })
    }
}

// CLI composition boundary. The shipped context has no operational store or provider;
// there is no command-line/environment switch selecting the synthetic constructor.
struct AppCommandContext {
    private let service: AppApplicationService?
    private let trials: ((ProfileID) throws -> AppTrialEvidence)?
    static let uncommissioned = AppCommandContext(service: nil, trials: nil)
    static func prepared(service: AppApplicationService, trials: @escaping (ProfileID) throws -> AppTrialEvidence) -> Self {
        Self(service: service, trials: trials)
    }
    func open(_ profile: ProfileID) -> AppOpenReply {
        service?.open(profile) ?? AppOpenReply(profileId: profile, state: .blocked, reason: .profileUnconfigured)
    }
    func approve(_ command: Command) throws -> Decision {
        guard command.name == "approve", command.target == .app, command.stage == .day,
              let profile = command.profile, let cwd = command.cwd else { return .blocked(.approvalRequired) }
        guard let service, let trials else { return .blocked(.approvalRequired) }
        guard let registration = try AppProfileRegistry(store: service.store).registration(for: profile),
              registration.configuration.cwd == cwd else { return .blocked(.approvalStale) }
        return try service.approveInTerminal(profile, trials: trials(profile))
    }
}
