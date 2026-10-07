import Foundation
import AppKit

func submitWithinConsent<T>(expiresAt: Date, now: () -> Date, finalCheck: () throws -> Void,
                            submit: () throws -> T) throws -> T {
    try finalCheck()
    guard now() < expiresAt else { throw Failure.approvalRequired }
    return try submit()
}

// One official-app launch target. Neither a plan nor its receipt is login consent or normal-use approval.
struct AppInitialTrialPlan: Codable, Equatable {
    let requestID: UUID
    let requestedAt: Date
    let domain: AppEvidenceDomain
    let root: String
    let bundlePath: String
    let executablePath: String
    let appVersion: String
    let appBuild: String
    let appFingerprint: String
    let cliExecutablePath: String
    let cliVersion: String
    let cliBuild: String
    let cliFingerprint: String
    static func workTarget(_ pins: WorkAppPins, requestedAt: Date, requestID: UUID = UUID()) -> Self {
        Self(requestID: requestID, requestedAt: requestedAt, domain: .production, root: CodexSplitPaths.workRoot,
            bundlePath: CodexSplitPaths.officialBundle, executablePath: CodexSplitPaths.officialExecutable,
            appVersion: pins.appVersion, appBuild: pins.appBuild, appFingerprint: pins.appFingerprint,
            cliExecutablePath: CodexSplitPaths.officialCLI,
            cliVersion: pins.cliVersion, cliBuild: pins.cliBuild, cliFingerprint: pins.cliFingerprint)
    }
    // The only work target that may be launched.
    static func workSetup(requestedAt: Date, requestID: UUID = UUID()) -> Self {
        workTarget(WorkAppPins.current, requestedAt: requestedAt, requestID: requestID)
    }
    // Previously approved targets: preserved records stay readable, never launchable.
    var isHistoricalWorkPlan: Bool {
        domain == .production && WorkAppPins.history.contains { self == .workTarget($0, requestedAt: requestedAt, requestID: requestID) }
    }
    var isRecordedWorkPlan: Bool { self == .workSetup(requestedAt: requestedAt, requestID: requestID) || isHistoricalWorkPlan }
    var isPinnedProductionPlan: Bool { self == .workSetup(requestedAt: requestedAt, requestID: requestID) }
}
// Exact official identities. A candidate changes only the managed block below, in an
// isolated copy (scripts/update-work.py); the edge it adds still needs a verified
// replacement receipt, the user's consent and two new acceptance visits.
struct WorkAppPins: Equatable {
    let appVersion: String
    let appBuild: String
    let appFingerprint: String
    let cliVersion: String
    let cliBuild: String
    let cliFingerprint: String
    let resourcesSHA256: String
    // BEGIN update-work managed pins
    static let current: Self = Self(appVersion: "26.930.61225", appBuild: "13232", appFingerprint: "68e7fa91d6feb7ed8ac86c55fdaf043ef137557ccca9a104cf1ff9fa7ef6af25", cliVersion: "0.160.1", cliBuild: "1", cliFingerprint: "cc0a05e34876414280a79726153d0fe8d55c93f704ef6c292ec409bfe36d5b06", resourcesSHA256: "88b8cce6f627771bf341f5a6bb464ad220749b0d442d44f618d7741c2de7318b")
    static let history: [Self] = [
    ]
    static let updateReviewID: String? = nil
    // END update-work managed pins
    // A reviewed version edge always starts at the newest historical target.
    static var updateEdgeSource: Self? { updateReviewID == nil ? nil : history.first }
}
struct AppInitialTrialReceipt: Codable, Equatable {
    enum Source: String, Codable { case newLaunchCompletion }
    let plan: AppInitialTrialPlan
    let instanceToken: UUID
    let pid: Int32
    let launchedAt: Date
    let source: Source
    func matches(_ plan: AppInitialTrialPlan, now: Date) -> Bool {
        self.plan == plan && pid > 0 && launchedAt >= plan.requestedAt && launchedAt <= now
    }
}
enum AppTrialManualAccount: String, Codable { case confirmed, mismatch, loginRequired }
enum AppInitialTrialState: String, Codable { case submitted, ownedUIObserved, accountReported, mainAppExitedAfterQuitIntent }
struct AppInitialTrialTerminationReceipt: Codable, Equatable {
    let instance: AppInitialTrialReceipt
    let observedAt: Date
    // Exit after a user Quit intent, not proof of exit cause or helper cleanup.
    let mainAppExitObservedAfterQuitIntent: Bool
}
struct AppInitialTrialSession: Codable, Equatable {
    let receipt: AppInitialTrialReceipt
    private(set) var state: AppInitialTrialState = .submitted
    private(set) var manualAccount: AppTrialManualAccount?
    private(set) var terminationReceipt: AppInitialTrialTerminationReceipt?
    // No API converts this session into authentication or general execution approval.
    var loginAuthorized: Bool { false }
    var normalUseAuthorized: Bool { false }
    mutating func observeOwnedUI(_ observed: AppInitialTrialReceipt, now: Date) throws {
        guard state == .submitted, observed == receipt, receipt.matches(receipt.plan, now: now) else { throw Failure.processUnknown }
        state = .ownedUIObserved
    }
    mutating func reportAccount(_ report: AppTrialManualAccount, for observed: AppInitialTrialReceipt) throws {
        guard state == .ownedUIObserved, observed == receipt else { throw Failure.processUnknown }
        manualAccount = report
        state = .accountReported
    }
    mutating func recordObservedMainAppExit(_ termination: AppInitialTrialTerminationReceipt, now: Date) throws {
        guard state != .mainAppExitedAfterQuitIntent, termination.instance == receipt,
              termination.mainAppExitObservedAfterQuitIntent, termination.observedAt >= receipt.launchedAt,
              termination.observedAt <= now else { throw Failure.processUnknown }
        terminationReceipt = termination
        state = .mainAppExitedAfterQuitIntent
    }
    func validRecord(now: Date) -> Bool {
        guard receipt.matches(receipt.plan, now: now) else { return false }
        if state == .mainAppExitedAfterQuitIntent {
            guard let terminationReceipt else { return false }
            return terminationReceipt.instance == receipt && terminationReceipt.mainAppExitObservedAfterQuitIntent
                && terminationReceipt.observedAt >= receipt.launchedAt && terminationReceipt.observedAt <= now
        }
        guard terminationReceipt == nil else { return false }
        return (state == .accountReported) == (manualAccount != nil)
    }
}
// Mirrors only the properties of the NSWorkspace completion's NSRunningApplication.
// No process enumeration, activation, launch, or termination operation is exposed here.
protocol AppTrialApplicationObject: AnyObject {
    var trialBundlePath: String? { get }
    var trialExecutablePath: String? { get }
    var trialLaunchDate: Date? { get }
    var trialPID: Int32 { get }
    var trialIsTerminated: Bool { get }
    func isSameApplication(as other: Self) -> Bool
}

// Passive bridge for an object already returned by a future, separately authorized
// NSWorkspace launch completion. No workspace lookup or launch occurs here.
// The owner must keep the main run loop active so AppKit's volatile properties refresh.
extension NSRunningApplication: AppTrialApplicationObject {
    var trialBundlePath: String? { Thread.isMainThread ? bundleURL?.path : nil }
    var trialExecutablePath: String? { Thread.isMainThread ? executableURL?.path : nil }
    var trialLaunchDate: Date? { Thread.isMainThread ? launchDate : nil }
    var trialPID: Int32 { Thread.isMainThread ? processIdentifier : -1 }
    var trialIsTerminated: Bool { Thread.isMainThread && isTerminated }
    func isSameApplication(as other: NSRunningApplication) -> Bool {
        Thread.isMainThread && isEqual(other)
    }
}

final class AppInitialTrialObjectAdapter<Application: AppTrialApplicationObject> {
    let receipt: AppInitialTrialReceipt
    private let application: Application // Retain the completion object through observed exit.
    private var uiConfirmed = false
    private var userQuitAt: Date?
    // 검증된 완료 객체를 관측 수명 동안 유지한다. 이 getter는 앱 제어를 수행하지 않는다.
    var currentApplicationForObservation: Application { application }

    // Observation of a fake completion only; cannot authorize or submit a real launch.
    convenience init(syntheticCompletion application: Application, plan: AppInitialTrialPlan, now: Date) throws {
        guard plan.domain == .synthetic else { throw Failure.capabilityUnknown }
        try self.init(completion: application, plan: plan, now: now)
    }

    private init(completion application: Application, plan: AppInitialTrialPlan, now: Date) throws {
        guard application.trialBundlePath == plan.bundlePath,
              application.trialExecutablePath == plan.executablePath,
              let launchedAt = application.trialLaunchDate,
              !application.trialIsTerminated else { throw Failure.processUnknown }
        let receipt = AppInitialTrialReceipt(plan: plan, instanceToken: UUID(), pid: application.trialPID,
            launchedAt: launchedAt, source: .newLaunchCompletion)
        guard receipt.matches(plan, now: now) else { throw Failure.processUnknown }
        self.application = application
        self.receipt = receipt
    }

    // Passive binding only. The sole production launch call lives behind real preflight
    // and durable reservation in ProductionInitialTrial. No receipt import is exposed.
    static func productionCompletion(_ application: NSRunningApplication, plan: AppInitialTrialPlan,
                                     submittedAt: Date, now: Date) throws -> AppInitialTrialObjectAdapter<NSRunningApplication>
        where Application == NSRunningApplication {
        guard Thread.isMainThread, plan.domain == .production,
              plan.isPinnedProductionPlan,
              let launchedAt = application.launchDate, launchedAt >= submittedAt,
              submittedAt >= plan.requestedAt, submittedAt <= now else { throw Failure.identityMismatch }
        return try AppInitialTrialObjectAdapter<NSRunningApplication>(completion: application, plan: plan, now: now)
    }

    // A future caller supplies NSWorkspace's frontmost object, plus the user's UI confirmation.
    func observeOwnedUI(frontmost: Application?, userConfirmed: Bool, now: Date) throws -> AppInitialTrialReceipt {
        guard userConfirmed, userQuitAt == nil else { throw Failure.processUnknown }
        try requireOwnedFrontmost(frontmost, now: now)
        uiConfirmed = true
        return receipt
    }

    // Records the user's decision to use Quit on the identified frontmost app.
    // It sends no Quit event. A subsequent exit is observed separately.
    func recordUserQuitIntent(frontmost: Application?, now: Date) throws {
        guard uiConfirmed, userQuitAt == nil else { throw Failure.processUnknown }
        try requireOwnedFrontmost(frontmost, now: now)
        userQuitAt = now
    }

    // nil means still waiting; a timeout is unknown and does not clear a durable reservation.
    // This confirms main-app exit after user Quit, not exit cause or absence of helpers.
    func observeTermination(now: Date) throws -> AppInitialTrialTerminationReceipt? {
        guard let userQuitAt, now >= userQuitAt,
              now.timeIntervalSince(userQuitAt) <= 30 else { throw Failure.processUnknown }
        guard application.trialIsTerminated else { return nil }
        // Metadata can disappear after exit; retain the completion's validated receipt.
        return AppInitialTrialTerminationReceipt(instance: receipt, observedAt: now, mainAppExitObservedAfterQuitIntent: true)
    }

    private func requireOwnedFrontmost(_ frontmost: Application?, now: Date) throws {
        guard let frontmost, application.isSameApplication(as: frontmost),
              !application.trialIsTerminated, receipt.matches(receipt.plan, now: now),
              application.trialBundlePath == receipt.plan.bundlePath,
              application.trialExecutablePath == receipt.plan.executablePath,
              application.trialLaunchDate == receipt.launchedAt else { throw Failure.processUnknown }
    }
    func matchesFrontmost(_ application: Application?, now: Date) -> Bool {
        (try? requireOwnedFrontmost(application, now: now)) != nil
    }
}
