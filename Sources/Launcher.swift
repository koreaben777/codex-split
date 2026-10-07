import AppKit
import Foundation
import Darwin

// Thin development UI. All authorization and durable reservations remain in the sibling CLI.
@main
struct CodexSplitLauncher {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "CodexSplit (개발)"
        alert.addButton(withTitle: "확인")
        alert.alertStyle = .warning
        do {
            let bundle = Bundle.main
            guard let rawProfile = bundle.object(forInfoDictionaryKey: "CodexSplitProfile") as? String,
                  let profile = ProfileID(rawValue: rawProfile) else { throw CocoaError(.fileReadCorruptFile) }
            alert.messageText = profile == .work ? "CodexSplit 업무용 (개발)" : "CodexSplit 개인용 (개발)"
            let cli = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("codex-split")
            guard cli.path == cli.resolvingSymlinksInPath().path,
                  FileManager.default.isExecutableFile(atPath: cli.path) else { throw CocoaError(.fileNoSuchFile) }
            let process = Process(), output = Pipe()
            let descriptor = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CocoaError(.fileReadUnknown) }
            defer { try? output.fileHandleForReading.close() }
            process.executableURL = cli
            process.currentDirectoryURL = cli.deletingLastPathComponent()
            process.arguments = ["app", profile.rawValue, "--json"]
            process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"].contains($0.key) }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Close our write end so EOF means the child's output descriptors closed.
            try? output.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            let receipt = receiveLauncherReply(profile: profile, read: {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { return .bytes(Data(bytes.prefix(count))) }
                if count == 0 { return .eof }
                return errno == EAGAIN || errno == EINTR ? .waiting : .failed
            }, exitStatus: { process.isRunning ? nil : process.terminationStatus },
            expired: { ProcessInfo.processInfo.systemUptime >= deadline },
            pause: { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) })
            switch receipt {
            case .reply(let reply):
                alert.informativeText = reply.message
                alert.alertStyle = reply.state == .blocked ? .warning : .informational
            case .invalid:
                alert.informativeText = "CLI 결과의 형식이나 프로필을 확인할 수 없습니다. 실행 상태는 미확인입니다. 반복 실행 대신 상태를 확인하세요."
            case .timedOut:
                alert.informativeText = "5초 안에 실행 결과를 확인하지 못했습니다. 요청이 계속 진행 중일 수 있으므로 반복 실행하지 말고 상태를 확인하세요. 기존 앱은 강제 종료하지 않습니다."
            }
            // A timeout is not proof the CLI or GUI exited. Do not terminate them or clear pending.
        } catch {
            alert.informativeText = "런처 옆의 개발용 CLI 또는 런처 메타데이터를 확인하세요. 파일을 단독으로 옮기지 말고 개발 빌드를 다시 준비하세요."
        }
        application.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
