import Foundation

var starts = 0
var callbackDuringWait = false
var finished = false
var onMainThread = false
let scheduler = WorkDailyStartScheduler {
    starts += 1
    onMainThread = Thread.isMainThread
    var callbackRan = false
    DispatchQueue.main.async { callbackRan = true }
    do {
        try ProductionInitialTrial.pump(until: { callbackRan }, seconds: 0.5)
        callbackDuringWait = callbackRan
    } catch {}
    finished = true
}
DispatchQueue.main.async {
    scheduler.schedule()
    scheduler.schedule()
}
let end = Date().addingTimeInterval(2)
while !finished && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
guard finished && callbackDuringWait else { print("실패: GUI 시작 대기 중 main queue 완료 callback 실행"); exit(1) }
guard starts == 1 else { print("실패: 예약된 중복 시작 합치기"); exit(1) }
guard onMainThread else { print("실패: AppKit 실행은 main thread에서 유지"); exit(1) }
print("3개 GUI RunLoop/dispatch 회귀 통과 (실제 앱 실행 없음)")
