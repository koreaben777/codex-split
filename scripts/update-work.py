#!/usr/bin/env python3
"""Automatically inspect, stage and test an app update without touching live profiles.

An unknown upstream release stops at compatibility review. Passing synthetic tests
is never represented as successful live account/storage/IPC acceptance.
"""
from pathlib import Path
import argparse
import fcntl
import hashlib
import importlib.util
import signal
import stat
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import uuid

BASE = Path(__file__).resolve().parent.parent
HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)  # account database, not $HOME
WORK_ROOT = HOME / 'Library/Application Support/CodexSplit/profiles/work'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    # New private run directories only; journal replacement is atomic.
    temporary = path.with_name(path.name + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def inspect(base):
    executable = base / '.build/codex-split'
    require(executable.is_file() and not executable.is_symlink(), '먼저 sh scripts/build.sh를 실행하세요.')
    result = subprocess.run([str(executable), 'update-check', 'work', '--json'],
                            capture_output=True, timeout=180, check=False)
    require(result.returncode in (0, 2), '업데이트 검사 실행 실패')
    report = json.loads(result.stdout)
    require(isinstance(report, dict) and report.get('schemaVersion') == 1 and report.get('launchPermitted') is False
            and report.get('approvalChanged') is False, '알 수 없는 검사 형식')
    require((result.returncode == 0) == (report.get('status') == 'pinned'), '검사 종료 코드 불일치')
    return report


def target(plan):
    return {key: value for key, value in plan.items() if key not in ('requestID', 'requestedAt')}


def validate_candidate(report, version_edge=True):
    require(report.get('status') == 'review-required', '검증된 변경 후보가 아님')
    observed = report['observed']
    expected = report['expected']
    for name, path_field in [('app', 'executablePath'), ('cli', 'cliExecutablePath')]:
        binary = observed[name]
        require(binary['path'] == expected[path_field], '앱/CLI 경로 변경은 별도 구현 검토 필요')
        for field in ('version', 'build'):
            require(re.fullmatch(r'[A-Za-z0-9._+-]{1,100}', binary[field]) is not None, '지원하지 않는 버전 메타데이터')
        require(re.fullmatch(r'[a-f0-9]{64}', binary['fingerprint']) is not None, '유효하지 않은 해시')
        signature = observed[name + 'Signature']
        require(signature['state'] == 'valid-openai' and signature['team'] == '2DC432GLL2'
                and signature.get('cdhash'), '서명 미확인')
    require(re.fullmatch(r'[a-f0-9]{64}', observed['resourcesSHA256']) is not None, '리소스 해시 미확인')
    # The launcher's target is the app/CLI identity; an app.asar-only change cannot form a version edge.
    require(not version_edge or any(observed[name][field] != expected[prefix + suffix] for name, prefix in (('app', 'app'), ('cli', 'cli'))
                for field, suffix in (('version', 'Version'), ('build', 'Build'), ('fingerprint', 'Fingerprint'))),
            '리소스 단독 변경은 별도 구현 검토 필요')


def snapshot_source(base, destination):
    destination.mkdir(mode=0o700)
    manifest = {}
    # Explicit allowlist: no Git metadata, operational data, credentials or caches.
    # Assets holds only the optional local launcher icon, carried so a replacement keeps it.
    for directory in ('Sources', 'Tests', 'scripts', 'Assets'):
        root = base / directory
        if directory == 'Assets' and not root.exists():
            continue
        require(root.is_dir() and not root.is_symlink(), '소스 디렉터리 확인 실패')
        for source in sorted(root.rglob('*')):
            require(not source.is_symlink(), '소스 symlink는 허용하지 않음')
            relative = source.relative_to(base)
            target = destination / relative
            if source.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                require(source.is_file(), '일반 파일이 아닌 소스')
                before = digest(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                require(digest(source) == before == digest(target), '복사 중 소스 변경')
                manifest[str(relative)] = before
    return manifest


BEGIN = '    // BEGIN update-work managed pins\n'
END = '    // END update-work managed pins\n'
PIN_LITERAL = re.compile(r'Self\(appVersion: "[A-Za-z0-9._+-]{1,100}", appBuild: "[A-Za-z0-9._+-]{1,100}", '
                         r'appFingerprint: "[a-f0-9]{64}", cliVersion: "[A-Za-z0-9._+-]{1,100}", cliBuild: "[A-Za-z0-9._+-]{1,100}", '
                         r'cliFingerprint: "[a-f0-9]{64}", resourcesSHA256: "[a-f0-9]{64}"\)')


def read_pins(trial):
    text = trial.read_text()
    require(text.count(BEGIN) == 1 and text.count(END) == 1, '관리 pin 블록 없음')
    start, end = text.index(BEGIN) + len(BEGIN), text.index(END)
    lines = text[start:end].split('\n')[:-1]
    require(len(lines) >= 4 and lines[0].startswith('    static let current: Self = ')
            and lines[1] == '    static let history: [Self] = [' and lines[-2] == '    ]'
            and lines[-1].startswith('    static let updateReviewID: String? = '), '관리 pin 블록 형식 불일치')
    current = lines[0][len('    static let current: Self = '):]
    history = []
    for line in lines[2:-2]:
        require(line.startswith('        ') and line.endswith(','), '관리 pin 이력 형식 불일치')
        history.append(line[8:-1])
    for literal in [current] + history:
        require(PIN_LITERAL.fullmatch(literal) is not None, '관리 pin 값 형식 불일치')
    return text, start, end, current, history


def target_literal(observed):
    literal = ('Self(appVersion: "{}", appBuild: "{}", appFingerprint: "{}", cliVersion: "{}", cliBuild: "{}", '
               'cliFingerprint: "{}", resourcesSHA256: "{}")').format(
        observed['app']['version'], observed['app']['build'], observed['app']['fingerprint'],
        observed['cli']['version'], observed['cli']['build'], observed['cli']['fingerprint'], observed['resourcesSHA256'])
    require(PIN_LITERAL.fullmatch(literal) is not None, '새 target 형식 불일치')
    return literal


def write_pins(trial, text, start, end, current, history, review_id):
    block = ['    static let current: Self = ' + current, '    static let history: [Self] = [']
    block += ['        ' + literal + ',' for literal in history]
    block += ['    ]', '    static let updateReviewID: String? = ' + ('"' + review_id + '"' if review_id else 'nil')]
    trial.write_text(text[:start] + '\n'.join(block) + '\n' + text[end:])


def stage_pins(source, report, review_id):
    """Change only the isolated candidate, never the checkout or installed launcher.

    The previous target moves into history so preserved records stay readable; the new
    target becomes the only launchable one, joined by exactly one reviewed edge."""
    require(re.fullmatch(r'work-update-[0-9a-f]{32}', review_id) is not None, '검토 ID 형식 불일치')
    trial = source / 'Sources/AppTrial.swift'
    text, start, end, current, history = read_pins(trial)
    target = target_literal(report['observed'])
    require(target not in [current] + history, '새 target 중복')
    write_pins(trial, text, start, end, target, [current] + history, review_id)


def pin_installed(base, inspector=None, probe=None, work_root=WORK_ROOT):
    """First-time setup only: pin this checkout to the installed, signature-verified official
    app. With a work profile present, versions change only through the update path."""
    require(not work_root.exists(), '업무 프로필이 이미 있습니다. 버전 변경은 update-work.py 업데이트 경로를 사용하세요.')
    report = (inspector or inspect)(base)
    if report['status'] == 'pinned':
        return 'unchanged'
    validate_candidate(report, version_edge=False)
    isolation = (probe or isolation_markers)(report['expected']['bundlePath'])
    require(not any(value['missing'] for value in isolation.values()), '업무 저장소 분리 표식 누락: 이 버전은 지원하지 않음')
    trial = base / 'Sources/AppTrial.swift'
    text, start, end, _, _ = read_pins(trial)
    write_pins(trial, text, start, end, target_literal(report['observed']), [], None)
    return 'pinned'


def run_checks(source, log):
    # Reuse the test supervisor: timeout/interruption never force-kills a client
    # which may still own a synthetic server. Keep ownership until it exits.
    spec = importlib.util.spec_from_file_location('update_harness', BASE / 'Tests/harness_ownership.py')
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    interruption = harness.Interruption()
    previous = {sig: signal.signal(sig, interruption.receive) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        with log.open('xb') as stream:
            if interruption.requested:
                return False
            def report(event):
                stream.write((event + '\n').encode())
                stream.flush()
            # A copied candidate must prove that its observer is denied by the
            # unchanged operational path pin; it cannot impersonate the live tool.
            # The candidate launcher records the operational checkout, not the run directory.
            environment = dict(os.environ, CODEXSPLIT_SOURCE_ROOT=str(BASE))
            with harness.OwnedClient(subprocess.Popen(['/bin/sh', 'scripts/check.sh'], cwd=source, env=environment,
                    stdout=stream, stderr=subprocess.STDOUT), interruption, report) as owned:
                owned.finish(1800)
                return not owned.failed and owned.child.returncode == 0
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


# The work launcher separates storage only through these names (AppTrialStore launch configuration).
# Necessary, not sufficient: their presence is checked statically; real separation is the acceptance visits.
ISOLATION_MARKERS = {
    'Contents/Resources/app.asar': (b'CODEX_ELECTRON_USER_DATA_PATH', b'CODEX_HOME', b'CODEX_SQLITE_HOME', b'user-data-dir'),
    'Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex': (b'CODEX_HOME', b'CODEX_SQLITE_HOME'),
}


def isolation_markers(bundle):
    result = {}
    for relative, markers in ISOLATION_MARKERS.items():
        path = Path(bundle) / relative
        require(path.resolve() == path and path.is_file(), '분리 표식 검사 대상 없음')
        missing, tail = set(markers), b''
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(8 << 20), b''):
                data = tail + block
                missing = {marker for marker in missing if marker not in data}
                tail = data[-64:]
                if not missing:
                    break
        result[relative] = {'required': sorted(m.decode() for m in markers), 'missing': sorted(m.decode() for m in missing)}
    return result


def notify(message):
    # Best effort; the RESULT.json phase is the record.
    subprocess.run(['/usr/bin/osascript', '-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title "CodexSplit 업무용"',
                    '-e', 'end run', message], capture_output=True, timeout=30, check=False)


def show_progress(run):
    # Read-only window over this run (RESULT.json, checks.log); closing it never affects the run. Best effort.
    viewer = BASE / '.build/codex-split-update-progress'
    if viewer.is_file():
        subprocess.Popen([str(viewer), str(run)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)


def automatic_review(state, report, isolation, consented_at, to_manifest_sha):
    observed = report['observed']
    identity = 'app {} / {} sha256 {}; cli {} / {} sha256 {}; app.asar sha256 {}; OpenAI 2DC432GLL2 strict 서명'.format(
        observed['app']['version'], observed['app']['build'], observed['app']['fingerprint'], observed['cli']['version'],
        observed['cli']['build'], observed['cli']['fingerprint'], observed['resourcesSHA256'])
    markers = '; '.join(relative + ': ' + ', '.join(value['required']) for relative, value in sorted(isolation.items()))
    items = {
        'baseline': '배치 직전 미해결 업무 실행·거부 보고·미해결 설정 없음을 다시 확인. 이전 성공은 승계하지 않음. 직전 일상 허용이 있으면 새 구간 확인 1회 뒤 허용 재발급.',
        'release-evidence': '자동 대응: 공식 변경 내역은 사람이 검토하지 않음. 서명된 공식 설치본의 identity만 확인.',
        'identity': identity + ' (후보 시험 전후 동일). 후보 전체 검사(scripts/check.sh) 통과.',
        'storage-auth-ipc': '정적 분리 표식 확인 - ' + markers + '. 실제 저장·인증 분리는 새 구간의 사용자 확인으로 확인.',
        'preservation-recovery': '기존 교체 절차의 백업·영수증 보존, 새 구간 전환 전 --restore-backup 수동 복원. 자동 롤백 없음.',
        'trial-consent': '자동 대응 동의 {}. 새 구간 시작과 확인 방문은 별도 GUI 동의(직전 일상 허용이 있으면 한 번에).'.format(consented_at),
    }
    return {'schemaVersion': 1, 'mode': 'automatic', 'reviewID': state['reviewID'], 'candidateManifestSHA256': to_manifest_sha,
            'items': {name: {'result': 'automatic', 'evidence': text} for name, text in items.items()}}


def wait_idle(idle, sleep, seconds=600):
    # The launcher quits right after starting automation; wait for a re-opened one instead of racing it.
    for _ in range(seconds // 10):
        try:
            idle()
            return
        except RuntimeError:
            sleep(10)
    idle()


def pipeline(base, run, inspector=inspect, checks=run_checks, probe=isolation_markers):
    state = {'schemaVersion': 1, 'phase': 'inspecting', 'liveTransitionPerformed': False,
             'profileModified': False, 'launchPermitted': False}
    result_path = run / 'RESULT.json'
    write_json(result_path, state)
    try:
        report = inspector(base)
        write_json(run / 'inspection.json', report)
        if report['status'] == 'pinned':
            state['phase'] = 'unchanged'
        elif report['status'] != 'review-required':
            state['phase'] = 'blocked-unverified'
        else:
            validate_candidate(report)
            isolation = probe(report['expected']['bundlePath'])
            write_json(run / 'isolation.json', isolation)
            if any(value['missing'] for value in isolation.values()):
                state['phase'] = 'blocked-incompatible'
                write_json(result_path, state)
                return state
            source = run / 'candidate'
            manifest = snapshot_source(base, source)
            write_json(run / 'source-manifest.json', manifest)
            state['reviewID'] = 'work-update-' + uuid.uuid4().hex
            stage_pins(source, report, state['reviewID'])
            state['phase'] = 'testing'
            state['checks'] = 'scripts/check.sh'
            write_json(result_path, state)
            if not checks(source, run / 'checks.log'):
                state['phase'] = 'blocked-tests'
            else:
                final = inspector(base)
                write_json(run / 'final-inspection.json', final)
                require(final['status'] == report['status'] and final.get('observed') == report['observed']
                        and target(final['expected']) == target(report['expected']), '검증 중 앱 또는 기준 변경')
                state['phase'] = 'awaiting-compatibility-review'
                state['candidateLauncher'] = str(source / '.build/CodexSplit-work-standalone.app')
                state['remaining'] = [
                    '호환성 검토 기록 작성: 공식 변경 근거, 저장/인증/IPC 영향, 보존·복구 계획 (REVIEW.json)',
                    '설치 승인 후 scripts/install-work-update-approved.py로 백업·검증 교체',
                    '새 런처에서 새 구간 시작 동의 후 실제 계정/프로젝트 확인: 직전 일상 허용이 있으면 1회로 허용 재발급, 없으면 수용 2회와 별도 일상 사용 허용'
                ]
        write_json(result_path, state)
        return state
    except Exception as error:
        state['phase'] = 'blocked-error'
        state['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError):
            state['errorMessage'] = str(error)
        write_json(result_path, state)
        raise


INSTALLED_LAUNCHER = HOME / 'Applications/CodexSplit-work.app/Contents/MacOS/launcher'


def deployed_source(base, runs, installed=INSTALLED_LAUNCHER):
    """Stage from the candidate that built the installed launcher, so each candidate's pin history
    continues from the deployed one; otherwise the checkout itself. Installation re-checks continuity."""
    if not installed.is_file():
        return base
    launcher = digest(installed)
    matches = []
    for run in sorted(runs.iterdir()) if runs.is_dir() else []:
        result, built = run / 'RESULT.json', run / 'candidate/.build/CodexSplit-work-standalone.app/Contents/MacOS/launcher'
        if result.is_file() and built.is_file() and json.loads(result.read_text()).get('phase') == 'installed' and digest(built) == launcher:
            matches.append(run / 'candidate')
    require(len(matches) <= 1, '설치 런처와 일치하는 후보가 여럿')
    return matches[0] if matches else base


def load_installer(base):
    spec = importlib.util.spec_from_file_location('update_install', base / 'scripts/install-work-update-approved.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def automatic(base, run, consented_at, now=None, pipeline_run=pipeline, installer=None, sleep=None, alert=notify):
    """Launcher-consented response: candidate, checks, then a backed-up replacement. Never a new segment."""
    import time
    require(0 <= (now or time.time)() - consented_at < 120, '자동 대응 동의 만료')
    # The installer always comes from the operational checkout: candidates live in its .build/work-updates.
    installer, sleep = installer or load_installer(BASE), sleep or time.sleep
    alert('업무 런처 업데이트 대응을 시작했습니다. 검사·빌드에 10분 안팎이 걸립니다.')
    try:
        state = pipeline_run(base, run)
    except Exception:
        alert('업무 런처 업데이트 대응이 중단됐습니다. 업무 기록과 기존 런처는 그대로입니다.')
        raise
    if state['phase'] != 'awaiting-compatibility-review':
        alert('업무 런처 업데이트 대응 중단: ' + state['phase'] + '. 업무 기록과 기존 런처는 그대로입니다.')
        return state
    try:
        candidate = run / 'candidate'
        digest_of = lambda bundle: installer.replacement.manifest_digest(installer.replacement.manifest(bundle))
        to_sha = digest_of(candidate / '.build/CodexSplit-work-standalone.app')
        write_json(run / 'REVIEW.json', automatic_review(state, json.loads((run / 'final-inspection.json').read_text()),
                                                         json.loads((run / 'isolation.json').read_text()), consented_at, to_sha))
        for attempt in range(3):  # a launcher re-opened mid-install only delays the replacement
            wait_idle(installer.launcher_idle, sleep)
            try:
                installed = installer.deploy(candidate, run / 'REVIEW.json', digest_of(installer.DESTINATION), to_sha, True)
                break
            except RuntimeError as error:
                if attempt == 2 or '런처 실행 중' not in str(error):
                    raise
        state.update(phase='installed', receipt=installed['receipt'], backup=installed['backup'])
        write_json(run / 'RESULT.json', state)
        alert('업무 런처를 새 버전용으로 교체했습니다. 런처를 열어 새 구간을 시작하세요.')
    except Exception as error:
        state['phase'] = 'blocked-install'
        state['errorType'] = type(error).__name__
        if isinstance(error, RuntimeError):
            state['errorMessage'] = str(error)
        write_json(run / 'RESULT.json', state)
        alert('업무 런처 교체를 하지 않았습니다(' + state.get('errorMessage', state['errorType']) + '). 기존 런처와 업무 기록은 그대로입니다.')
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--auto', action='store_true', help='런처 동의로 시작: 후보 검증 후 백업 교체까지')
    parser.add_argument('--consented-at', type=float)
    parser.add_argument('--pin-installed', action='store_true', help='처음 설정 전에만: 설치된 공식 앱 버전을 이 소스에 고정')
    options = parser.parse_args()
    require(options.auto == (options.consented_at is not None), '--auto와 --consented-at은 함께 사용')
    os.umask(0o077)
    if options.pin_installed:
        require(not options.auto, '--pin-installed는 단독으로 사용')
        result = pin_installed(BASE)
        print('결과: ' + result + ('. sh scripts/check.sh로 다시 빌드·검사하세요.' if result == 'pinned' else ''))
        return 0
    root = BASE / '.build'
    require(root.is_dir() and not root.is_symlink(), '먼저 sh scripts/build.sh를 실행하세요.')
    runs = root / 'work-updates'
    runs.mkdir(mode=0o700, exist_ok=True)
    require(runs.resolve() == runs and runs.stat().st_uid == os.getuid()
            and runs.stat().st_mode & 0o077 == 0, '업데이트 기록 디렉터리 권한 불일치')
    fd = os.open(runs / 'update.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o777 == 0o600, '업데이트 lock 형식/권한 불일치')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = runs / uuid.uuid4().hex
        run.mkdir(mode=0o700)
        print('자동 검사·후보 빌드 기록: ' + str(run), flush=True)
        if options.auto:
            show_progress(run)
        source = deployed_source(BASE, runs)
        print('후보 원본 소스: ' + str(source), flush=True)
        state = automatic(source, run, options.consented_at) if options.auto else pipeline(source, run)
        print('결과: ' + state['phase'])
        print('운영 앱·프로필·승인 기록은 보존됩니다. RESULT.json을 확인하세요.')
        return 0 if state['phase'] in ('unchanged', 'installed') else 2
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('업데이트 자동 검증 중단. 기존 앱과 업무 기록을 유지합니다.', file=sys.stderr)
        if '--auto' in sys.argv:  # the launcher promised a notification even for early failures
            notify('업무 런처 업데이트 대응을 시작하지 못했거나 중단됐습니다(' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__)
                   + '). 업무 기록과 기존 런처는 그대로입니다.')
        sys.exit(2)
