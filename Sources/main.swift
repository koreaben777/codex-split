import Foundation
import Darwin

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    print("")
}
func blocked(_ reason: Failure, _ detail: String) -> Never {
    print("\(reason.rawValue): \(detail)")
    exit(2)
}
do {
    let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    let appCommands = AppCommandContext.uncommissioned
    switch command.name {
    case "help":
        print("""
        codex-split — development foundation (no operational profiles registered)
        profiles | doctor | status <personal|work> [--json]
        cli <profile> --cwd <absolute-path> | app <profile> [--json]
        update-check work [--json] | update-plan work --json (read-only; 0 pinned, 2 review/unverified)
        update-directory-check work --json (read-only; folder continuity, never grants consent)
        login <profile> | verify-auth <profile>
        verify <profile> --target <cli|app> --stage <basic|extended|day> --cwd <absolute-path>
        approve <profile> --target <cli|app> --stage <basic|extended|day> --cwd <absolute-path>

        status exit 0 means query completed, NOT authenticated, connected or approved.
        Actual launch/login/approval remain blocked until supported observation and account
        verification paths are implemented and separately tested. No passthrough or force.
        """)
    case "profiles":
        try emit(ProfileID.allCases.map { profileStatus(profile: $0, validation: nil, runtime: nil) })
    case "status":
        let status = profileStatus(profile: command.profile!, validation: nil, runtime: nil)
        if command.json { try emit(status) }
        else {
            print("\(status.profileId.rawValue): 실행 unknown · CLI/앱 계정 unverified · 운영 프로필 미등록")
            print("로컬 연결 unknown · 자동 확인 불가 · 공식 앱에서 별도 확인 필요")
            print("다음 단계: capability 확인 및 별도 승인된 신규 프로필 준비. 실제 앱은 실행하지 않았습니다.")
        }
    case "update-check", "update-plan":
        let report = WorkUpdateInspector.production().inspect()
        if command.name == "update-plan" { try emit(WorkUpdateReviewPlan(report: report)) }
        else if command.json { try emit(report) }
        else { print(report.text) }
        exit(report.exitCode)
    case "update-directory-check":
        do {
            let path = CodexSplitPaths.workRoot + "/control/work-daily.json"
            var info = stat()
            let daily: WorkDailyState
            if lstat(path, &info) != 0 && errno == ENOENT { daily = WorkDailyState() }
            else { daily = try WorkDailyState.decode(dailyReplacementReceiptData(path), now: Date()) }
            let directories = try WorkDirectory.snapshot(CodexSplitPaths.workRoot)
            let status = daily.directoryStatus(directories, bootSession: try WorkProcess.bootSession())
            struct Report: Encodable { let status: String; let directories: [String: WorkDirectory] }
            try emit(Report(status: status, directories: directories))
            exit(status == "blocked" ? 2 : 0)
        } catch {
            try emit(["status": "blocked"])
            exit(2)
        }
    case "doctor":
        try emit(inspectEnvironment())
    case "verify":
        print("진단 절차만 표시: \(command.profile!.rawValue) / \(command.target!.rawValue) / \(command.stage!.rawValue)")
        print("공식 제한 계정 확인·실제 저장 경로 관측 수단은 미검증입니다. 시험 실행·승인 기록은 만들지 않았습니다.")
        print("기본 → 2시간 확대 → 하루 시험 및 사용자 최종 승인은 별도 단계입니다.")
    case "login", "verify-auth":
        blocked(.capabilityUnknown, "제한 계정 확인 수단 미검증. 로그인은 실행하지 않았습니다. 업무 프로필 로그인은 codex-split-work-setup --setup work를 사용하세요.")
    case "approve":
        let decision = try appCommands.approve(command)
        if case .blocked(let reason) = decision {
            blocked(reason, "현재 identity·계정·실제 경로·단계별 시험 증거가 없습니다. 자동 승인하지 않습니다.")
        }
        print("명시적 승인 기록을 저장했습니다. 앱은 실행하지 않았습니다.")
    case "app":
        // The common path is tested with injected observation and backend dependencies.
        // Operational commissioning is absent; no config/env flag injects synthetic evidence.
        let reply = appCommands.open(command.profile!)
        if command.json { try emit(reply) }
        else { print(reply.title + "\n" + reply.message) }
        exit(reply.exitCode)
    case "cli":
        blocked(.authUnverified, "운영 프로필 미등록 및 계정 미확인. 실행을 차단했습니다. status/doctor/공식 로그인 안내만 제공합니다.")
    default: throw Failure.invalidArguments
    }
} catch {
    // Never interpolate parser input, inherited environment or raw system errors into diagnostics.
    print(Failure.invalidArguments.rawValue + ": codex-split help")
    exit(64)
}
