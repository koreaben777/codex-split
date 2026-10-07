import Foundation
import Security
import CryptoKit
import Darwin

// Contract only: no app-server is started and no credential storage is opened.
func accountObservation(_ data: Data, expectedEmail: String) -> AccountState {
    guard data.count <= 65_536, !expectedEmail.isEmpty,
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = message["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
          id == 1, message["error"] == nil,
          let result = message["result"] as? [String: Any],
          let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt",
          let email = account["email"] as? String, !email.isEmpty,
          !email.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return .unverified }
    return email == expectedEmail ? .confirmed : .mismatch
}

struct SignatureReport: Codable, Equatable {
    var state = "unknown"
    var team: String?
    var cdhash: String?
}
func inspectSignature(_ path: String) -> SignatureReport {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
          let code else { return SignatureReport() }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString, [], &requirement) == errSecSuccess else { return SignatureReport() }
    let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
    var info: CFDictionary?
    let infoResult = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    if infoResult == errSecCSUnsigned { return SignatureReport(state: "unsigned") }
    guard infoResult == errSecSuccess,
          let dictionary = info as? [String: Any] else { return SignatureReport(state: "unknown") }
    return SignatureReport(state: valid ? "valid-openai" : "invalid",
        team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
        cdhash: (dictionary[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined())
}
func fileDigest(_ path: String) -> String? {
    guard let stream = InputStream(fileAtPath: path) else { return nil }
    stream.open(); defer { stream.close() }
    var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        hash.update(data: Data(buffer.prefix(count)))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
struct FileReport: Codable {
    var path: String
    var resolvedPath: String
    var version: String
    var build: String
    var sha256: String?
    var signature: SignatureReport
}
func inspectFile(_ path: String, version: String = "unknown", build: String = "unknown") -> FileReport {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return FileReport(path: path, resolvedPath: resolved, version: version, build: build,
                      sha256: fileDigest(resolved), signature: inspectSignature(resolved))
}
struct ObservedProcess: Codable, Equatable {
    var pid: Int32
    var parentPID: Int32
    var uid: UInt32
    var startedAt: String
    var executable: String
}
func parseProcesses(_ text: String) -> [ObservedProcess]? {
    var result: [ObservedProcess] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 9, let pid = Int32(parts[0]), pid > 0,
              let parent = Int32(parts[1]), let uid = UInt32(parts[2]) else { return nil }
        result.append(ObservedProcess(pid: pid, parentPID: parent, uid: uid,
            startedAt: parts[3...7].joined(separator: " "), executable: parts[8].trimmingCharacters(in: .whitespaces)))
    }
    return result
}
func databasePaths(_ text: String, pid: Int32) -> [String]? {
    let lines = text.split(separator: "\n")
    guard lines.first == Substring("p\(pid)"), lines.filter({ $0.hasPrefix("p") }).count == 1 else { return nil }
    return Array(Set(lines.filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }.filter {
        ["sqlite", "sqlite3", "db"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    })).sorted()
}
// Only fixed macOS metadata commands call this helper. No shell, argv dump or environment dump.
func metadataCommand(_ executable: String, _ arguments: [String]) -> String? {
    let child = Process(), output = Pipe()
    child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TZ": "UTC"]
    child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice; child.standardOutput = output
    do { try child.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    guard child.terminationReason == .exit, child.terminationStatus == 0, data.count <= 4_194_304 else { return nil }
    return String(data: data, encoding: .utf8)
}
struct EnvironmentReport: Codable {
    var schemaVersion = 1
    var app: FileReport
    var bundledCLI: FileReport
    var bundledNativeCLI: FileReport
    var pathCLI: FileReport?
    var pathNativeCLI: FileReport?
    var processQuery: String
    var processes: [ObservedProcess]
    var observedDatabaseFiles: [String: [String]]
    var storageQuery: [String: String]
    var effectiveStorage = "unknown"
    var profileBinding = "unknown"
    var account = "unverified (account/read transport not enabled)"
    var localConnection = "unknown (manual record is not live evidence)"
    var generalUse = "blocked"
}
func inspectEnvironment() -> EnvironmentReport {
    let bundle = "/Applications/ChatGPT.app"
    let plist = (try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    } ?? [:]
    let package = (try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Resources/codex-cli/codex-package.json"))).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    let executable = plist["CFBundleExecutable"] as? String ?? "Codex"
    let safeName = !executable.isEmpty && !executable.contains("/") && executable != "." && executable != ".."
    var app = inspectFile(bundle + "/Contents/MacOS/" + (safeName ? executable : "__unknown__"),
        version: plist["CFBundleShortVersionString"] as? String ?? "unknown", build: plist["CFBundleVersion"] as? String ?? "unknown")
    app.signature = inspectSignature(bundle)
    let bundled = inspectFile(bundle + "/Contents/Resources/codex-cli/bin/codex", version: package["version"] as? String ?? "unknown")
    let nestedInfo = (try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/Info.plist"))).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
    let bundledNative = inspectFile(bundle + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        version: package["version"] as? String ?? "unknown", build: nestedInfo?["CFBundleVersion"] as? String ?? "unknown")
    var pathCLI: FileReport?
    var nativeCLI: FileReport?
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
        let candidate = String(directory) + "/codex"
        guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
        let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        // Recognize the official npm layout only; never inspect arbitrary PATH wrapper contents.
        if resolved.hasSuffix("/node_modules/@openai/codex/bin/codex.js") {
            let packageURL = URL(fileURLWithPath: resolved).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")
            let info = (try? Data(contentsOf: packageURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            pathCLI = inspectFile(candidate, version: info?["version"] as? String ?? "unknown")
            #if arch(arm64)
            let suffix = "/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin"
            #else
            let suffix = "/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin"
            #endif
            let nativeRoot = packageURL.deletingLastPathComponent().path + suffix
            let nativePackage = (try? Data(contentsOf: URL(fileURLWithPath: nativeRoot + "/codex-package.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            nativeCLI = inspectFile(nativeRoot + "/bin/codex", version: nativePackage?["version"] as? String ?? "unknown")
        }
        break
    }
    let all = metadataCommand("/bin/ps", ["-ww", "-axo", "pid=,ppid=,uid=,lstart=,comm="]).flatMap(parseProcesses)
    let candidates = (all ?? []).filter { $0.executable == app.resolvedPath || $0.executable == bundled.resolvedPath || $0.executable == bundledNative.resolvedPath || $0.executable == nativeCLI?.resolvedPath }
    var files: [String: [String]] = [:], states: [String: String] = [:]
    for process in candidates {
        let key = String(process.pid)
        let paths = metadataCommand("/usr/sbin/lsof", ["-b", "-S", "2", "-a", "-p", key, "-Fpn", "-nP"]).flatMap { databasePaths($0, pid: process.pid) }
        // ps start time is coarse and cannot exclude PID reuse. Never authorize from this report.
        if let paths { files[key] = paths; states[key] = "metadata-only / binding-unknown" }
        else { states[key] = "unknown" }
    }
    return EnvironmentReport(app: app, bundledCLI: bundled, bundledNativeCLI: bundledNative, pathCLI: pathCLI, pathNativeCLI: nativeCLI,
        processQuery: all == nil ? "unknown" : "metadata-only / binding-unknown", processes: candidates,
        observedDatabaseFiles: files, storageQuery: states)
}
