import Foundation
import AppKit
import Darwin

// Terminal-only work profile setup: one sign-in visit and one reopen, each with an exact typed consent.
guard CommandLine.arguments.count == 3, ["--setup", "--resume-setup"].contains(CommandLine.arguments[1]), CommandLine.arguments[2] == "work" else {
    print("Usage: codex-split-work-setup --setup work | --resume-setup work"); exit(64)
}
do { try ProductionWorkSetup.run(resume: CommandLine.arguments[1] == "--resume-setup") }
catch {
    print("업무 설정 중단: \((error as? Failure)?.rawValue ?? "IO_ERROR"). 저장소/예약 보존. 자동 재실행·로그아웃·강제 종료·삭제하지 마세요. 재개에는 새 동의가 필요합니다.")
    exit(2)
}
