import Foundation
import Darwin

// 동기 NSWorkspace 대기는 활성 main dispatch 블록 밖의 RunLoop timer에서 시작한다.
final class WorkDailyStartScheduler {
    private var timer: Timer?
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func schedule() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        let scheduled = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            self.action()
        }
        timer = scheduled
        RunLoop.main.add(scheduled, forMode: .common)
    }
}
enum WorkDailyFailureStage: String, Codable {
    case finalVerification, workspaceVerification, workspaceSubmission, workspaceCompletion, completionAttribution
    case workspaceOpening, receiptPersistence, kernelBinding, bindingPersistence, initialHeartbeat
    case duplicateActivation, observerPoll, heartbeatVerification, heartbeatPersistence, exitPersistence, observerStop
    var korean: String {
        switch self {
        case .finalVerification: return "최종 사전 검사"
        case .workspaceVerification: return "실행 경로·서명 검사"
        case .workspaceSubmission: return "앱 실행 제출"
        case .workspaceCompletion: return "완료 콜백 대기"
        case .completionAttribution: return "완료 객체 귀속 검사"
        case .workspaceOpening: return "앱 열기"
        case .receiptPersistence: return "완료 객체 기록 저장"
        case .kernelBinding: return "커널 세대·종료 관측 연결"
        case .bindingPersistence: return "관측 연결 기록 저장"
        case .initialHeartbeat: return "최초 heartbeat 저장"
        case .duplicateActivation: return "기존 업무 앱 재선택"
        case .observerPoll: return "종료 관측"
        case .heartbeatVerification: return "관측 대상 재검증"
        case .heartbeatPersistence: return "heartbeat 저장"
        case .exitPersistence: return "종료 기록 저장"
        case .observerStop: return "런처 관측 종료"
        }
    }
}
struct WorkDailyDiagnostic: Codable, Equatable {
    let stage: WorkDailyFailureStage
    let reason: Failure
    let recordedAt: Date
    init(stage: WorkDailyFailureStage, error: Error, now: Date) {
        self.stage = stage
        reason = (error as? WorkDailyOpeningFailure)?.reason ?? (error as? Failure) ?? .processUnknown
        recordedAt = now
    }
}
struct WorkDailyOpeningFailure: Error {
    let stage: WorkDailyFailureStage
    let reason: Failure
    init(stage: WorkDailyFailureStage, error: Error) {
        self.stage = stage; reason = (error as? Failure) ?? .processUnknown
    }
}

enum WorkDailyScope: String, Codable { case acceptance, normal }
enum WorkDailyPhase: String, Codable { case reserved, bound, active, blocked, exitObserved, exitUnobserved }
// Kernel proof that a visit's process is gone although no launcher observed its exit.
enum WorkDailyResolution: String, Codable { case otherBoot, processGone }
struct WorkDailyAttempt: Codable {
    let id: UUID
    let plan: AppInitialTrialPlan
    let scope: WorkDailyScope
    let approvedAt: Date
    let toolFingerprint: String
    let directories: [String: WorkDirectory]
    let owner: UUID
    let bootSession: String
    var phase: WorkDailyPhase = .reserved
    var receipt: AppInitialTrialReceipt?
    var generation: WorkProcess?
    var heartbeatAt: Date?
    var reportAt: Date?
    var account: AppTrialManualAccount?
    var personal: WorkPersonalReport?
    var projectsConnected: Bool?
    var quitIntentAt: Date?
    var endedAt: Date?
    var observerLostAt: Date?
    var diagnostic: WorkDailyDiagnostic?
    var resolvedAt: Date?
    var resolution: WorkDailyResolution?
    var closed: Bool { phase == .exitObserved || phase == .exitUnobserved }
    var accepted: Bool {
        scope == .acceptance && phase == .exitObserved && account == .confirmed && personal == .unchanged
            && projectsConnected == true && quitIntentAt != nil && endedAt != nil && heartbeatAt != nil && observerLostAt == nil
    }
    var rejectedReport: Bool {
        account == .mismatch || account == .loginRequired || personal == .changed || personal == .unknown || projectsConnected == false
    }
    func valid(now: Date) -> Bool {
        guard safeAbsolutePath(plan.root), approvedAt >= plan.requestedAt, approvedAt <= now,
              UUID(uuidString: bootSession) != nil,
              WorkDailyState.validHash(toolFingerprint), WorkDailyState.validDirectories(directories),
              plan.domain != .production || plan.isRecordedWorkPlan else { return false }
        if let receipt {
            guard receipt.matches(plan, now: now), receipt.launchedAt >= approvedAt else { return false }
            if let generation {
                guard generation.matchesScope(receipt) else { return false }
            } else if phase != .reserved && phase != .blocked && phase != .exitUnobserved { return false }
            if [heartbeatAt, reportAt, quitIntentAt, endedAt, resolvedAt].compactMap({ $0 }).contains(where: { $0 < receipt.launchedAt }) { return false }
        } else if generation != nil || phase == .bound || phase == .active || phase == .exitObserved { return false }
        for date in [heartbeatAt, reportAt, quitIntentAt, endedAt, observerLostAt, resolvedAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, date >= approvedAt, date <= now else { return false }
        }
        guard (account != nil) == (reportAt != nil), (personal != nil) == (reportAt != nil),
              (projectsConnected != nil) == (reportAt != nil),
              reportAt == nil || receipt != nil,
              quitIntentAt == nil || (reportAt != nil && account == .confirmed && personal == .unchanged && projectsConnected == true),
              phase != .active || heartbeatAt != nil,
              (phase == .exitObserved) == (endedAt != nil),
              (phase == .exitUnobserved) == (resolvedAt != nil), (resolvedAt != nil) == (resolution != nil),
              resolution != .processGone || generation != nil else { return false }
        if let resolvedAt, [heartbeatAt, reportAt, quitIntentAt, observerLostAt].contains(where: { $0.map { $0 > resolvedAt } ?? false }) { return false }
        if let endedAt, let quitIntentAt, endedAt < quitIntentAt { return false }
        if let quitIntentAt, let reportAt, quitIntentAt < reportAt { return false }
        if let diagnostic {
            guard let observerLostAt, diagnostic.recordedAt >= approvedAt, diagnostic.recordedAt <= observerLostAt,
                  diagnostic.recordedAt <= now, diagnostic.recordedAt.timeIntervalSince1970.isFinite,
                  phase == .blocked || closed else { return false }
        }
        return true
    }
}
struct WorkDailyGrant: Codable {
    let acceptedAttemptIDs: [UUID]
    let approvedAt: Date
    let toolFingerprint: String
    let directories: [String: WorkDirectory]
    let plan: AppInitialTrialPlan
}
// Starts a new acceptance segment after a verified launcher replacement. No visit is
// inherited: the predecessor stays byte-for-byte in an immutable archive. A new launcher/
// version needs two acceptance visits and a separate daily-use grant, unless the predecessor
// held a grant (carryOver): then one accepted visit re-issues it, consented at segment start.
struct WorkDailyUpdateTransition: Codable {
    let reviewID: String? // nil only when the official target is unchanged (launcher-only replacement)
    let setupPlan: AppInitialTrialPlan
    let fromPlan: AppInitialTrialPlan
    let toPlan: AppInitialTrialPlan
    let fromToolFingerprint: String
    let toToolFingerprint: String
    let directories: [String: WorkDirectory]
    let previousArchiveID: UUID
    let previousArchiveSHA256: String
    let replacement: WorkDailyReplacementEvidence?
    let approvedAt: Date
    var carryOver: Bool? = nil // true only; re-verified against the archived predecessor on every read
    var versionChanged: Bool { !WorkDailyState.sameTarget(fromPlan, toPlan) }
    static func validReviewID(_ value: String) -> Bool {
        value.range(of: "^work-update-[0-9a-f]{32}$", options: .regularExpression) != nil
    }
    func valid(now: Date) -> Bool {
        let domain = toPlan.domain
        guard fromPlan.domain == domain, setupPlan.domain == domain,
              domain != .production || ([setupPlan, fromPlan, toPlan].allSatisfy(\.isRecordedWorkPlan) && replacement != nil),
              replacement?.valid() ?? true,
              (reviewID != nil) == versionChanged, reviewID.map(Self.validReviewID) ?? true,
              versionChanged || fromToolFingerprint != toToolFingerprint, carryOver != false,
              [fromToolFingerprint, toToolFingerprint, previousArchiveSHA256].allSatisfy(WorkDailyState.validHash),
              WorkDailyState.validDirectories(directories),
              approvedAt.timeIntervalSince1970.isFinite, approvedAt >= toPlan.requestedAt, approvedAt <= now else { return false }
        return true
    }
}
struct WorkDailyState: Codable {
    var schemaVersion = 1
    var update: WorkDailyUpdateTransition?
    var attempts: [WorkDailyAttempt] = []
    var grant: WorkDailyGrant?
    var pending: Bool { attempts.last.map { !$0.closed } ?? false }
    var acceptedCount: Int { attempts.filter(\.accepted).count }
    var requiredAcceptances: Int { update?.carryOver == true ? 1 : 2 }
    // Daily use the next segment may carry over: issued, or earned in a carry-over segment where
    // issuing needs no further consent (the confirmed visit ended before the next launch).
    var carriesGrant: Bool { grant != nil || (update?.carryOver == true && acceptedCount >= requiredAcceptances) }
    // The official target and launcher this segment is bound to, even before its first visit.
    var segment: (plan: AppInitialTrialPlan, toolFingerprint: String, directories: [String: WorkDirectory])? {
        if let last = attempts.last { return (last.plan, last.toolFingerprint, last.directories) }
        if let update { return (update.toPlan, update.toToolFingerprint, update.directories) }
        return nil
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func validDirectories(_ value: [String: WorkDirectory]) -> Bool {
        Set(value.keys) == Set(["", "codex", "desktop", "cwd", "control"]) && value.values.allSatisfy { $0.inode > 0 }
    }
    static func sameTarget(_ a: AppInitialTrialPlan, _ b: AppInitialTrialPlan) -> Bool {
        WorkSetupRecord(plan: a, approvedAt: a.requestedAt).sameTarget(as: b)
    }
    func valid(now: Date) -> Bool {
        guard (schemaVersion == 1 && update == nil) || (schemaVersion == 2 && update?.valid(now: now) == true) else { return false }
        if let update {
            guard attempts.allSatisfy({ $0.toolFingerprint == update.toToolFingerprint &&
                $0.directories == update.directories && Self.sameTarget($0.plan, update.toPlan) &&
                $0.plan.requestedAt >= update.approvedAt }) else { return false }
        }
        guard attempts.count <= 256, Set(attempts.map(\.id)).count == attempts.count,
              attempts.allSatisfy({ $0.valid(now: now) }) else { return false }
        for index in attempts.indices where index > 0 {
            let previous = attempts[index - 1], current = attempts[index]
            guard previous.closed, let ended = previous.endedAt ?? previous.resolvedAt,
                  current.plan.requestedAt >= ended, Self.sameTarget(previous.plan, current.plan) else { return false }
        }
        if let grant {
            let accepted = Array(attempts.filter(\.accepted).suffix(requiredAcceptances))
            guard accepted.count == requiredAcceptances, grant.acceptedAttemptIDs == accepted.map(\.id),
                  grant.approvedAt >= accepted.last!.endedAt!, grant.approvedAt <= now,
                  accepted.allSatisfy({ $0.toolFingerprint == grant.toolFingerprint && $0.directories == grant.directories && Self.sameTarget($0.plan, grant.plan) }),
                  Self.validHash(grant.toolFingerprint), Self.validDirectories(grant.directories) else { return false }
        }
        for attempt in attempts where attempt.scope == .normal {
            guard let grant, attempt.approvedAt >= grant.approvedAt, attempt.toolFingerprint == grant.toolFingerprint,
                  attempt.directories == grant.directories, Self.sameTarget(attempt.plan, grant.plan) else { return false }
        }
        return true
    }
    mutating func reserve(plan: AppInitialTrialPlan, scope: WorkDailyScope, consentAccepted: Bool, consentAt: Date? = nil,
                          toolFingerprint: String, directories: [String: WorkDirectory],
                          owner: UUID, bootSession: String, now: Date) throws -> UUID {
        guard consentAccepted else { throw Failure.approvalRequired }
        let approvedAt = consentAt ?? now
        guard approvedAt >= plan.requestedAt, approvedAt <= now, now.timeIntervalSince(approvedAt) < 120 else { throw Failure.approvalStale }
        guard valid(now: now), attempts.count < 256, !pending else { throw Failure.processUnknown }
        guard !attempts.contains(where: \.rejectedReport) else { throw Failure.approvalRequired }
        if let update {
            guard toolFingerprint == update.toToolFingerprint, directories == update.directories,
                  Self.sameTarget(plan, update.toPlan), plan.requestedAt >= update.approvedAt else { throw Failure.approvalStale }
        }
        if let first = attempts.first {
            guard first.toolFingerprint == toolFingerprint, first.directories == directories,
                  Self.sameTarget(first.plan, plan) else { throw Failure.approvalStale }
        }
        if scope == .normal {
            guard let grant, grant.toolFingerprint == toolFingerprint, grant.directories == directories,
                  Self.sameTarget(grant.plan, plan) else { throw Failure.approvalStale }
        } else if grant != nil { throw Failure.approvalRequired }
        let attempt = WorkDailyAttempt(id: UUID(), plan: plan, scope: scope, approvedAt: approvedAt,
            toolFingerprint: toolFingerprint, directories: directories, owner: owner, bootSession: bootSession)
        guard attempt.valid(now: now) else { throw Failure.stateInvalid }
        attempts.append(attempt)
        return attempt.id
    }
    private mutating func edit(_ id: UUID, owner: UUID? = nil, bootSession: String? = nil, now: Date,
                              _ action: (inout WorkDailyAttempt) throws -> Void) throws {
        guard valid(now: now), let index = attempts.indices.last, attempts[index].id == id,
              !attempts[index].closed,
              owner == nil || attempts[index].owner == owner,
              bootSession == nil || attempts[index].bootSession == bootSession else { throw Failure.processUnknown }
        var attempt = attempts[index]
        try action(&attempt)
        guard attempt.valid(now: now) else { throw Failure.stateInvalid }
        attempts[index] = attempt
    }
    mutating func bind(_ id: UUID, receipt: AppInitialTrialReceipt, generation: WorkProcess,
                       owner: UUID, bootSession: String, now: Date) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            guard attempt.phase == .reserved, receipt.plan == attempt.plan, generation.matchesScope(receipt),
                  attempt.receipt == nil || attempt.receipt == receipt else { throw Failure.processUnknown }
            attempt.receipt = receipt; attempt.generation = generation; attempt.phase = .bound
        }
    }
    mutating func completion(_ id: UUID, receipt: AppInitialTrialReceipt, owner: UUID, bootSession: String, now: Date) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            guard attempt.phase == .reserved, attempt.receipt == nil, receipt.plan == attempt.plan else { throw Failure.processUnknown }
            attempt.receipt = receipt
        }
    }
    mutating func heartbeat(_ id: UUID, owner: UUID, bootSession: String, now: Date) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            guard attempt.phase == .bound || attempt.phase == .active else { throw Failure.processUnknown }
            attempt.heartbeatAt = now; attempt.phase = .active
        }
    }
    func isFresh(owner: UUID, bootSession: String, now: Date) -> Bool {
        guard let attempt = attempts.last, attempt.owner == owner, attempt.bootSession == bootSession,
              attempt.phase == .active, let heartbeat = attempt.heartbeatAt else { return false }
        return now >= heartbeat && now.timeIntervalSince(heartbeat) <= 15
    }
    mutating func report(_ id: UUID, account: AppTrialManualAccount, personal: WorkPersonalReport,
                         projectsConnected: Bool, now: Date) throws {
        try edit(id, now: now) { attempt in
            guard attempt.receipt != nil, attempt.reportAt == nil else { throw Failure.processUnknown }
            attempt.account = account; attempt.personal = personal; attempt.projectsConnected = projectsConnected
            attempt.reportAt = now
            if attempt.rejectedReport { attempt.phase = .blocked }
        }
    }
    mutating func quitIntent(_ id: UUID, owner: UUID, bootSession: String, now: Date) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            guard attempt.account == .confirmed, attempt.personal == .unchanged, attempt.projectsConnected == true,
                  attempt.quitIntentAt == nil else { throw Failure.approvalRequired }
            attempt.quitIntentAt = now
        }
    }
    mutating func observerLost(_ id: UUID, owner: UUID, bootSession: String, now: Date, diagnostic: WorkDailyDiagnostic? = nil) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            attempt.phase = .blocked; attempt.observerLostAt = now
            if attempt.diagnostic == nil { attempt.diagnostic = diagnostic }
        }
    }
    mutating func exit(_ id: UUID, generation: WorkProcess, owner: UUID, bootSession: String, now: Date) throws {
        try edit(id, owner: owner, bootSession: bootSession, now: now) { attempt in
            guard attempt.generation == generation, attempt.receipt != nil else { throw Failure.processUnknown }
            attempt.endedAt = now; attempt.phase = .exitObserved
        }
    }
    // The unresolved visit may be closed without counting as accepted only when its process is provably
    // gone: a different boot session, or its exact kernel generation (pid + start time) no longer exists.
    // `exited` is true only on proof; a visit without a bound generation needs another boot.
    func unobservedExit(bootSession: String, exited: (WorkProcess) -> Bool?) -> WorkDailyResolution? {
        guard let attempt = attempts.last, !attempt.closed, !attempts.contains(where: \.rejectedReport) else { return nil }
        if attempt.bootSession != bootSession { return attempt.generation.map({ exited($0) != false }) ?? true ? .otherBoot : nil }
        guard let generation = attempt.generation, exited(generation) == true else { return nil }
        return .processGone
    }
    // Re-proves under the lock; the caller obtained consent for exactly this visit.
    mutating func closeUnobserved(_ id: UUID, bootSession: String, exited: (WorkProcess) -> Bool?, now: Date) throws {
        guard let reason = unobservedExit(bootSession: bootSession, exited: exited) else { throw Failure.processUnknown }
        try edit(id, now: now) { attempt in
            attempt.phase = .exitUnobserved; attempt.resolvedAt = now; attempt.resolution = reason
        }
    }
    mutating func approveNormal(toolFingerprint: String, directories: [String: WorkDirectory], accepted: Bool, now: Date) throws {
        guard accepted, valid(now: now), !pending, grant == nil, !attempts.contains(where: \.rejectedReport) else { throw Failure.approvalRequired }
        let acceptedAttempts = Array(attempts.filter(\.accepted).suffix(requiredAcceptances))
        guard acceptedAttempts.count == requiredAcceptances, acceptedAttempts.allSatisfy({ $0.toolFingerprint == toolFingerprint && $0.directories == directories }) else { throw Failure.approvalRequired }
        grant = WorkDailyGrant(acceptedAttemptIDs: acceptedAttempts.map(\.id), approvedAt: now,
            toolFingerprint: toolFingerprint, directories: directories, plan: acceptedAttempts.last!.plan)
        guard valid(now: now) else { grant = nil; throw Failure.stateInvalid }
    }
    static func decode(_ data: Data, now: Date) throws -> Self {
        guard data.count <= 1_048_576, uniqueJSONKeys(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "attempts", "grant", "update"]), validJSONFields(object),
              let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.valid(now: now) else { throw Failure.stateInvalid }
        if let update = decoded.update {
            guard let fields = object["update"],
                  let expected = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(update)),
                  dailySameJSONShape(fields, expected) else { throw Failure.stateInvalid }
        }
        return decoded
    }
    private static func validJSONFields(_ object: [String: Any]) -> Bool {
        let planKeys: Set<String> = ["requestID", "requestedAt", "domain", "root", "bundlePath", "executablePath", "appVersion", "appBuild", "appFingerprint", "cliExecutablePath", "cliVersion", "cliBuild", "cliFingerprint"]
        func plan(_ value: Any?) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            return Set(object.keys) == planKeys
        }
        func directories(_ value: Any?) -> Bool {
            guard let values = value as? [String: [String: Any]] else { return false }
            return values.values.allSatisfy { Set($0.keys) == ["device", "inode"] }
        }
        guard let attempts = object["attempts"] as? [[String: Any]] else { return false }
        let attemptKeys: Set<String> = ["id", "plan", "scope", "approvedAt", "toolFingerprint", "directories", "owner", "bootSession", "phase", "receipt", "generation", "heartbeatAt", "reportAt", "account", "personal", "projectsConnected", "quitIntentAt", "endedAt", "observerLostAt", "diagnostic", "resolvedAt", "resolution"]
        for attempt in attempts {
            guard Set(attempt.keys).isSubset(of: attemptKeys), plan(attempt["plan"]), directories(attempt["directories"]) else { return false }
            if let diagnostic = attempt["diagnostic"] {
                guard let fields = diagnostic as? [String: Any], Set(fields.keys) == ["stage", "reason", "recordedAt"] else { return false }
            }
            if let receipt = attempt["receipt"] {
                guard let fields = receipt as? [String: Any], Set(fields.keys) == ["plan", "instanceToken", "pid", "launchedAt", "source"], plan(fields["plan"]) else { return false }
            }
            if let generation = attempt["generation"] {
                guard let fields = generation as? [String: Any], Set(fields.keys) == ["pid", "uid", "startSeconds", "startMicroseconds", "executable"] else { return false }
            }
        }
        if let grant = object["grant"] {
            guard let fields = grant as? [String: Any], Set(fields.keys) == ["acceptedAttemptIDs", "approvedAt", "toolFingerprint", "directories", "plan"], plan(fields["plan"]), directories(fields["directories"]) else { return false }
        }
        return true
    }
}

final class WorkDailyLaunchPermit {
    let attemptID: UUID
    let plan: AppInitialTrialPlan
    let approvedAt: Date
    let expiresAt: Date
    fileprivate init(attemptID: UUID, plan: AppInitialTrialPlan, approvedAt: Date) {
        self.attemptID = attemptID; self.plan = plan; self.approvedAt = approvedAt
        expiresAt = approvedAt.addingTimeInterval(120)
    }
    func validateProduction(now: Date) throws {
        guard Thread.isMainThread, plan.domain == .production,
              plan == .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID) else { throw Failure.capabilityUnknown }
        guard approvedAt >= plan.requestedAt, approvedAt <= now, now < expiresAt else { throw Failure.approvalStale }
    }
}
struct WorkDailySubmission {
    let attemptID: UUID
    let receipt: AppInitialTrialReceipt
    let generation: WorkProcess
}

struct WorkDailyCoordinator {
    let store: PrivateStore
    let now: () -> Date
    private let domain: AppEvidenceDomain
    private init(store: PrivateStore, now: @escaping () -> Date, domain: AppEvidenceDomain) {
        self.store = store; self.now = now; self.domain = domain
    }
    static func synthetic(store: PrivateStore, now: @escaping () -> Date) -> Self { Self(store: store, now: now, domain: .synthetic) }
    static func production(store: PrivateStore) -> Self { Self(store: store, now: Date.init, domain: .production) }
    private func checkDomain(_ state: WorkDailyState) throws {
        guard state.attempts.allSatisfy({ $0.plan.domain == domain }), state.grant == nil || state.grant?.plan.domain == domain else { throw Failure.capabilityUnknown }
    }
    func readLocked() throws -> WorkDailyState {
        guard let data = try store.readWorkDailyLocked() else { return WorkDailyState() }
        let state = try WorkDailyState.decode(data, now: now())
        try checkDomain(state)
        if let update = state.update {
            _ = try predecessorLocked(update)
            if let replacement = update.replacement {
                guard replacement.valid(), try dailyReplacementReceiptDigest(replacement.receiptPath) == replacement.receiptSHA256 else { throw Failure.stateInvalid }
            }
        }
        return state
    }
    // One level is re-verified on every read; each segment verified its own predecessor when created.
    private func predecessorLocked(_ update: WorkDailyUpdateTransition) throws -> WorkDailyState {
        guard let archive = try store.readWorkDailyArchiveLocked(update.previousArchiveID),
              dailyDataDigest(archive) == update.previousArchiveSHA256 else { throw Failure.stateInvalid }
        let prior = try WorkDailyState.decode(archive, now: now())
        try checkDomain(prior)
        // One direction only: segments recorded before carry-over existed keep needing two visits.
        guard update.carryOver != true || prior.carriesGrant else { throw Failure.stateInvalid }
        guard let segment = prior.segment else {
            // An update before the first launcher visit continues from the completed setup itself.
            guard prior.schemaVersion == 1, prior.attempts.isEmpty, prior.grant == nil,
                  update.fromPlan == update.setupPlan else { throw Failure.stateInvalid }
            return prior
        }
        guard !prior.pending, !prior.attempts.contains(where: \.rejectedReport),
              segment.plan == update.fromPlan, segment.toolFingerprint == update.fromToolFingerprint,
              segment.directories == update.directories,
              prior.update.map({ $0.setupPlan == update.setupPlan }) ?? Self.sameTarget(update.setupPlan, segment.plan) else { throw Failure.stateInvalid }
        return prior
    }
    private static func sameTarget(_ a: AppInitialTrialPlan, _ b: AppInitialTrialPlan) -> Bool { WorkDailyState.sameTarget(a, b) }
    // Production: exactly one edge exists in this build, from the newest historical target
    // to the current one. A launcher-only replacement keeps the target and changes the tool.
    func beginUpdate(plan: AppInitialTrialPlan, accepted: Bool, consentAt: Date, toolFingerprint: String,
                     directories: [String: WorkDirectory], reviewID: String?,
                     replacement: WorkDailyReplacementEvidence?, replacedToolFingerprint: String? = nil,
                     inspect: () throws -> Void) throws -> WorkDailyUpdateTransition {
        guard accepted else { throw Failure.approvalRequired }
        guard plan.domain == domain else { throw Failure.capabilityUnknown }
        return try store.withLock {
            let at = now()
            guard consentAt >= plan.requestedAt, consentAt <= at, at.timeIntervalSince(consentAt) < 120 else { throw Failure.approvalStale }
            let prior = try readLocked()
            // Before the first launcher visit nothing is recorded yet: the completed setup is the
            // segment, bound to the launcher the verified receipt replaced.
            let data = try store.readWorkDailyLocked() ?? JSONEncoder().encode(prior)
            let saved = try store.readLocked()
            guard let setup = saved.workSetup, setup.completed else { throw Failure.approvalRequired }
            guard let segment = prior.segment ?? replacedToolFingerprint.map({ (setup.plan, $0, directories) }),
                  !prior.pending, !prior.attempts.contains(where: \.rejectedReport),
                  segment.directories == directories else { throw Failure.approvalRequired }
            if domain == .production { try Self.prerequisites(saved, plan: segment.plan, daily: prior) }
            guard prior.update.map({ $0.setupPlan == setup.plan }) ?? setup.sameTarget(as: segment.plan) else { throw Failure.approvalRequired }
            let versionChanged = !Self.sameTarget(segment.plan, plan)
            guard (reviewID != nil) == versionChanged, versionChanged || segment.toolFingerprint != toolFingerprint else { throw Failure.approvalRequired }
            if domain == .production {
                // The receipt must have replaced exactly the launcher this segment is bound to.
                guard plan == .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID), replacement?.valid() == true,
                      replacedToolFingerprint == segment.toolFingerprint else { throw Failure.identityMismatch }
                if versionChanged {
                    guard let source = WorkAppPins.updateEdgeSource, reviewID == WorkAppPins.updateReviewID,
                          Self.sameTarget(segment.plan, .workTarget(source, requestedAt: segment.plan.requestedAt)) else { throw Failure.identityMismatch }
                }
            }
            if let replacement {
                guard try dailyReplacementReceiptDigest(replacement.receiptPath) == replacement.receiptSHA256 else { throw Failure.stateInvalid }
            }
            try inspect()
            let update = WorkDailyUpdateTransition(reviewID: reviewID, setupPlan: setup.plan, fromPlan: segment.plan, toPlan: plan,
                fromToolFingerprint: segment.toolFingerprint, toToolFingerprint: toolFingerprint, directories: directories,
                previousArchiveID: UUID(), previousArchiveSHA256: dailyDataDigest(data), replacement: replacement, approvedAt: now(),
                carryOver: prior.carriesGrant ? true : nil)
            var next = WorkDailyState(); next.schemaVersion = 2; next.update = update
            guard next.valid(now: now()) else { throw Failure.stateInvalid }
            try store.archiveWorkDailyLocked(data, id: update.previousArchiveID)
            try store.writeWorkDailyLocked(JSONEncoder().encode(next))
            return update
        }
    }
    func read() throws -> WorkDailyState { try store.withLock { try readLocked() } }
    func transaction<T>(_ body: (inout WorkDailyState) throws -> T) throws -> T {
        try store.withLock {
            var state = try readLocked()
            let result = try body(&state)
            try checkDomain(state)
            guard state.valid(now: now()) else { throw Failure.stateInvalid }
            try store.writeWorkDailyLocked(JSONEncoder().encode(state))
            return result
        }
    }
    func submit(plan: AppInitialTrialPlan, scope: WorkDailyScope, accepted: Bool, consentAt: Date? = nil, toolFingerprint: String,
                directories: [String: WorkDirectory], owner: UUID, bootSession: String,
                inspect: () throws -> Void, open: (WorkDailyLaunchPermit) throws -> AppInitialTrialReceipt,
                bind: (AppInitialTrialReceipt) throws -> WorkProcess) throws -> WorkDailySubmission {
        guard accepted else { throw Failure.approvalRequired }
        guard plan.domain == domain else { throw Failure.capabilityUnknown }
        // Historical targets are readable records only; never reserve a visit for one.
        if domain == .production { guard plan == .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID) else { throw Failure.identityMismatch } }
        return try store.withLock {
            var state = try readLocked()
            if domain == .production { try Self.prerequisites(store.readLocked(), plan: plan, daily: state) }
            try inspect()
            // 완료된 일상 기록은 불변 파일로 먼저 보존한다. 미해결 예약은 정리하지 않는다.
            if state.attempts.count >= 128, !state.pending, state.grant != nil,
               !state.attempts.contains(where: \.rejectedReport) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let archive = try encoder.encode(state)
                try store.archiveWorkDailyLocked(archive, id: state.attempts.last!.id)
                state.attempts.removeAll { $0.scope == .normal }
            }
            let approvedAt = consentAt ?? now()
            let id = try state.reserve(plan: plan, scope: scope, consentAccepted: accepted, consentAt: approvedAt, toolFingerprint: toolFingerprint,
                directories: directories, owner: owner, bootSession: bootSession, now: now())
            try store.writeWorkDailyLocked(JSONEncoder().encode(state))
            let permit = WorkDailyLaunchPermit(attemptID: id, plan: plan, approvedAt: approvedAt)
            var stage: WorkDailyFailureStage = .finalVerification
            do {
                try inspect()
                stage = .workspaceOpening
                let receipt = try open(permit)
                stage = .receiptPersistence
                try state.completion(id, receipt: receipt, owner: owner, bootSession: bootSession, now: now())
                try store.writeWorkDailyLocked(JSONEncoder().encode(state))
                stage = .kernelBinding
                let generation = try bind(receipt)
                stage = .bindingPersistence
                try state.bind(id, receipt: receipt, generation: generation, owner: owner, bootSession: bootSession, now: now())
                try store.writeWorkDailyLocked(JSONEncoder().encode(state))
                return WorkDailySubmission(attemptID: id, receipt: receipt, generation: generation)
            } catch {
                let failedAt = now()
                let diagnostic = WorkDailyDiagnostic(stage: (error as? WorkDailyOpeningFailure)?.stage ?? stage, error: error, now: failedAt)
                try? state.observerLost(id, owner: owner, bootSession: bootSession, now: failedAt, diagnostic: diagnostic)
                try? store.writeWorkDailyLocked(JSONEncoder().encode(state))
                throw error
            }
        }
    }
    // A completed setup on an older target qualifies only through a recorded update segment.
    static func prerequisites(_ state: SavedState, plan: AppInitialTrialPlan, daily: WorkDailyState? = nil) throws {
        guard let setup = state.workSetup, setup.completed,
              setup.sameTarget(as: plan) || (daily?.update.map { $0.setupPlan == setup.plan && WorkDailyState.sameTarget($0.toPlan, plan) } ?? false),
              !state.launchUnresolved, state.pending.isEmpty, (state.appApprovals ?? [:]).isEmpty else { throw Failure.approvalRequired }
    }
}
