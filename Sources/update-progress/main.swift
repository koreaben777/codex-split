import AppKit
import Foundation

// Read-only progress window for scripts/update-work.py --auto, which starts it with the run directory.
// It never writes, locks or signals anything; the parent process (the run) leaving means the run ended.
guard CommandLine.arguments.count == 2, safeAbsolutePath(CommandLine.arguments[1]) else { exit(64) }
let run = CommandLine.arguments[1]
let runner = getppid()

func readProgress() -> WorkUpdateProgress {
    let alive = getppid() == runner // checked before the result file, which is written before the run exits
    let result = (try? Data(contentsOf: URL(fileURLWithPath: run + "/RESULT.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let log = (try? String(contentsOfFile: run + "/checks.log", encoding: .utf8)) ?? ""
    let lastCheck = log.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { String($0.prefix(120)) }
    let launcher = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.codexsplit.work").filter { !$0.isTerminated }.isEmpty
    return .describe(phase: result?["phase"] as? String, reviewWritten: FileManager.default.fileExists(atPath: run + "/REVIEW.json"),
                     launcherRunning: launcher, runnerAlive: alive, lastCheck: lastCheck, error: result?["errorMessage"] as? String)
}

final class ProgressWindow: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    let stage = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let bar = NSProgressIndicator()
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.title = "CodexSplit 업무용 — 업데이트 자동 대응"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        stage.font = .boldSystemFont(ofSize: 13)
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = Double(WorkUpdateProgress.steps)
        let stack = NSStackView(views: [stage, bar, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        bar.widthAnchor.constraint(equalToConstant: 408).isActive = true
        detail.preferredMaxLayoutWidth = 408
        panel.contentView = stack
        panel.center()
        update()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func update() {
        let progress = readProgress()
        stage.stringValue = progress.finished ? "자동 대응 끝" : "단계 \(progress.step)/\(WorkUpdateProgress.steps)"
        detail.stringValue = progress.text + (progress.finished ? "" : "\n이 창을 닫아도 자동 대응은 계속됩니다.")
        bar.doubleValue = Double(progress.step)
        if progress.finished { timer?.invalidate(); timer = nil }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = ProgressWindow()
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }
