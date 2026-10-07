import Foundation
import Darwin

// Synthetic fixture directories only: no official app, work profile or launcher is touched.
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    checks += 1
    if (try? value()) != true { print("FAIL: " + label); exit(1) }
}
func rejected(_ label: String, _ action: () throws -> Void) {
    checks += 1
    do { try action(); print("FAIL: " + label); exit(1) } catch {}
}
let fm = FileManager.default
let base = fm.currentDirectoryPath + "/.test-data/work-adoption-" + UUID().uuidString
try fm.createDirectory(atPath: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? fm.removeItem(atPath: base) }
func profile(_ name: String, control: Bool = true, children: [String] = ["codex", "desktop", "cwd"]) throws -> String {
    let root = base + "/" + name
    try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for child in children + (control ? ["control"] : []) {
        try fm.createDirectory(atPath: root + "/" + child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try Data("thread".utf8).write(to: URL(fileURLWithPath: root + "/codex/session.jsonl"))
    if control { try Data("{\"old\":true}".utf8).write(to: URL(fileURLWithPath: root + "/control/state.json")) }
    return root
}
func inode(_ path: String) -> UInt64 { var info = stat(); lstat(path, &info); return UInt64(info.st_ino) }
let profiles = base + "/profiles"
try fm.createDirectory(atPath: profiles, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let legacy = base + "/legacy"
let time = Date()
var busy = false
let adopter = WorkProfileAdopter(inUse: { _ in busy }, now: { time })

let source = try profile("old-work")
let codexInode = inode(source + "/codex")
let target = profiles + "/work"
rejected("profile in use is never moved") { busy = true; defer { busy = false }; _ = try adopter.adopt(from: source, to: target, legacy: legacy) }
check(fm.fileExists(atPath: source + "/codex/session.jsonl") && !fm.fileExists(atPath: target), "refusal leaves the source in place")
rejected("legacy folder inside the target is refused") { _ = try adopter.adopt(from: source, to: target, legacy: target + "/legacy") }
let occupied = try profile("occupied")
rejected("an existing target is never overwritten") { _ = try adopter.adopt(from: source, to: occupied, legacy: legacy) }
let incomplete = try profile("incomplete", children: ["codex", "desktop"])
rejected("a root without the fixed children is not a profile") { _ = try adopter.adopt(from: incomplete, to: profiles + "/other", legacy: legacy) }
let looseProfile = try profile("open")
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: looseProfile + "/desktop")
rejected("non-private children are refused") { _ = try adopter.adopt(from: looseProfile, to: profiles + "/other", legacy: legacy) }
try fm.createSymbolicLink(atPath: base + "/linked", withDestinationPath: source)
rejected("a symlinked source is refused") { _ = try adopter.adopt(from: base + "/linked", to: profiles + "/other", legacy: legacy) }

let adoption = try adopter.adopt(from: source, to: target, legacy: legacy)
check(!fm.fileExists(atPath: source) && inode(target + "/codex") == codexInode, "moved by rename: same inode, no copy left behind")
check(try String(contentsOfFile: target + "/codex/session.jsonl", encoding: .utf8) == "thread", "profile data intact")
check(try fm.contentsOfDirectory(atPath: target + "/control").isEmpty, "the work root starts with empty control records")
check(adoption.legacyControl.map { (try? String(contentsOfFile: $0 + "/state.json", encoding: .utf8)) == "{\"old\":true}" } == true,
      "earlier control records are preserved unchanged outside the work root")
check(adoption.directories == (try WorkDirectory.snapshot(target)) && adoption.fromRoot == source, "adoption evidence matches the moved root")

// The setup record carries the adoption; fresh-setup rules otherwise apply unchanged.
let plan = AppInitialTrialPlan(requestID: UUID(), requestedAt: time.addingTimeInterval(-1), domain: .synthetic, root: target,
    bundlePath: "/synthetic/App.app", executablePath: "/synthetic/App.app/Contents/MacOS/App", appVersion: "1", appBuild: "1",
    appFingerprint: "fake", cliExecutablePath: "/synthetic/App.app/Contents/MacOS/cli", cliVersion: "1", cliBuild: "1", cliFingerprint: "fake")
let setup = WorkSetupCoordinator.synthetic(store: try PrivateStore(root: target + "/control"), now: { time })
let approvedAt = time.addingTimeInterval(-0.5)
rejected("adoption cannot predate its approval") {
    let early = WorkSetupAdoption(fromRoot: source, legacyControl: adoption.legacyControl, adoptedAt: approvedAt.addingTimeInterval(-1), directories: adoption.directories)
    try setup.initialize(plan: plan, approvedAt: approvedAt, adoption: early)
}
rejected("adoption evidence cannot point inside the work root") {
    let inside = WorkSetupAdoption(fromRoot: target + "/codex", legacyControl: nil, adoptedAt: time, directories: adoption.directories)
    try setup.initialize(plan: plan, approvedAt: approvedAt, adoption: inside)
}
try setup.initialize(plan: plan, approvedAt: approvedAt, adoption: adoption)
check(try setup.store.read().workSetup?.adoption == adoption && setup.store.read().workSetup?.completed == false,
      "adopted setup is recorded but needs its own two visits")
let lease = try AppTrialRootLease.syntheticExisting(plan)
check((try? lease.validate(requireEmpty: false)) != nil, "existing-root lease accepts the adopted profile")
check((try? lease.validate(requireEmpty: true)) == nil, "an adopted profile is never mistaken for a fresh root")
let listing = "  101 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT --user-data-dir=/old/work/desktop\n  202 codex-split-work-setup --adopt work --from /old/work\n  303 /bin/zsh -l\n"
check(WorkProfileAdopter.processesUse(listing, source: "/old/work", ownPID: 202), "the official app using the profile blocks adoption")
check(!WorkProfileAdopter.processesUse("  202 codex-split-work-setup --adopt work --from /old/work\n  303 /bin/zsh -l\n", source: "/old/work", ownPID: 202),
      "the adopting tool's own --from argument does not count as use")
check(WorkProfileAdopter.processesUse("garbled\n", source: "/old/work", ownPID: 202), "an unparsable process listing fails closed")
print("\(checks) profile adoption checks passed (synthetic fixture directories only)")
