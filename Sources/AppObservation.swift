import Foundation
import Darwin

enum AppEvidenceDomain: String, Codable { case synthetic, production }
struct AppRuntimeObservation {
    let registration: AppRegistration
    let snapshot: RuntimeSnapshot
    let source: Capability
    let restrictedAuth: Capability
    let execution: Capability
    let account: AccountState
    let observedAt: Date
    let expiresAt: Date
    let domain: AppEvidenceDomain
}

// This is a version contract, not a user approval or a config-importable capability flag.
struct AppVersionContract {
    let domain: AppEvidenceDomain
    let appVersion: String
    let appBuild: String
    let serverVersion: String
    let serverBuild: String
    let desktopIsolation: Capability
    private init(domain: AppEvidenceDomain, appVersion: String, appBuild: String,
                 serverVersion: String, serverBuild: String, desktopIsolation: Capability) {
        self.domain = domain; self.appVersion = appVersion; self.appBuild = appBuild
        self.serverVersion = serverVersion; self.serverBuild = serverBuild; self.desktopIsolation = desktopIsolation
    }
    // Public CLI/app-server schema does not document desktop auth/IPC isolation.
    // Updating version strings must never turn that missing contract into support.
    static let historicalReference = AppVersionContract(domain: .production, appVersion: "26.928.40906", appBuild: "12694",
        serverVersion: "0.159.2", serverBuild: "1", desktopIsolation: .unknown)
    static func synthetic(identity: Identity) -> Self {
        Self(domain: .synthetic, appVersion: identity.app.version, appBuild: identity.app.build,
             serverVersion: identity.bundledCLI.version, serverBuild: identity.bundledCLI.build, desktopIsolation: .supported)
    }
    func matches(_ identity: Identity) -> Bool {
        identity.app.version == appVersion && identity.app.build == appBuild
            && identity.bundledCLI.version == serverVersion && identity.bundledCLI.build == serverBuild
    }
}

struct AppEvidenceStamp: Equatable {
    let registration: AppRegistration
    let identity: Identity
    let domain: AppEvidenceDomain
    let observedAt: Date
    let expiresAt: Date
    func isCurrent(for registration: AppRegistration, identity: Identity, domain: AppEvidenceDomain, now: Date) -> Bool {
        self.registration == registration && self.identity == identity && self.domain == domain
            && observedAt <= now && expiresAt > now && expiresAt > observedAt
            && expiresAt.timeIntervalSince(observedAt) <= 30
    }
}
struct AppIdentityReading { let stamp: AppEvidenceStamp; let officialSource: Capability }
struct AppStorageReading { let stamp: AppEvidenceStamp; let actualPaths: ProfilePaths }
enum AppAccountBinding { case cliOnly, application }
struct AppAccountReading { let stamp: AppEvidenceStamp; let state: AccountState; let binding: AppAccountBinding }
struct AppProcessReading {
    let stamp: AppEvidenceStamp
    let recordedMain: ProcessEvidence?
    let candidates: [ProcessEvidence]
    let servers: [ProcessEvidence]
    let complete: Bool
    // nil means unobserved, not false/empty. ps/lsof alone cannot supply these facts.
    let sessionWriter: Bool?
    let otherProfiles: [Identity]?
    let expectedUID: UInt32
}
struct AppObservationIO {
    // Explicitly supplied acquisition functions. No defaults start an app-server, inspect
    // credentials, run ps/lsof, or infer effective paths from environment/config strings.
    let identity: (AppRegistration) throws -> AppIdentityReading
    let storage: (AppRegistration) throws -> AppStorageReading?
    let account: (AppRegistration) throws -> AppAccountReading?
    let processes: (AppRegistration) throws -> AppProcessReading?
}
struct AppObservationProvider {
    let domain: AppEvidenceDomain
    let contract: AppVersionContract
    let io: AppObservationIO
    let now: () -> Date
    func observe(_ registration: AppRegistration) throws -> AppRuntimeObservation {
        try registration.configuration.validate(for: registration.configuration.profileId)
        guard contract.domain == domain else { throw Failure.capabilityUnknown }
        let first = try io.identity(registration)
        let identity = first.stamp.identity
        guard registration.configuration.matches(identity),
              first.stamp.isCurrent(for: registration, identity: identity, domain: domain, now: now()) else { throw Failure.approvalStale }
        let storage = try io.storage(registration)
        let account = try io.account(registration)
        let processes = try io.processes(registration)
        let last = try io.identity(registration)
        let time = now()
        guard last.stamp.identity == identity,
              first.stamp.isCurrent(for: registration, identity: identity, domain: domain, now: time),
              last.stamp.isCurrent(for: registration, identity: identity, domain: domain, now: time) else { throw Failure.approvalStale }
        func valid(_ stamp: AppEvidenceStamp) -> Bool { stamp.isCurrent(for: registration, identity: identity, domain: domain, now: time) }
        var expiry = min(first.stamp.expiresAt, last.stamp.expiresAt)
        var snapshot = RuntimeSnapshot(identity: identity)
        if let process = processes, valid(process.stamp), process.sessionWriter != nil, process.otherProfiles != nil {
            expiry = min(expiry, process.stamp.expiresAt)
            snapshot = observeApp(identity: identity, recordedMain: process.recordedMain,
                candidates: process.candidates, servers: process.servers, complete: process.complete,
                pending: false, expectedUID: process.expectedUID)
            snapshot.sessionWriter = process.sessionWriter!
            snapshot.otherProfiles = process.otherProfiles!
        }
        if let storage, valid(storage.stamp), storage.actualPaths == identity.paths {
            expiry = min(expiry, storage.stamp.expiresAt)
            snapshot.observedPaths = storage.actualPaths
        } else {
            // Process association is not authoritative effective DB/IPC observation.
            snapshot.observedPaths = nil
        }
        var accountState = AccountState.unverified
        if let account, valid(account.stamp), account.binding == .application {
            accountState = account.state
            expiry = min(expiry, account.stamp.expiresAt)
        }
        let source: Capability = first.officialSource == .supported && last.officialSource == .supported ? .supported : .unknown
        let supported = source == .supported && contract.matches(identity)
        return AppRuntimeObservation(registration: registration, snapshot: snapshot, source: source,
            restrictedAuth: supported && accountState != .unverified ? .supported : .unknown,
            execution: supported ? contract.desktopIsolation : .unknown, account: accountState,
            observedAt: time, expiresAt: expiry, domain: domain)
    }
}

// Concrete file metadata acquisition, with injectable reads for synthetic fixtures.
// It never executes the app or CLI and never reads config, databases, auth or logs.
struct AppBinaryFiles {
    let read: (String) throws -> Data
    let canonicalPath: (String) -> String
    let digest: (String) -> String?
    let signature: (String) -> SignatureReport
    static func localReadOnly() -> Self {
        Self(read: { path in
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.io }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= 65536 else { throw Failure.stateInvalid }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Failure.io }
                if count == 0 { return result }
                result.append(contentsOf: buffer.prefix(count))
                guard result.count <= 65536 else { throw Failure.stateInvalid }
            }
        },
             canonicalPath: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
             digest: fileDigest, signature: inspectSignature)
    }
}
struct AppBinaryReading {
    let app: BinaryIdentity
    let server: BinaryIdentity
    let officialSource: Capability
}
func readAppBinaries(bundle: String, files: AppBinaryFiles) throws -> AppBinaryReading {
    guard safeAbsolutePath(bundle), bundle.hasSuffix(".app"), files.canonicalPath(bundle) == bundle else { throw Failure.identityMismatch }
    func plist(_ path: String) throws -> [String: Any] {
        guard files.canonicalPath(path) == path else { throw Failure.identityMismatch }
        let data = try files.read(path)
        guard data.count <= 65536, let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure.stateInvalid }
        return object
    }
    let info = try plist(bundle + "/Contents/Info.plist")
    guard info["CFBundleIdentifier"] as? String == "com.openai.codex",
          let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
          !executable.contains("/"), executable != ".", executable != "..",
          let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
          let build = info["CFBundleVersion"] as? String, !build.isEmpty else { throw Failure.identityMismatch }
    let nested = bundle + "/Contents/Resources/codex-cli/CodexCLI.app"
    let nestedInfo = try plist(nested + "/Contents/Info.plist")
    let packagePath = bundle + "/Contents/Resources/codex-cli/codex-package.json"
    guard files.canonicalPath(packagePath) == packagePath else { throw Failure.identityMismatch }
    let packageData = try files.read(packagePath)
    guard packageData.count <= 65536, uniqueJSONKeys(packageData),
          let package = try JSONSerialization.jsonObject(with: packageData) as? [String: Any],
          let serverVersion = package["version"] as? String, !serverVersion.isEmpty,
          let serverBuild = nestedInfo["CFBundleVersion"] as? String, !serverBuild.isEmpty,
          nestedInfo["CFBundleExecutable"] as? String == "codex" else { throw Failure.identityMismatch }
    let appPath = bundle + "/Contents/MacOS/" + executable
    let serverPath = nested + "/Contents/MacOS/codex"
    guard safeAbsolutePath(appPath), files.canonicalPath(appPath) == appPath, files.canonicalPath(serverPath) == serverPath,
          let appHash = files.digest(appPath), let serverHash = files.digest(serverPath),
          [appHash, serverHash].allSatisfy({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) else { throw Failure.identityMismatch }
    let appSignature = files.signature(bundle), serverSignature = files.signature(nested)
    let official = [appSignature, serverSignature].allSatisfy { $0.state == "valid-openai" && $0.team == "2DC432GLL2" && !($0.cdhash?.isEmpty ?? true) }
    return AppBinaryReading(app: BinaryIdentity(path: appPath, version: version, build: build, fingerprint: appHash, provenance: official ? "openai-signed" : "unverified"),
        server: BinaryIdentity(path: serverPath, version: serverVersion, build: serverBuild, fingerprint: serverHash, provenance: official ? "openai-signed" : "unverified"),
        officialSource: official ? .supported : .unknown)
}
