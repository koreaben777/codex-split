import Foundation
import Darwin
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("FAIL: " + label); exit(1) }
}
let date = Date(timeIntervalSince1970: 1_790_000_000)
let plan = AppInitialTrialPlan.workSetup(requestedAt: date)
var appVersion = plan.appVersion
var cliVersion = plan.cliVersion
var appHash = plan.appFingerprint
var cliHash = plan.cliFingerprint
var resourceHash: String? = WorkAppPins.current.resourcesSHA256
var signature = SignatureReport(state: "valid-openai", team: "2DC432GLL2", cdhash: "abcd")
var canonical = true
var strict = true
var race = false
var reads = 0
let files = AppBinaryFiles(read: { path in
    if path.hasSuffix("codex-package.json") { return try JSONSerialization.data(withJSONObject: ["version": cliVersion]) }
    let cli = path.contains("CodexCLI.app")
    return try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": cli ? "codex" : "com.openai.codex",
        "CFBundleExecutable": cli ? "codex" : "ChatGPT",
        "CFBundleVersion": cli ? plan.cliBuild : plan.appBuild,
        "CFBundleShortVersionString": cli ? cliVersion : appVersion
    ], format: .xml, options: 0)
}, canonicalPath: { canonical ? $0 : "/unexpected" }, digest: { path in
    if path.hasSuffix("app.asar") { return resourceHash }
    if path == plan.executablePath {
        reads += 1
        return race && reads > 1 ? String(repeating: "f", count: 64) : appHash
    }
    return cliHash
}, signature: { _ in signature })
let inspector = WorkUpdateInspector(files: files, verifySignatures: { _ in if !strict { throw Failure.identityMismatch } }, now: { date })
check(inspector.inspect().status == .pinned, "exact signed identity")
check(!inspector.inspect().launchPermitted, "diagnostics never authorize launch")
appVersion = "new"
check(inspector.inspect().differences.map(\.field) == ["app.version"], "version change reported")
check(inspector.inspect().status == .reviewRequired, "new version requires review")
appVersion = plan.appVersion
appHash = String(repeating: "a", count: 64)
check(inspector.inspect().differences.map(\.field) == ["app.sha256"], "same-version executable change")
appHash = plan.appFingerprint
resourceHash = String(repeating: "b", count: 64)
check(inspector.inspect().differences.map(\.field) == ["resources.sha256"], "resource-only update")
resourceHash = WorkAppPins.current.resourcesSHA256
cliVersion = "new-cli"; cliHash = String(repeating: "c", count: 64)
check(inspector.inspect().differences.map(\.field) == ["cli.version", "cli.sha256"], "CLI-only update")
cliVersion = plan.cliVersion; cliHash = plan.cliFingerprint
strict = false
check(inspector.inspect().status == .unverified, "identifier-specific signature rejects")
strict = true; signature.team = "wrong"
check(inspector.inspect().status == .unverified, "foreign team")
signature.team = "2DC432GLL2"; canonical = false
check(inspector.inspect().status == .unverified, "symlink fails closed")
canonical = true; resourceHash = nil
check(inspector.inspect().status == .unverified, "missing resource")
resourceHash = WorkAppPins.current.resourcesSHA256
race = true; reads = 0
let raced = inspector.inspect()
check(raced.status == .unverified && raced.reason == "changed-during-inspection" && raced.observed == nil, "update during signature verification")
race = false
let review = WorkUpdateReviewPlan(report: inspector.inspect())
check(!review.launchPermitted && !review.recordReplacementPermitted && review.checks.map(\.id) == ["baseline", "release-evidence", "identity", "storage-auth-ipc", "preservation-recovery", "trial-consent"],
      "review template matches the installer's required items and is not approval")
for name in ["update-check", "update-plan"] {
    check(try Command.parse([name, "work", "--json"]).json, "parser supports " + name)
    check((try? Command.parse([name, "personal"])) == nil, "work only")
    check((try? Command.parse([name, "work", "--force"])) == nil, "no force flag")
}
print("Work update checks passed: \(checks)")
