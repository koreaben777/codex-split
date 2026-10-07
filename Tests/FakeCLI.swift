import Foundation
import Darwin

if Array(CommandLine.arguments.dropFirst()) == ["--wait"] {
    var terminal = termios()
    if tcgetattr(STDIN_FILENO, &terminal) == 0 {
        terminal.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &terminal)
    }
    print("READY")
    fflush(stdout)
    while true { pause() }
}
if Array(CommandLine.arguments.dropFirst()) == ["--interrupt-self"] {
    signal(SIGINT, SIG_DFL)
    raise(SIGINT)
    exit(99)
}
let result: [String: Any] = ["arguments": Array(CommandLine.arguments.dropFirst()),
                           "cwd": FileManager.default.currentDirectoryPath,
                           "environment": ProcessInfo.processInfo.environment]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/received.json"))
exit(7)
