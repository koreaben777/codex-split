import Foundation
import Darwin

// Per-user locations come from the account database, not $HOME, so an environment
// change cannot redirect the work profile, the installed launcher or its receipts.
enum CodexSplitPaths {
    static let home: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "/nonexistent" }
        return URL(fileURLWithPath: String(cString: directory)).standardizedFileURL.path
    }()
    static let support = home + "/Library/Application Support/CodexSplit"
    static let workRoot = support + "/profiles/work"
    static let installedWorkLauncher = home + "/Applications/CodexSplit-work.app"
    static let replacementPrefix = home + "/Applications/.CodexSplit-work-replacement-"
    static let officialBundle = "/Applications/ChatGPT.app"
    static let officialExecutable = officialBundle + "/Contents/MacOS/ChatGPT"
    static let officialCLI = officialBundle + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let officialResources = officialBundle + "/Contents/Resources/app.asar"
}
