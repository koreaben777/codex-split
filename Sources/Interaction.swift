import Foundation

enum ApprovalAnswer: Equatable { case accepted, denied, cancelled, interrupted }
func approvalAnswer(_ text: String) -> ApprovalAnswer {
    switch text { case "yes": return .accepted; case "no": return .denied; default: return .cancelled }
}
func terminalApproval(_ request: Request) -> ApprovalAnswer {
    print("Approve \(request.profile.rawValue) / \(request.target.rawValue) at \(request.cwd)? Type yes, no, or cancel:")
    fflush(stdout)
    var buffer = [CChar](repeating: 0, count: 80)
    let result = cs_answer(&buffer, Int32(buffer.count))
    if result < 0 { return .interrupted }
    guard result == 1 else { return .cancelled }
    return approvalAnswer(String(cString: buffer))
}
func approve(store: PrivateStore, request: Request, validation: Validation,
             observe: () throws -> RuntimeSnapshot, ask: () -> ApprovalAnswer) throws -> Decision {
    guard request.operation == .run else { return .blocked(.invalidArguments) }
    var proposed = validation
    proposed.finalApproval = true
    let before = try observe()
    let eligible = evaluate(request: request, validation: proposed, runtime: before)
    guard eligible == .allow else { return eligible }
    guard ask() == .accepted else { return .blocked(.approvalRequired) }
    return try store.withLock {
        var state = try store.readLocked()
        guard state.pending.isEmpty, !state.launchUnresolved else { return .blocked(.processUnknown) }
        let after = try observe()
        guard before.identity == after.identity else { return .blocked(.approvalStale) }
        let checked = evaluate(request: request, validation: proposed, runtime: after)
        guard checked == .allow else { return checked }
        try inspectPaths(after.identity.paths)
        state.validations[request.profile.rawValue + "-" + request.target.rawValue] = proposed
        try store.writeLocked(state)
        return .allow
    }
}
struct ManualConnection: Codable {
    var identity: Identity
    var recordedAt: Date
    enum Report: String, Codable { case connected, disconnected }
    var report: Report // user-reported only, never machine-observed connection
    func status(current: Identity?, now: Date = Date()) -> [String: String] {
        ["actual": "unknown", "manualReport": report.rawValue, "recordedAt": ISO8601DateFormatter().string(from: recordedAt),
         "freshness": current == identity && recordedAt <= now ? "identity-matches / not-live-evidence" : "stale"]
    }
}
