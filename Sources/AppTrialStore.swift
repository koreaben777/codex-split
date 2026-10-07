import Foundation
import AppKit
import Security
import Darwin

// Exclusive, never-reused profile root. A failed first visit deliberately leaves it intact.
final class AppTrialRootLease {
    let plan: AppInitialTrialPlan
    private var fd: Int32
    private var children: [String: (dev_t, ino_t)] = [:]
    private init(plan: AppInitialTrialPlan) throws {
        self.plan = plan
        try inspectDirectoryPath(plan.root)
        let parent = URL(fileURLWithPath: plan.root).deletingLastPathComponent().path
        if mkdir(parent, 0o700) != 0 && errno != EEXIST { throw Failure.io }
        try inspectDirectoryPath(parent)
        guard mkdir(plan.root, 0o700) == 0 else { throw Failure.profilePathConflict }
        fd = open(plan.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        do {
            for name in ["codex", "desktop", "cwd", "control"] {
                guard mkdirat(fd, name, 0o700) == 0 else { throw Failure.io }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
                children[name] = (info.st_dev, info.st_ino)
            }
            guard fsync(fd) == 0 else { throw Failure.io }
            let parentFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw Failure.io }
            let synced = fsync(parentFD)
            close(parentFD)
            guard synced == 0 else { throw Failure.io }
            try validate()
        } catch { close(fd); fd = -1; throw error }
    }
    // Attach without creating, deleting, enumerating, or replacing application data.
    // This proves identity during this invocation, not across prior process lifetimes.
    private init(existing plan: AppInitialTrialPlan) throws {
        self.plan = plan
        try inspectDirectoryPath(plan.root, privateRoot: plan.root)
        fd = open(plan.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.profilePathConflict }
        do {
            for name in ["codex", "desktop", "cwd", "control"] {
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.profilePathConflict }
                children[name] = (info.st_dev, info.st_ino)
            }
            try validate(requireEmpty: false)
        } catch { close(fd); fd = -1; throw error }
    }
    static func resumeWork(_ plan: AppInitialTrialPlan) throws -> AppTrialRootLease {
        guard plan.domain == .production,
              plan == .workSetup(requestedAt: plan.requestedAt, requestID: plan.requestID) else { throw Failure.identityMismatch }
        return try AppTrialRootLease(existing: plan)
    }
    static func syntheticExisting(_ plan: AppInitialTrialPlan) throws -> AppTrialRootLease {
        guard plan.domain == .synthetic else { throw Failure.capabilityUnknown }
        return try AppTrialRootLease(existing: plan)
    }
    deinit { if fd >= 0 { close(fd) } }
    static func synthetic(_ plan: AppInitialTrialPlan) throws -> AppTrialRootLease {
        guard plan.domain == .synthetic else { throw Failure.capabilityUnknown }
        return try AppTrialRootLease(plan: plan)
    }
    static func production(_ plan: AppInitialTrialPlan) throws -> AppTrialRootLease {
        guard plan.domain == .production,
              plan.isPinnedProductionPlan else { throw Failure.identityMismatch }
        return try AppTrialRootLease(plan: plan)
    }
    func validate(requireEmpty: Bool = true) throws {
        var held = stat(), current = stat()
        guard fstat(fd, &held) == 0, lstat(plan.root, &current) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else { throw Failure.profilePathConflict }
        for suffix in ["", "/codex", "/desktop", "/cwd", "/control"] {
            try inspectDirectoryPath(plan.root + suffix, privateRoot: plan.root)
            var info = stat()
            guard lstat(plan.root + suffix, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.profilePathConflict }
            if !suffix.isEmpty {
                let name = String(suffix.dropFirst())
                guard let held = children[name], held.0 == info.st_dev, held.1 == info.st_ino else { throw Failure.profilePathConflict }
                if requireEmpty && name != "control" {
                    guard try FileManager.default.contentsOfDirectory(atPath: plan.root + suffix).isEmpty else { throw Failure.profilePathConflict }
                }
            }
        }
    }
}

// The only production launch leaf. No injected verifier, imported approval, or external receipt enters here.
enum ProductionInitialTrial {
    static func requireTerminal() throws {
        guard Thread.isMainThread, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              tcgetpgrp(STDIN_FILENO) == getpgrp() else { throw Failure.approvalRequired }
    }
    // Keep AppKit properties fresh while awaiting a bounded, non-secret terminal answer.
    static func answer(_ prompt: String, onEOF: () throws -> Void = {}) throws -> String {
        try requireTerminal()
        print(prompt); fflush(stdout)
        var bytes = [UInt8]()
        while true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            if ready < 0 { if errno == EINTR { continue }; throw Failure.io }
            if ready == 0 { continue }
            try requireTerminal()
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { try onEOF(); throw Failure.approvalRequired }
            guard count == 1 else { throw Failure.approvalRequired }
            if byte == 10 { return String(bytes: bytes, encoding: .utf8) ?? "" }
            guard byte >= 32, byte < 127, bytes.count < 80 else { throw Failure.approvalRequired }
            bytes.append(byte)
        }
    }
    static func pump(until done: () -> Bool, seconds: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.processUnknown }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    private static func strictSignature(_ path: String, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { throw Failure.identityMismatch }
        var requirement: SecRequirement?
        let source = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"\(identifier)\""
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess else { throw Failure.identityMismatch }
        let status = SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement)
        guard status == errSecSuccess else {
            FileHandle.standardError.write(Data("서명 검증 실패 OSStatus=\(status). 이 실행 컨텍스트에서는 시작하지 않습니다.\n".utf8))
            throw Failure.identityMismatch
        }
    }
    static func checkSignatures(_ bundle: String) throws {
        try strictSignature(bundle, identifier: "com.openai.codex")
        try strictSignature(bundle + "/Contents/Resources/codex-cli/CodexCLI.app", identifier: "codex")
    }
    static func checkBinaries(_ plan: AppInitialTrialPlan) throws {
        guard plan.isPinnedProductionPlan else { throw Failure.identityMismatch }
        let files = AppBinaryFiles.localReadOnly()
        func checkWorkResources() throws {
            guard files.canonicalPath(CodexSplitPaths.officialResources) == CodexSplitPaths.officialResources,
                  files.digest(CodexSplitPaths.officialResources) == WorkAppPins.current.resourcesSHA256 else { throw Failure.identityMismatch }
        }
        try checkWorkResources()
        let before = try readAppBinaries(bundle: plan.bundlePath, files: files)
        try checkSignatures(plan.bundlePath)
        let after = try readAppBinaries(bundle: plan.bundlePath, files: files)
        try checkWorkResources()
        for reading in [before, after] {
            guard reading.officialSource == .supported,
                  reading.app.path == plan.executablePath, reading.app.version == plan.appVersion,
                  reading.app.build == plan.appBuild, reading.app.fingerprint == plan.appFingerprint,
                  reading.server.path == plan.cliExecutablePath, reading.server.version == plan.cliVersion,
                  reading.server.build == plan.cliBuild, reading.server.fingerprint == plan.cliFingerprint
            else { throw Failure.identityMismatch }
        }
    }
    static func openVerified(_ target: AppInitialTrialPlan, consentExpiresAt: Date,
                             finalCheck: () throws -> Void) throws -> AppInitialTrialObjectAdapter<NSRunningApplication> {
        try openBound(target, consentExpiresAt: consentExpiresAt, checkContext: requireTerminal, finalCheck: finalCheck)
    }
    static func openVerifiedGUI(_ permit: WorkDailyLaunchPermit,
                                onStage: ((WorkDailyFailureStage) -> Void)? = nil, finalCheck: () throws -> Void) throws -> AppInitialTrialObjectAdapter<NSRunningApplication> {
        try permit.validateProduction(now: Date())
        return try openBound(permit.plan, consentExpiresAt: permit.expiresAt,
            checkContext: { try permit.validateProduction(now: Date()) }, onStage: onStage, finalCheck: finalCheck)
    }
    private static func openBound(_ target: AppInitialTrialPlan, consentExpiresAt: Date,
                                  checkContext: () throws -> Void, onStage: ((WorkDailyFailureStage) -> Void)? = nil,
                                  finalCheck: () throws -> Void) throws -> AppInitialTrialObjectAdapter<NSRunningApplication> {
        onStage?(.workspaceVerification)
        try checkContext()
        try checkBinaries(target)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.activates = true
            configuration.hidesOthers = false
            configuration.environment = ["CODEX_HOME": target.root + "/codex", "CODEX_SQLITE_HOME": target.root + "/codex",
                "CODEX_ELECTRON_USER_DATA_PATH": target.root + "/desktop"]
            configuration.arguments = ["--user-data-dir=" + target.root + "/desktop"]
            var finished = false
            var completed: NSRunningApplication?
            var failed = false
            var submittedAt = Date()
            onStage?(.workspaceSubmission)
            try submitWithinConsent(expiresAt: consentExpiresAt, now: Date.init, finalCheck: {
                try checkContext()
                try finalCheck()
            }, submit: {
            submittedAt = Date()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target.bundlePath), configuration: configuration) { app, error in
                DispatchQueue.main.async {
                    completed = app
                    failed = error != nil
                    finished = true
                }
            }
            })
            // Timeout retains the durable unknown reservation. No cancellation, kill, or retry.
            onStage?(.workspaceCompletion)
            try pump(until: { finished }, seconds: 30)
            guard !failed, let completed else { throw Failure.processUnknown }
            onStage?(.completionAttribution)
            let bound = try AppInitialTrialObjectAdapter<NSRunningApplication>.productionCompletion(completed, plan: target, submittedAt: submittedAt, now: Date())
            return bound
    }
}
