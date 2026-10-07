import Foundation
import Darwin

// Kernel identity of one official app process: pid alone can be reused, start time cannot.
struct WorkProcess: Codable, Equatable {
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
    static func snapshot(_ root: String) throws -> [String: Self] {
        var result: [String: Self] = [:]
        for name in ["", "codex", "desktop", "cwd", "control"] {
            let path = name.isEmpty ? root : root + "/" + name
            try inspectDirectoryPath(path, privateRoot: root)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.profilePathConflict }
            result[name] = Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
        return result
    }
}
