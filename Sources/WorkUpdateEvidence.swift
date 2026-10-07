// Replacement receipts written by scripts/install-work-update-approved.py, read without trusting their content.
import Foundation
import CryptoKit
import Darwin

func dailyDataDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func dailyReplacementReceiptDigest(_ path: String) throws -> String { dailyDataDigest(try dailyReplacementReceiptData(path)) }
func dailyReplacementReceiptData(_ path: String) throws -> Data {
    guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { throw Failure.stateInvalid }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try inspectDirectoryPath(parent, privateRoot: parent)
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw Failure.stateInvalid }; defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
          info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else { throw Failure.stateInvalid }
    var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0 else { throw Failure.io }; if n == 0 { break }
        data.append(contentsOf: bytes.prefix(n)); guard data.count <= 1_048_576 else { throw Failure.stateInvalid }
    }
    return data
}

// Reject unknown fields recursively, including fields silently discarded by Codable.
func dailySameJSONShape(_ input: Any, _ encoded: Any) -> Bool {
    if let a = input as? [String: Any], let b = encoded as? [String: Any] {
        return Set(a.keys) == Set(b.keys) && a.allSatisfy { dailySameJSONShape($0.value, b[$0.key]!) }
    }
    if let a = input as? [Any], let b = encoded as? [Any] {
        return a.count == b.count && zip(a, b).allSatisfy { dailySameJSONShape($0, $1) }
    }
    return !(input is [String: Any]) && !(input is [Any]) && !(input is NSNull) && !(encoded is NSNull)
}

struct WorkDailyReplacementEvidence: Codable {
    let receiptPath: String
    let receiptSHA256: String
    let fromManifestSHA256: String
    let toManifestSHA256: String
    func valid() -> Bool {
        let url = URL(fileURLWithPath: receiptPath)
        let prefix = CodexSplitPaths.replacementPrefix
        let workspace = url.deletingLastPathComponent().path
        let suffix = String(workspace.dropFirst(prefix.count))
        return url.lastPathComponent == "RESULT.json" && workspace.hasPrefix(prefix) && suffix.count == 32 &&
            suffix.allSatisfy { "0123456789abcdef".contains($0) } && safeAbsolutePath(receiptPath) &&
            [receiptSHA256, fromManifestSHA256, toManifestSHA256].allSatisfy(WorkDailyState.validHash)
    }
    // Finds the verified replacement that published this exact launcher and its update binding
    // (written by scripts/install-work-update-approved.py). Zero or several matches block.
    static func locateInstalled(launcherSHA256: String, root: String = CodexSplitPaths.home + "/Applications",
                                destination: String = CodexSplitPaths.installedWorkLauncher) throws -> (evidence: Self, reviewID: String?, replacedLauncherSHA256: String, automatic: Bool) {
        let receiptKeys: Set<String> = ["phase", "backup", "staging", "destination", "oldManifest", "newManifest",
                                        "stateTransitionPerformed", "fromManifestSHA256", "toManifestSHA256"]
        var found: [(Self, String?, String, Bool)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root) where name.hasPrefix(".CodexSplit-work-replacement-") {
            let workspace = root + "/" + name
            // A rolled-back replacement, or one whose backup is gone, is no longer evidence.
            var isDirectory: ObjCBool = false
            guard !FileManager.default.fileExists(atPath: workspace + "/RESTORE.json"),
                  FileManager.default.fileExists(atPath: workspace + "/previous.app", isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let receiptData = try? dailyReplacementReceiptData(workspace + "/RESULT.json"),
                  uniqueJSONKeys(receiptData),
                  let receipt = try? JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
                  Set(receipt.keys) == receiptKeys, receipt["phase"] as? String == "verified",
                  receipt["stateTransitionPerformed"] as? Bool == false, receipt["destination"] as? String == destination,
                  receipt["backup"] as? String == workspace + "/previous.app",
                  let replaced = ((receipt["oldManifest"] as? [String: Any])?["Contents/MacOS/launcher"] as? [Any])?.first as? String,
                  WorkDailyState.validHash(replaced),
                  let launcher = (receipt["newManifest"] as? [String: Any])?["Contents/MacOS/launcher"] as? [Any],
                  launcher.first as? String == launcherSHA256,
                  let from = receipt["fromManifestSHA256"] as? String, let to = receipt["toManifestSHA256"] as? String else { continue }
            guard let bindingData = try? dailyReplacementReceiptData(workspace + "/UPDATE.json"), uniqueJSONKeys(bindingData),
                  let binding = try? JSONSerialization.jsonObject(with: bindingData) as? [String: Any],
                  Set(binding.keys) == ["schemaVersion", "reviewID", "mode", "launcherSHA256", "toManifestSHA256", "reviewSHA256"],
                  let mode = binding["mode"] as? String, mode == "reviewed" || mode == "automatic",
                  let version = binding["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  binding["launcherSHA256"] as? String == launcherSHA256, binding["toManifestSHA256"] as? String == to,
                  let review = try? dailyReplacementReceiptData(workspace + "/REVIEW.json"),
                  binding["reviewSHA256"] as? String == dailyDataDigest(review) else { throw Failure.stateInvalid }
            let reviewID: String?
            if binding["reviewID"] is NSNull { reviewID = nil }
            else if let value = binding["reviewID"] as? String, WorkDailyUpdateTransition.validReviewID(value) { reviewID = value }
            else { throw Failure.stateInvalid }
            guard mode == "reviewed" || reviewID != nil else { throw Failure.stateInvalid }
            found.append((Self(receiptPath: workspace + "/RESULT.json", receiptSHA256: dailyDataDigest(receiptData),
                               fromManifestSHA256: from, toManifestSHA256: to), reviewID, replaced, mode == "automatic"))
        }
        guard found.count == 1 else { throw Failure.approvalRequired }
        return found[0]
    }
}
