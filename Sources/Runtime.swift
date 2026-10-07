import Foundation
import Darwin

func runCLI(_ plan: LaunchPlan) throws -> Int32 {
    guard safeAbsolutePath(plan.executable), safeAbsolutePath(plan.cwd),
          !plan.arguments.contains(where: { $0.contains("\0") }),
          plan.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw Failure.invalidArguments }
    let arguments = ([plan.executable] + plan.arguments).map { strdup($0) }
    let environment = plan.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
    defer { for pointer in arguments + environment { free(pointer) } }
    let result = cs_run(plan.executable, arguments + [nil], environment + [nil], plan.cwd)
    guard result >= 0 else { throw Failure.io }
    return result
}

struct Pending: Codable, Equatable {
    var token: UUID? = UUID()
    var identity: Identity
    var createdAt: Date
}
struct SavedState: Codable {
    var schemaVersion = 1
    var pending: [String: Pending] = [:]
    var validations: [String: Validation] = [:]
    var manualConnections: [String: ManualConnection]?
    var appRegistrations: [String: AppRegistration]?
    var appApprovals: [String: AppApprovalRecord]?
    var workSetup: WorkSetupRecord?
    // A live official-app launch whose exit is not yet recorded blocks every other operation.
    var launchUnresolved: Bool { workSetup?.pending ?? false }
}
final class PrivateStore {
    private let directory: Int32
    init(root: String) throws {
        try inspectDirectoryPath(root)
        directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(directory); throw Failure.profilePathConflict
        }
    }
    deinit { close(directory) }
    private func checkFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw Failure.stateInvalid }
    }
    func read() throws -> SavedState { try withLock { try readLocked() } }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        // ponytail: one mutex serializes starts, login and state updates; per-profile locks only if contention matters.
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(directory, "state.lock", flags)
        if fd < 0 && errno == ENOENT {
            fd = openat(directory, "state.lock", flags | O_CREAT | O_EXCL, 0o600)
            if fd < 0 && errno == EEXIST { fd = openat(directory, "state.lock", flags) }
        }
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        try checkFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.lockBusy }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    // Call only while holding withLock; the stable lock inode is never unlinked.
    func readLocked() throws -> SavedState {
        let fd = openat(directory, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return SavedState() }
            throw Failure.stateInvalid
        }
        defer { close(fd) }
        try checkFile(fd)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.io }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 1_048_576 else { throw Failure.stateInvalid }
        }
        guard let state = try? JSONDecoder().decode(SavedState.self, from: data), state.schemaVersion == 1,
              state.pending.allSatisfy({ ProfileID(rawValue: $0.key) == $0.value.identity.profile
                  && pathsAreValid($0.value.identity.paths) && $0.value.createdAt <= Date() }),
              state.validations.allSatisfy({ $0.key == $0.value.identity.profile.rawValue + "-" + $0.value.approvedTarget.rawValue }),
              (state.manualConnections ?? [:]).allSatisfy({ $0.key == $0.value.identity.profile.rawValue && pathsAreValid($0.value.identity.paths) && $0.value.recordedAt <= Date() })
        else { throw Failure.stateInvalid }
        if let registrations = state.appRegistrations {
            guard registrations.allSatisfy({ $0.key == $0.value.configuration.profileId.rawValue }) else { throw Failure.stateInvalid }
            try AppProfileConfiguration.validateSet(registrations.values.map(\.configuration))
        }
        guard (state.appApprovals ?? [:]).allSatisfy({ key, record in
            guard let registration = state.appRegistrations?[key] else { return false }
            return key == record.validation.identity.profile.rawValue
                && record.validation.approvedTarget == .app && record.validation.finalApproval
                && record.validation.appRegistrationRevision == registration.revision
                && registration.configuration.matches(record.validation.identity)
                && record.approvedAt < record.expiresAt
        }) else { throw Failure.stateInvalid }
        if let setup = state.workSetup { guard setup.valid(now: Date()) else { throw Failure.stateInvalid } }
        return state
    }
    func writeLocked(_ state: SavedState) throws {
        guard state.schemaVersion == 1 else { throw Failure.stateInvalid }
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1_048_576 else { throw Failure.stateInvalid }
        let name = "state-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd); unlinkat(directory, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, name, directory, "state.json") == 0,
              fsync(directory) == 0 else { throw Failure.io }
    }
    func transaction(_ edit: (inout SavedState) throws -> Void) throws {
        try withLock {
            var state = try readLocked()
            try edit(&state)
            try writeLocked(state)
        }
    }
    // 일상 GUI 기록은 기존 state.json과 별도이며 같은 control 잠금에서만 접근한다.
    func readWorkDailyLocked() throws -> Data? { try readDailyFileLocked("work-daily.json") }
    func readWorkDailyArchiveLocked(_ id: UUID) throws -> Data? { try readDailyFileLocked("work-daily-history-" + id.uuidString + ".json") }
    private func readDailyFileLocked(_ name: String) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw Failure.stateInvalid }
        defer { close(fd) }
        try checkFile(fd)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.io }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 1_048_576 else { throw Failure.stateInvalid }
        }
        return data
    }
    func writeWorkDailyLocked(_ data: Data) throws { try writeDailyFileLocked(data, destination: "work-daily.json", immutable: false) }
    func archiveWorkDailyLocked(_ data: Data, id: UUID) throws {
        try writeDailyFileLocked(data, destination: "work-daily-history-" + id.uuidString + ".json", immutable: true)
    }
    private func writeDailyFileLocked(_ data: Data, destination: String, immutable: Bool) throws {
        guard data.count <= 1_048_576 else { throw Failure.stateInvalid }
        // 기존 별도 기록이 심볼릭 링크·다중 링크·다른 권한이면 교체하지 않는다.
        if let existing = try readDailyFileLocked(destination) {
            if immutable {
                guard existing == data else { throw Failure.stateInvalid }
                let existingFD = openat(directory, destination, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard existingFD >= 0 else { throw Failure.io }
                defer { close(existingFD) }
                try checkFile(existingFD)
                guard fsync(existingFD) == 0, fsync(directory) == 0 else { throw Failure.io }
                return
            }
        }
        let name = "work-daily-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd); unlinkat(directory, name, 0) }
        try checkFile(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
        if immutable {
            guard cs_rename_exclusive(directory, name, destination) == 0 else { throw Failure.io }
        } else {
            guard renameat(directory, name, directory, destination) == 0 else { throw Failure.io }
        }
        guard fsync(directory) == 0 else { throw Failure.io }
    }
}
func inspectDirectoryPath(_ path: String, privateRoot: String? = nil) throws {
    guard safeAbsolutePath(path) else { throw Failure.profilePathConflict }
    var cursor = ""
    for part in path.split(separator: "/") {
        cursor += "/" + part
        var info = stat()
        if lstat(cursor, &info) != 0 {
            if errno == ENOENT { continue }
            throw Failure.profilePathConflict
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else { throw Failure.profilePathConflict }
        if let privateRoot, cursor == privateRoot || inside(cursor, privateRoot) {
            guard info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.profilePathConflict }
        }
    }
}
func inspectPaths(_ paths: ProfilePaths) throws {
    guard pathsAreValid(paths) else { throw Failure.profilePathConflict }
    for path in [paths.root, paths.codex, paths.sqlite, paths.desktop, paths.ipc] {
        try inspectDirectoryPath(path, privateRoot: paths.root)
    }
}
struct Coordinator {
    let store: PrivateStore
    func start(request: Request, validation: Validation, registration: AppRegistration? = nil, observe: () throws -> RuntimeSnapshot,
               launch: () throws -> Void) throws -> Decision {
        try store.withLock {
            var state = try store.readLocked()
            guard !state.launchUnresolved else { return .blocked(.processUnknown) }
            if let registration {
                guard validation.appRegistrationRevision == registration.revision,
                      registration.configuration.profileId == request.profile,
                      registration.configuration.matches(validation.identity),
                      state.appRegistrations?[request.profile.rawValue] == registration else { return .blocked(.approvalStale) }
            } else if state.appRegistrations?[request.profile.rawValue] != nil {
                // Registered profiles cannot use an unbound legacy callback path.
                return .blocked(.approvalStale)
            }
            guard state.pending[request.profile.rawValue] == nil else { return .blocked(.processUnknown) }
            guard state.pending.isEmpty else { return .blocked(.concurrencyUnverified) }
            let before = try observe()
            let decision = evaluate(request: request, validation: validation, runtime: before)
            guard decision == .allow else { return decision }
            try inspectPaths(before.identity.paths)
            state.pending[request.profile.rawValue] = Pending(identity: before.identity, createdAt: Date())
            try store.writeLocked(state)
            do {
                let after = try observe()
                let checked = before.identity == after.identity
                    ? evaluate(request: request, validation: validation, runtime: after) : .blocked(.approvalStale)
                guard checked == .allow else {
                    state.pending.removeValue(forKey: request.profile.rawValue)
                    try store.writeLocked(state)
                    return checked
                }
                try inspectPaths(after.identity.paths)
            } catch {
                // No launcher has been called yet; this reservation is safe to remove.
                state.pending.removeValue(forKey: request.profile.rawValue)
                try store.writeLocked(state)
                throw error
            }
            try launch()
            // A request accepted by an OS launcher does not prove exit, absence or a bound GUI.
            // Leave pending durable until a trustworthy observation path can reconcile it.
            return .allow
        }
    }
}

extension Coordinator {
    func complete(pending: Pending, observe: () throws -> RuntimeSnapshot) throws -> Decision {
        try store.withLock {
            var state = try store.readLocked()
            let key = pending.identity.profile.rawValue
            guard pending.token != nil, state.pending[key] == pending else { return .blocked(.processUnknown) }
            let current = try observe()
            guard current.identity == pending.identity, current.observationComplete, current.bindingMatches,
                  current.process == .notRunning, !current.sessionWriter,
                  current.observedPaths == pending.identity.paths else { return .blocked(.processUnknown) }
            state.pending.removeValue(forKey: key)
            try store.writeLocked(state)
            return .allow
        }
    }
}
