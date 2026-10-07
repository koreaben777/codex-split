import Foundation
import AppKit
import Darwin

// Evidence that an existing profile (codex, desktop, cwd) was moved, not copied, into the
// work root. Earlier control records were moved aside unchanged and are never reinterpreted.
struct WorkSetupAdoption: Codable, Equatable {
    let fromRoot: String
    let legacyControl: String?
    let adoptedAt: Date
    let directories: [String: WorkDirectory]
    func valid(root: String, approvedAt: Date, now: Date) -> Bool {
        safeAbsolutePath(fromRoot) && !overlap(fromRoot, root)
            && (legacyControl.map { safeAbsolutePath($0) && !overlap($0, root) && !overlap($0, fromRoot) } ?? true)
            && adoptedAt.timeIntervalSince1970.isFinite && adoptedAt >= approvedAt && adoptedAt <= now
            && WorkDailyState.validDirectories(directories)
    }
}

struct WorkProfileAdopter {
    let inUse: (String) -> Bool
    let now: () -> Date
    // Same-volume renames only: no copy, no deletion; inodes of codex/desktop/cwd are preserved.
    func adopt(from source: String, to root: String, legacy: String) throws -> WorkSetupAdoption {
        guard safeAbsolutePath(source), safeAbsolutePath(root), safeAbsolutePath(legacy),
              !overlap(source, root), !overlap(legacy, root), !overlap(legacy, source) else { throw Failure.profilePathConflict }
        try inspectDirectoryPath(source, privateRoot: source)
        var info = stat()
        for name in ["", "codex", "desktop", "cwd"] {
            let path = name.isEmpty ? source : source + "/" + name
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o700 else { throw Failure.profilePathConflict }
        }
        let hasControl = lstat(source + "/control", &info) == 0
        if hasControl { guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Failure.profilePathConflict } }
        guard lstat(root, &info) != 0, errno == ENOENT else { throw Failure.profilePathConflict }
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
        try inspectDirectoryPath(parent)
        var sourceInfo = stat(), parentInfo = stat()
        guard lstat(source, &sourceInfo) == 0, lstat(parent, &parentInfo) == 0, sourceInfo.st_dev == parentInfo.st_dev else { throw Failure.profilePathConflict }
        guard !inUse(source) else { throw Failure.profileBusy }
        if mkdir(legacy, 0o700) != 0 && errno != EEXIST { throw Failure.io }
        try inspectDirectoryPath(legacy, privateRoot: legacy)
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "")
        let legacyControl = hasControl ? legacy + "/control-" + stamp : nil
        if let legacyControl { guard lstat(legacyControl, &info) != 0, errno == ENOENT else { throw Failure.profilePathConflict } }
        guard renamex_np(source, root, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
        if let legacyControl {
            guard renamex_np(root + "/control", legacyControl, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
        }
        guard mkdir(root + "/control", 0o700) == 0 else { throw Failure.io }
        for directory in [parent, root, legacy, URL(fileURLWithPath: source).deletingLastPathComponent().path] {
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.io }
            let synced = fsync(fd); close(fd)
            guard synced == 0 else { throw Failure.io }
        }
        return WorkSetupAdoption(fromRoot: source, legacyControl: legacyControl, adoptedAt: now(),
                                 directories: try WorkDirectory.snapshot(root))
    }
    // `ps -o pid=,args=` lines naming the profile, except this tool (its own --from argument names it).
    static func processesUse(_ listing: String, source: String, ownPID: Int32) -> Bool {
        listing.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { return true } // unparsable: assume busy
            return pid != ownPID && fields[1].contains(source)
        }
    }
    // Any other process whose arguments name the profile (official app, helpers, plugins) or a running launcher blocks the move.
    static func production() -> Self {
        Self(inUse: { source in
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.codexsplit.work").isEmpty else { return true }
            let ps = Process(), pipe = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axww", "-o", "pid=,args="]
            ps.standardOutput = pipe
            guard (try? ps.run()) != nil else { return true }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            guard ps.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return true }
            return processesUse(text, source: source, ownPID: getpid())
        }, now: Date.init)
    }
}
