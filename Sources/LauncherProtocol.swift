import Foundation

enum ProfileID: String, Codable, CaseIterable { case personal, work }
enum Failure: String, Error, Codable {
    case invalidArguments = "INVALID_ARGUMENTS"
    case authUnverified = "AUTH_UNVERIFIED", capabilityUnknown = "CAPABILITY_UNKNOWN"
    case approvalRequired = "APPROVAL_REQUIRED", approvalStale = "APPROVAL_STALE"
    case testsIncomplete = "TESTS_INCOMPLETE", pathsUnobserved = "PATHS_UNOBSERVED"
    case profilePathConflict = "PROFILE_PATH_CONFLICT", identityMismatch = "IDENTITY_MISMATCH"
    case processUnknown = "PROCESS_UNKNOWN", profileBusy = "PROFILE_BUSY", sessionBusy = "SESSION_BUSY"
    case concurrencyUnverified = "CONCURRENCY_UNVERIFIED", stateInvalid = "STATE_INVALID"
    case lockBusy = "LOCK_BUSY", io = "IO_ERROR", profileUnconfigured = "PROFILE_UNCONFIGURED"
}

// JSONSerialization validates syntax; this scan rejects duplicate keys (including escaped keys)
// rather than accepting the parser's first/last-value choice at a protocol trust boundary.
func uniqueJSONKeys(_ data: Data) -> Bool {
    let bytes = Array(data)
    var frames: [(object: Bool, keys: Set<String>, keyNext: Bool)] = []
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case 123, 91: frames.append((bytes[i] == 123, [], bytes[i] == 123))
        case 125, 93: if !frames.isEmpty { frames.removeLast() }
        case 44: if !frames.isEmpty { frames[frames.count - 1].keyNext = frames.last!.object }
        case 58: if !frames.isEmpty { frames[frames.count - 1].keyNext = false }
        case 34:
            let start = i
            i += 1
            while i < bytes.count && bytes[i] != 34 {
                if bytes[i] == 92 { i += 1 }
                i += 1
            }
            guard i < bytes.count else { return false }
            if let frame = frames.last, frame.object && frame.keyNext {
                guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[start...i]), options: .fragmentsAllowed) as? String,
                      frames[frames.count - 1].keys.insert(key).inserted else { return false }
            }
        default: break
        }
        i += 1
    }
    return true
}

enum AppOpenState: String, Codable { case blocked, alreadyRunning, launchRequested }
struct AppOpenReply: Codable, Equatable {
    var schemaVersion = 1
    var profileId: ProfileID
    var state: AppOpenState
    var reason: Failure?
    var launchConfirmed = false
    var exitCode: Int32 { state == .blocked ? 2 : 0 }
    var title: String { profileId == .work ? "CodexSplit 업무용 (개발)" : "CodexSplit 개인용 (개발)" }
    var message: String {
        if state == .alreadyRunning { return "해당 프로필의 앱이 이미 실행 중입니다. 기존 창을 사용하세요. 새 앱은 실행하지 않았습니다." }
        if state == .launchRequested { return "앱 열기를 요청했습니다. 창과 계정 확인은 아직 완료되지 않았습니다. 반복 실행 대신 상태를 확인하세요." }
        switch reason {
        case .profileUnconfigured: return "업무·개인 프로필을 아직 등록하지 않았습니다. 개발용 바로가기이며 실행 계열 명령은 아직 차단돼 있습니다. 업무 프로필은 CodexSplit-work.app을 사용하세요."
        case .approvalStale, .identityMismatch: return "앱 버전 또는 실행 대상이 검증 기록과 다릅니다. 다시 검증하기 전에는 실행하지 않습니다. 기존 앱을 종료하거나 교체하지 않았습니다."
        case .profileBusy: return "해당 프로필이 사용 중입니다. 기존 창을 확인하세요."
        case .lockBusy, .processUnknown, .sessionBusy: return "다른 요청이 진행 중이거나 실행 상태를 확인할 수 없습니다. 반복 실행하지 말고 상태를 확인하세요. 기존 앱은 종료하지 않았습니다."
        case .authUnverified: return "계정 확인이 필요합니다. 공식 계정 확인 전에는 앱을 실행하지 않습니다. 로그인은 자동으로 시작하지 않습니다."
        case .profilePathConflict, .pathsUnobserved: return "프로필 저장 경로의 분리를 확인할 수 없어 실행을 중단했습니다. 기존 프로필을 옮기거나 수정하지 않았습니다."
        case .approvalRequired, .testsIncomplete, .concurrencyUnverified, .capabilityUnknown: return "실행·병행 사용 검증 또는 승인이 아직 완료되지 않았습니다. 실제 앱은 실행하지 않았습니다."
        default: return "실행 요청을 완료하지 못했습니다. 설정과 상태를 확인하세요. 자동 재시도나 기존 앱 종료는 하지 않았습니다."
        }
    }
    static func decode(_ data: Data, expectedProfile: ProfileID, exitCode: Int32) -> AppOpenReply? {
        guard data.count <= 8192, uniqueJSONKeys(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "profileId", "state", "reason", "launchConfirmed"]),
              let reply = try? JSONDecoder().decode(Self.self, from: data), reply.schemaVersion == 1,
              reply.profileId == expectedProfile, !reply.launchConfirmed, reply.exitCode == exitCode else { return nil }
        switch reply.state {
        case .blocked: guard reply.reason != nil else { return nil }
        case .alreadyRunning: guard reply.reason == .profileBusy else { return nil }
        case .launchRequested: guard reply.reason == nil else { return nil }
        }
        return reply
    }
}
enum LauncherRead { case bytes(Data), waiting, eof, failed }
enum LauncherReceipt { case reply(AppOpenReply), invalid, timedOut }
// Shared by the thin UI and deterministic tests. No process control or launch permission here.
func receiveLauncherReply(profile: ProfileID, read: () -> LauncherRead, exitStatus: () -> Int32?,
                          expired: () -> Bool, pause: () -> Void) -> LauncherReceipt {
    var buffer = Data(), eof = false
    while !expired() {
        if !eof {
            switch read() {
            case .bytes(let data):
                guard data.count <= 8192 - buffer.count else { return .invalid }
                buffer.append(data)
            case .eof: eof = true
            case .failed: return .invalid
            case .waiting: break
            }
        }
        if eof, let status = exitStatus() {
            guard let reply = AppOpenReply.decode(buffer, expectedProfile: profile, exitCode: status) else { return .invalid }
            return .reply(reply)
        }
        pause()
    }
    return .timedOut
}
