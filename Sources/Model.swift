import Foundation

enum Target: String, Codable { case cli, app }
enum Capability: String, Codable { case supported, unsupported, unknown }
enum AccountState: String, Codable { case unverified, confirmed, stale, mismatch }
enum Stage: String, Codable, CaseIterable { case basic, extended, day }
enum TestResult: String, Codable { case passed, failed, notRun, inconclusive }
enum ValidationScope: String, Hashable { case cli, app, account, crossProfile, connection }
enum ProcessState: String, Codable {
    case notRunning = "not-running", starting, runningObserved = "running-observed"
    case launchUnconfirmed = "launch-unconfirmed", unknown
}
struct BinaryIdentity: Codable, Equatable {
    var path: String
    var version: String
    var build: String
    var fingerprint: String
    var provenance: String
}
struct ProfilePaths: Codable, Equatable {
    var root: String
    var codex: String
    var sqlite: String
    var desktop: String
    var ipc: String
}
struct Identity: Codable, Equatable {
    var profile: ProfileID
    var cli: BinaryIdentity
    var app: BinaryIdentity
    var bundledCLI: BinaryIdentity
    var appBundlePath: String
    var node: BinaryIdentity?
    var paths: ProfilePaths
    var cwd: String
    var effectiveSettings: String
    var authBackend: String
    var accountGeneration: String
    var platform: String
}
struct Validation: Codable, Equatable {
    var identity: Identity
    var source: Capability
    var restrictedAuth: Capability
    var execution: Capability
    var account: AccountState
    var observedPaths: Bool
    var tests: [Stage: TestResult]
    var finalApproval: Bool
    var approvedTarget: Target
    var trialPermission: Stage?
    var separation: [Identity]
    // Captured by the evidence/approval producer; adapters must never fill this in.
    var appRegistrationRevision: UUID? = nil
}
enum Operation: Equatable { case run, authCheck, login, trial(Stage) }
struct Request: Equatable {
    var profile: ProfileID
    var target: Target
    var operation: Operation
    var cwd: String
}
struct RuntimeSnapshot {
    var identity: Identity
    var process: ProcessState = .unknown
    var sessionWriter = false
    var otherProfiles: [Identity] = []
    var observationComplete = false
    var bindingMatches = false
    var observedPaths: ProfilePaths?
    var mainProcess: ProcessEvidence?
}
enum Decision: Equatable {
    case allow, blocked(Failure)
    var isBlocked: Bool { if case .blocked = self { return true }; return false }
}
struct ProcessEvidence: Codable, Equatable {
    var pid: Int32
    var startedAt: Double
    var uid: UInt32
    var executable: String
    var fingerprint: String
    var profile: ProfileID
    var paths: ProfilePaths
    var parentPID: Int32
}
struct LaunchPlan: Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var cwd: String
}
struct ProfileStatus: Codable {
    struct ProcessStatus: Codable { var state: ProcessState; var identity: ProcessEvidence? }
    struct PathStatus: Codable { var expected: String?; var observed: String?; var state: String }
    struct Connection: Codable {
        var capability = "manual-only"
        var state = "unknown"
        var manualRecord: [String: String]?
        var note = "자동 확인 불가 · 공식 앱에서 로컬 연결 상태를 확인하세요."
    }
    var schemaVersion = 1
    var profileId: ProfileID
    var observedAt = ISO8601DateFormatter().string(from: Date())
    var process: ProcessStatus
    var paths: [String: PathStatus]
    var profileBinding: String
    var account: [String: String]
    var compatibility: [String: String]
    var localConnection = Connection()
    var nextAction: String
}

struct Command {
    var name: String
    var profile: ProfileID?
    var target: Target?
    var stage: Stage?
    var cwd: String?
    var json = false
    static func parse(_ args: [String]) throws -> Command {
        guard let name = args.first else { throw Failure.invalidArguments }
        if ["profiles", "doctor", "help"].contains(name), args.count == 1 {
            return Command(name: name)
        }
        guard args.count >= 2, let profile = ProfileID(rawValue: args[1]) else { throw Failure.invalidArguments }
        var result = Command(name: name, profile: profile)
        switch name {
        case "status":
            guard args.count == 2 || (args.count == 3 && args[2] == "--json") else { throw Failure.invalidArguments }
            result.json = args.count == 3
        case "update-check", "update-plan":
            guard profile == .work, args.count == 2 || (args.count == 3 && args[2] == "--json") else { throw Failure.invalidArguments }
            result.json = args.count == 3
        case "app":
            guard args.count == 2 || (args.count == 3 && args[2] == "--json") else { throw Failure.invalidArguments }
            result.target = .app; result.json = args.count == 3
        case "login", "verify-auth":
            guard args.count == 2 else { throw Failure.invalidArguments }
            result.target = name == "app" ? .app : .cli
        case "cli":
            guard args.count == 4, args[2] == "--cwd", safeAbsolutePath(args[3]) else { throw Failure.invalidArguments }
            result.target = .cli; result.cwd = args[3]
        case "verify", "approve":
            guard args.count == 8, args[2] == "--target", let target = Target(rawValue: args[3]),
                  args[4] == "--stage", let stage = Stage(rawValue: args[5]),
                  args[6] == "--cwd", safeAbsolutePath(args[7]) else { throw Failure.invalidArguments }
            result.target = target; result.stage = stage; result.cwd = args[7]
        default: throw Failure.invalidArguments
        }
        return result
    }
}
