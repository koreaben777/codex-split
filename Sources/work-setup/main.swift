import Foundation
import AppKit
import Darwin

// Terminal-only work profile setup with exact typed consents:
//   --setup work                  new profile: sign-in visit + reopen
//   --resume-setup work           first visit ended with login required
//   --adopt work --from <root>    move an existing profile (codex, desktop, cwd) in, then two keep-login visits
let args = Array(CommandLine.arguments.dropFirst())
let mode: ProductionWorkSetup.Mode
switch args {
case ["--setup", "work"]: mode = .setup
case ["--resume-setup", "work"]: mode = .resume
case _ where args.count == 4 && args[0] == "--adopt" && args[1] == "work" && args[2] == "--from" && safeAbsolutePath(args[3]):
    mode = .adopt(from: args[3])
default:
    print("Usage: codex-split-work-setup --setup work | --resume-setup work | --adopt work --from <absolute profile root>"); exit(64)
}
do { try ProductionWorkSetup.run(mode) }
catch {
    print("업무 설정 중단: \((error as? Failure)?.rawValue ?? "IO_ERROR"). 저장소/예약 보존. 자동 재실행·로그아웃·강제 종료·삭제하지 마세요. 재개에는 새 동의가 필요합니다.")
    exit(2)
}
