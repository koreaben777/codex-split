import Foundation

// What the progress window shows for one automatic update run. It only reads the run's files;
// closing the window or this view failing never affects the run.
struct WorkUpdateProgress: Equatable {
    static let steps = 5
    let step: Int
    let text: String
    let finished: Bool
    static func describe(phase: String?, reviewWritten: Bool, launcherRunning: Bool, runnerAlive: Bool,
                         lastCheck: String?, error: String?) -> Self {
        let kept = " 기존 런처와 업무 기록은 그대로입니다."
        switch phase {
        case "installed":
            return Self(step: 5, text: "완료: 업무 런처를 교체했습니다. 런처를 열어 새 구간을 시작하세요.", finished: true)
        case "unchanged":
            return Self(step: 5, text: "공식 앱이 고정 버전과 같아 할 일이 없습니다." + kept, finished: true)
        case let phase? where phase.hasPrefix("blocked"):
            return Self(step: 5, text: "중단(\(phase))" + (error.map { ": " + $0 } ?? "") + "." + kept, finished: true)
        default: break
        }
        // The run writes its result before it exits; anything else means it ended without one.
        guard runnerAlive else { return Self(step: 5, text: "자동 대응이 결과 기록 없이 끝났습니다." + kept, finished: true) }
        switch phase {
        case "testing":
            return Self(step: 2, text: "후보 런처 빌드와 전체 시험 중 (몇 분 걸립니다)" + (lastCheck.map { "\n최근: " + $0 } ?? ""), finished: false)
        case "awaiting-compatibility-review" where !reviewWritten:
            return Self(step: 3, text: "공식 앱 재검사와 자동 검토 기록 작성 중", finished: false)
        case "awaiting-compatibility-review":
            return launcherRunning
                ? Self(step: 4, text: "업무 런처가 닫히기를 기다리는 중입니다. 업무 창을 Cmd-Q로 닫아 주세요.", finished: false)
                : Self(step: 4, text: "백업을 남기고 업무 런처 교체 중", finished: false)
        default:
            return Self(step: 1, text: "공식 앱 서명·버전 확인 중", finished: false)
        }
    }
}
