import Foundation
import Darwin

// Kernel identity of one official app process: pid alone can be reused, start time cannot.
struct WorkProcess: Codable, Equatable {
    static func bootSession() throws -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        guard cs_boot_session(&bytes, 128) == 0 else { throw Failure.processUnknown }
        let boot = String(cString: bytes)
        guard UUID(uuidString: boot) != nil else { throw Failure.processUnknown }
        return boot
    }
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
    func matchesScope(_ receipt: AppInitialTrialReceipt) -> Bool {
        // Scope only: LaunchServices launchDate is not kernel process birth.
        pid == receipt.pid && pid > 0 && uid == getuid() && startSeconds > 0 &&
            startMicroseconds < 1_000_000 && executable == receipt.plan.executablePath
    }
    // true: this generation provably no longer exists (pid free, or reused by a later process).
    // false: still running. nil: cannot tell.
    var exited: Bool? {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        guard let current = try? Self.exact(pid) else { return nil }
        if current == self { return false }
        return current.startSeconds != startSeconds || current.startMicroseconds != startMicroseconds ? true : nil
    }
    static func exact(_ pid: Int32) throws -> Self {
        var value = CSObservedProcess()
        guard cs_observer_process(pid, &value) == 0 else { throw Failure.processUnknown }
        let path = withUnsafePointer(to: &value.executable) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
        }
        return Self(pid: Int32(value.pid), uid: UInt32(value.uid), startSeconds: UInt64(value.start_seconds),
                    startMicroseconds: UInt64(value.start_microseconds), executable: path)
    }
}
// Identity of the profile root and its fixed children; a same-permission replacement changes it.
struct WorkDirectory: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    var volumeUUID: UUID? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.inode == rhs.inode else { return false }
        switch (lhs.volumeUUID, rhs.volumeUUID) {
        case (.some(let a), .some(let b)): return a == b
        case (nil, nil): return lhs.device == rhs.device
        default: return false // Legacy records need an explicit transition, never an implicit match.
        }
    }
    static func canAnchor(_ old: [String: Self], to current: [String: Self]) -> Bool {
        WorkDailyState.validDirectories(old) && WorkDailyState.validDirectories(current) &&
            old.values.allSatisfy { $0.volumeUUID == nil } && current.values.allSatisfy { $0.volumeUUID != nil } &&
            Set(old.values.map(\.device)).count == 1 &&
            old.allSatisfy { current[$0.key]?.inode == $0.value.inode }
    }
    static func snapshot(_ root: String) throws -> [String: Self] {
        var result: [String: Self] = [:]
        for name in ["", "codex", "desktop", "cwd", "control"] {
            let path = name.isEmpty ? root : root + "/" + name
            try inspectDirectoryPath(path, privateRoot: root)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.profilePathConflict }
            let volume = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard let volume, let uuid = UUID(uuidString: volume) else { throw Failure.profilePathConflict }
            var after = stat()
            guard lstat(path, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                  after.st_mode == info.st_mode, after.st_uid == info.st_uid else { throw Failure.profilePathConflict }
            result[name] = Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), volumeUUID: uuid)
        }
        guard WorkDailyState.validDirectories(result) else { throw Failure.profilePathConflict }
        return result
    }
}
