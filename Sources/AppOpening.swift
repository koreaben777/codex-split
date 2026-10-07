import Foundation

// Configuration is location data, never an account/approval/observation record.
// Production has no registry/import switch until a supported runtime adapter is verified.
struct AppProfileConfiguration: Codable, Equatable {
    var schemaVersion = 1
    var profileId: ProfileID
    var appBundlePath: String
    var paths: ProfilePaths
    var cwd: String
    func validate(for profile: ProfileID) throws {
        guard schemaVersion == 1, profileId == profile else { throw Failure.stateInvalid }
        guard safeAbsolutePath(appBundlePath), appBundlePath.hasSuffix(".app"), pathsAreValid(paths),
              safeAbsolutePath(cwd), !overlap(appBundlePath, paths.root) else { throw Failure.profilePathConflict }
    }
    func matches(_ identity: Identity) -> Bool {
        profileId == identity.profile && appBundlePath == identity.appBundlePath && paths == identity.paths && cwd == identity.cwd
    }
    static func decode(_ data: Data, for profile: ProfileID) throws -> Self {
        guard data.count <= 16384, uniqueJSONKeys(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "profileId", "appBundlePath", "paths", "cwd"],
              let paths = object["paths"] as? [String: Any], Set(paths.keys) == ["root", "codex", "sqlite", "desktop", "ipc"],
              let result = try? JSONDecoder().decode(Self.self, from: data) else { throw Failure.stateInvalid }
        try result.validate(for: profile)
        return result
    }
    static func validateSet(_ profiles: [Self]) throws {
        var seen = Set<ProfileID>()
        for (index, profile) in profiles.enumerated() {
            try profile.validate(for: profile.profileId)
            guard seen.insert(profile.profileId).inserted,
                  !profiles.prefix(index).contains(where: { overlap($0.paths.root, profile.paths.root) }),
                  !profiles.contains(where: { overlap(profile.appBundlePath, $0.paths.root) }) else { throw Failure.profilePathConflict }
        }
    }
}

// The existing Coordinator owns locking, durable reservations and launch-time revalidation.
// Only tests supply a supported adapter today; no CLI flag imports synthetic evidence.
func requestAppOpen(profile: ProfileID, configuration: AppProfileConfiguration?, validation: Validation?,
                    coordinator: Coordinator?, adapterCapability: Capability,
                    observe: () throws -> RuntimeSnapshot, launch: (LaunchPlan) throws -> Void,
                    inherited: [String: String] = [:], registration: AppRegistration? = nil) -> AppOpenReply {
    func blocked(_ reason: Failure) -> AppOpenReply { AppOpenReply(profileId: profile, state: .blocked, reason: reason) }
    do {
        guard let configuration else { return blocked(.profileUnconfigured) }
        try configuration.validate(for: profile)
        guard adapterCapability == .supported else { return blocked(.capabilityUnknown) }
        guard let validation else { return blocked(.approvalRequired) }
        guard configuration.matches(validation.identity), validation.approvedTarget == .app else { return blocked(.approvalStale) }
        guard let coordinator else { return blocked(.stateInvalid) }
        let request = Request(profile: profile, target: .app, operation: .run, cwd: configuration.cwd)
        let result = try coordinator.start(request: request, validation: validation, registration: registration, observe: {
            let snapshot = try observe()
            guard snapshot.identity == validation.identity else { throw Failure.approvalStale }
            guard snapshot.observedPaths == configuration.paths else { throw Failure.pathsUnobserved }
            return snapshot
        }, launch: {
            try launch(launchPlan(request: request, identity: validation.identity, inherited: inherited))
        })
        switch result {
        case .allow: return AppOpenReply(profileId: profile, state: .launchRequested, reason: nil)
        case .blocked(.profileBusy): return AppOpenReply(profileId: profile, state: .alreadyRunning, reason: .profileBusy)
        case .blocked(let reason): return blocked(reason)
        }
    } catch let failure as Failure { return blocked(failure) }
    catch { return blocked(.io) }
}

// Revisions are invalidation tokens, never approval or account evidence.
struct AppRegistration: Codable, Equatable {
    let configuration: AppProfileConfiguration
    let revision: UUID
}
struct AppProfileRegistry {
    let store: PrivateStore
    func registration(for profile: ProfileID) throws -> AppRegistration? {
        try store.read().appRegistrations?[profile.rawValue]
    }
    @discardableResult
    func register(_ configuration: AppProfileConfiguration, replacing revision: UUID?) throws -> AppRegistration {
        try configuration.validate(for: configuration.profileId)
        return try store.withLock {
            var state = try store.readLocked()
            guard state.pending.isEmpty, !state.launchUnresolved else { throw Failure.processUnknown }
            var records = state.appRegistrations ?? [:]
            let key = configuration.profileId.rawValue
            guard records[key]?.revision == revision else { throw Failure.approvalStale }
            let record = AppRegistration(configuration: configuration, revision: UUID())
            // Separation evidence binds the entire registry, not just edited locations.
            records = records.mapValues { AppRegistration(configuration: $0.configuration, revision: UUID()) }
            records[key] = record
            try AppProfileConfiguration.validateSet(records.values.map(\.configuration))
            state.appRegistrations = records
            // Other profile approvals may depend on separation from this profile.
            state.validations.removeAll()
            state.appApprovals = nil
            state.manualConnections = nil
            try store.writeLocked(state)
            return record
        }
    }
}
// Internal injection boundary. No production provider/importer is exposed by the CLI.
// Observation and launch must be supplied separately from location-only registration.
struct AppRuntimeAdapter {
    let registration: AppRegistration
    let capability: Capability
    let validation: Validation
    let observe: () throws -> RuntimeSnapshot
    let launch: (LaunchPlan) throws -> Void
    func open(using coordinator: Coordinator, inherited: [String: String] = [:]) -> AppOpenReply {
        requestAppOpen(profile: registration.configuration.profileId,
            configuration: registration.configuration, validation: validation, coordinator: coordinator,
            adapterCapability: capability, observe: observe, launch: launch,
            inherited: inherited, registration: registration)
    }
}
