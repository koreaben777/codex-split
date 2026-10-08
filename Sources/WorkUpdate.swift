import Foundation
import Security
import Darwin

// Metadata-only update workflow. Neither a report nor its digest grants execution.
enum WorkUpdateStatus: String, Codable {
    case pinned, reviewRequired = "review-required", unverified
}
struct WorkUpdateSnapshot: Codable, Equatable {
    let app: BinaryIdentity
    let cli: BinaryIdentity
    let resourcesSHA256: String
    let appSignature: SignatureReport
    let cliSignature: SignatureReport
}
struct WorkUpdateDifference: Codable {
    let field: String
    let expected: String
    let observed: String
}
struct WorkUpdateReport: Encodable {
    let schemaVersion = 1
    let checkedAt: Date
    let status: WorkUpdateStatus
    let expected: AppInitialTrialPlan
    let expectedResourcesSHA256: String
    let observed: WorkUpdateSnapshot?
    let differences: [WorkUpdateDifference]
    let reason: String
    // These are deliberately false, including for a pinned binary: runtime/account/
    // path/consent checks still belong to the existing launch path.
    let launchPermitted = false
    let approvalChanged = false
    let nextSteps: [String]
    var exitCode: Int32 { status == .pinned ? 0 : 2 }
    var summary: String {
        switch status {
        case .pinned:
            return "앱·번들 CLI·리소스가 승인된 조합과 일치합니다. 실행 시 계정·경로·기존 승인 검사는 별도로 수행합니다."
        case .reviewRequired:
            return "승인된 조합과 다른 앱 업데이트를 감지했습니다. 변경 항목: " + differences.map(\.field).joined(separator: ", ")
                + "\n새 버전 검토와 별도 시험·승인이 필요합니다. 기존 업무 기록은 보존됩니다."
        case .unverified:
            return "앱의 서명·파일 또는 검사 중 일관성을 확인하지 못했습니다. 업데이트 완료나 호환성을 추정하지 않습니다. 기존 업무 기록은 보존됩니다."
        }
    }
    var text: String {
        summary + "\n상태: " + status.rawValue + " / " + reason
            + "\n" + nextSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

enum WorkUpdateGuide {
    // Source checkout that built this launcher, recorded inside the signed bundle by
    // scripts/build-work-daily.sh (and covered by the replacement manifest). CLI tools have none.
    // The bundle's own signature covers Resources/source-root; re-signing changes the launcher
    // hash every record is bound to, so an edited source-root cannot pass either way.
    static let ownBundleIntact: Bool = {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"local.codexsplit.work\"" as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }()
    static let sourceRoot: String? = {
        guard ownBundleIntact, let url = Bundle.main.url(forResource: "source-root", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeAbsolutePath(path), FileManager.default.isReadableFile(atPath: path + "/scripts/update-work.py") else { return nil }
        return path
    }()
    static var blockedLaunch: String {
        "업무 기록은 그대로 보존했고 업무 앱은 열지 않았습니다. CodexSplit 소스에서 업데이트 후보를 준비하세요: python3 "
            + (sourceRoot.map { $0 + "/" } ?? "") + "scripts/update-work.py (문서: docs/UPDATES.md). 설치 뒤 이 런처를 다시 열면 새 구간을 시작합니다."
    }
}

// Starts scripts/update-work.py --auto detached from the launcher; the script owns every check,
// the backed-up replacement and the notification. Nothing here opens the official app.
enum WorkUpdateAutomation {
    static var lockPath: String? { WorkUpdateGuide.sourceRoot.map { $0 + "/.build/work-updates/update.lock" } }
    static func running() -> Bool {
        guard let lockPath else { return false }
        let fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
    static func start(consentedAt: Date) throws {
        guard let sourceRoot = WorkUpdateGuide.sourceRoot else { throw Failure.capabilityUnknown }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [sourceRoot + "/scripts/update-work.py", "--auto", "--consented-at", String(consentedAt.timeIntervalSince1970)]
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

struct WorkUpdateInspector {
    let files: AppBinaryFiles
    // Production uses the same identifier-specific strict verification as launch.
    let verifySignatures: (String) throws -> Void
    let now: () -> Date
    static func production() -> Self {
        Self(files: .localReadOnly(), verifySignatures: ProductionInitialTrial.checkSignatures, now: Date.init)
    }
    private func snapshot(_ plan: AppInitialTrialPlan) throws -> WorkUpdateSnapshot {
        let binaries = try readAppBinaries(bundle: plan.bundlePath, files: files)
        let resources = plan.bundlePath + "/Contents/Resources/app.asar"
        guard files.canonicalPath(resources) == resources,
              let digest = files.digest(resources), WorkDailyState.validHash(digest) else { throw Failure.identityMismatch }
        return WorkUpdateSnapshot(app: binaries.app, cli: binaries.server, resourcesSHA256: digest,
            appSignature: files.signature(plan.bundlePath),
            cliSignature: files.signature(plan.bundlePath + "/Contents/Resources/codex-cli/CodexCLI.app"))
    }
    func inspect() -> WorkUpdateReport {
        let expected = AppInitialTrialPlan.workSetup(requestedAt: now())
        let resources = WorkAppPins.current.resourcesSHA256
        func report(_ status: WorkUpdateStatus, _ observed: WorkUpdateSnapshot?, _ differences: [WorkUpdateDifference], _ reason: String) -> WorkUpdateReport {
            WorkUpdateReport(checkedAt: now(), status: status, expected: expected,
                expectedResourcesSHA256: resources, observed: observed, differences: differences, reason: reason,
                nextSteps: status == .pinned ? ["업무 런처에서 기존 승인과 종료 관측 상태를 확인하세요."] : [
                    "업무 런처를 열어 자동 대응을 시작하거나 python3 scripts/update-work.py로 후보를 만드세요.",
                    "후보 검사가 통과하면 교체(백업·영수증) 뒤 런처에서 새 수용 구간을 시작하세요. 이 보고는 실행 승인이 아닙니다.",
                    "수동 검토는 update-plan work --json의 항목으로 REVIEW.json을 작성하세요(docs/UPDATES.md)."
                ])
        }
        var first: WorkUpdateSnapshot?
        do {
            let before = try snapshot(expected)
            first = before
            try verifySignatures(expected.bundlePath)
            let after = try snapshot(expected)
            guard before == after else { return report(.unverified, nil, [], "changed-during-inspection") }
            guard [after.appSignature, after.cliSignature].allSatisfy({
                $0.state == "valid-openai" && $0.team == "2DC432GLL2" && !($0.cdhash?.isEmpty ?? true)
            }) else { return report(.unverified, after, [], "signature-unverified") }
            var differences: [WorkUpdateDifference] = []
            func compare(_ field: String, _ expected: String, _ observed: String) {
                if expected != observed { differences.append(WorkUpdateDifference(field: field, expected: expected, observed: observed)) }
            }
            compare("app.path", expected.executablePath, after.app.path)
            compare("app.version", expected.appVersion, after.app.version)
            compare("app.build", expected.appBuild, after.app.build)
            compare("app.sha256", expected.appFingerprint, after.app.fingerprint)
            compare("cli.path", expected.cliExecutablePath, after.cli.path)
            compare("cli.version", expected.cliVersion, after.cli.version)
            compare("cli.build", expected.cliBuild, after.cli.build)
            compare("cli.sha256", expected.cliFingerprint, after.cli.fingerprint)
            compare("resources.sha256", resources, after.resourcesSHA256)
            return report(differences.isEmpty ? .pinned : .reviewRequired, after, differences,
                          differences.isEmpty ? "exact-pins-match" : "identity-changed")
        } catch {
            return report(.unverified, first, [], "metadata-or-signature-unverified")
        }
    }
}

// Template for a manual REVIEW.json (scripts/install-work-update-approved.py). Not an approval.
struct WorkUpdateReviewPlan: Encodable {
    struct ReviewItem: Encodable {
        let id: String
        let requirement: String
        let result = "not-reviewed"
    }
    let schemaVersion = 1
    let report: WorkUpdateReport
    let launchPermitted = false
    let recordReplacementPermitted = false
    let checks: [ReviewItem]
    init(report: WorkUpdateReport) {
        self.report = report
        checks = [
            ReviewItem(id: "baseline", requirement: "현재 구간의 수용 기록과 미해결 실행·거부 보고 없음"),
            ReviewItem(id: "release-evidence", requirement: "대상 버전의 공식 변경 근거와 확인일"),
            ReviewItem(id: "identity", requirement: "report.observed의 앱·CLI·리소스 해시와 서명; 바뀌면 새 후보 필요"),
            ReviewItem(id: "storage-auth-ipc", requirement: "저장 구조·인증·IPC 변경과 업무/개인 프로필 영향"),
            ReviewItem(id: "preservation-recovery", requirement: "백업·영수증 보존과 전환 전 복원 방법"),
            ReviewItem(id: "trial-consent", requirement: "교체 뒤 새 구간 확인(직전 일상 허용이 있으면 확인 1회로 허용 재발급, 없으면 수용 시험 두 번과 별도 일상 허용)에 대한 동의")
        ]
    }
}
