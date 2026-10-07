#!/usr/bin/env python3
"""업무 런처 설치·교체. 공식 앱·로그인 데이터·업무 앱 프로세스는 제어하지 않는다.

교체는 launcher_replacement.py의 백업·배타 이동·영수증 절차를 쓴다. 설치는 실행 허가가 아니다.
새 수용 구간은 설치된 런처에서 사용자의 별도 동의로만 시작한다.

  --install-new   (처음 설치: 이 checkout에서 빌드한 런처, 설치 경로가 비어 있을 때만)
  --manifest BUNDLE   (bundle 전체 manifest SHA-256 출력: 아래 인자와 REVIEW.json에 사용)
  --preflight|--install --candidate-root DIR --review REVIEW.json --from-manifest-sha256 X --to-manifest-sha256 Y
  --bind-update --receipt RESULT.json --candidate-root DIR --review REVIEW.json   (교체 후 binding 기록만 재시도)
  --restore-backup --receipt RESULT.json   (새 구간 전환 전, 런처 미실행일 때 이전 런처 복원)
"""
from pathlib import Path
import fcntl, hashlib, importlib.util, json, os, pwd, re, shutil, subprocess, sys, uuid

BASE = Path(__file__).resolve().parent.parent
HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)  # account database, not $HOME
DESTINATION = HOME / 'Applications/CodexSplit-work.app'
CONTROL = HOME / 'Library/Application Support/CodexSplit/profiles/work/control'
ICON = 'Contents/Resources/CodexSplit-work.icns'
REVIEW_ITEMS = ('baseline', 'release-evidence', 'identity', 'storage-auth-ipc', 'preservation-recovery', 'trial-consent')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


replacement = load('launcher_replacement', BASE / 'scripts/launcher_replacement.py')
require, digest = replacement.require, replacement.digest


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, '중복 JSON key')
        result[key] = value
    return result


def candidate(root, base=BASE):
    """The checkout itself (launcher-only) or an update-work.py candidate awaiting review."""
    root = Path(root)
    require(root.resolve() == root and root.is_dir() and not root.is_symlink(), '후보 경로 불일치')
    if root == base:
        return {'root': root, 'reviewID': None}
    run = root.parent
    require(root.name == 'candidate' and run.parent == base / '.build/work-updates'
            and re.fullmatch(r'[0-9a-f]{32}', run.name) is not None, '승인 가능한 후보 위치 아님')
    result = json.loads((run / 'RESULT.json').read_bytes(), object_pairs_hook=unique_object)
    require(result.get('phase') == 'awaiting-compatibility-review' and result.get('liveTransitionPerformed') is False
            and re.fullmatch(r'work-update-[0-9a-f]{32}', result.get('reviewID', '')) is not None
            and result.get('candidateLauncher') == str(root / '.build/CodexSplit-work-standalone.app'), '검토 대기 후보 아님')
    trial = (root / 'Sources/AppTrial.swift').read_text()
    require(trial.count('static let updateReviewID: String? = "' + result['reviewID'] + '"') == 1, '후보 검토 ID 불일치')
    return {'root': root, 'reviewID': result['reviewID']}


def review(path, review_id, to_manifest_sha):
    """Compatibility record. 'reviewed': a person accepted every item. 'automatic': launcher-consented
    response for a signed version update; it says so item by item and never claims a human review."""
    data = Path(path).read_bytes()
    value = json.loads(data, object_pairs_hook=unique_object)
    require(set(value) == {'schemaVersion', 'mode', 'reviewID', 'candidateManifestSHA256', 'items'} and value['schemaVersion'] == 1
            and value['reviewID'] == review_id and value['candidateManifestSHA256'] == to_manifest_sha, '검토 기록 대상 불일치')
    require(value['mode'] == 'reviewed' or (value['mode'] == 'automatic' and review_id is not None), '검토 방식 불일치')
    require(set(value['items']) == set(REVIEW_ITEMS), '검토 항목 누락')
    expected = 'accepted' if value['mode'] == 'reviewed' else 'automatic'
    for item in value['items'].values():
        require(set(item) == {'result', 'evidence'} and item['result'] == expected and isinstance(item['evidence'], str)
                and 0 < len(item['evidence'].strip()) <= 2000, '미승인 또는 근거 없는 검토 항목')
    return data, value['mode']


def official_pinned(root):
    # The candidate's own checker: exact pins plus identifier-specific strict signatures.
    result = subprocess.run([str(root / '.build/codex-split'), 'update-check', 'work', '--json'],
                            capture_output=True, timeout=180, check=False)
    report = json.loads(result.stdout) if result.stdout else {}
    require(result.returncode == 0 and report.get('status') == 'pinned', '공식 앱이 후보 pin과 일치하지 않거나 서명 미확인')


def launcher_idle():
    result = subprocess.run(['/usr/bin/pgrep', '-f', r'CodexSplit-work[^/]*\.app/Contents/MacOS/launcher'], capture_output=True)
    require(result.returncode == 1, '업무 런처 실행 중이거나 확인 불가')


def read_daily(control):
    # Absent until the first launcher visit: no attempts, no segment.
    path = control / 'work-daily.json'
    if not os.path.lexists(path):
        return {}
    replacement.safe(path, private=True)
    return json.loads(path.read_bytes(), object_pairs_hook=unique_object)


def visit_idle(control):
    # Restore needs only this: no launcher process and no unresolved daily visit.
    for name in ('state.json', 'state.lock'):
        replacement.safe(control / name, private=True)
    daily = read_daily(control)
    attempts = daily.get('attempts', [])
    require(not attempts or attempts[-1].get('phase') == 'exitObserved', '미해결 업무 실행 존재')
    return daily


def control_baseline(control):
    daily = visit_idle(control)
    attempts = daily.get('attempts', [])
    saved = json.loads((control / 'state.json').read_bytes(), object_pairs_hook=unique_object)
    require(not saved.get('pending') and not (saved.get('workSetup') or {}).get('pending'), '미해결 설정 기록 존재')
    # The launcher refuses a new segment after a rejected report; do not install into that dead end.
    require(not any(a.get('account') in ('mismatch', 'loginRequired') or a.get('personal') in ('changed', 'unknown')
                    or a.get('projectsConnected') is False for a in attempts), '거부된 계정·개인 앱·프로젝트 보고 존재')
    baseline = {name: digest(control / name) if os.path.lexists(control / name) else None for name in ('state.json', 'work-daily.json')}
    return baseline, daily, saved


PIN_FIELDS = ('appVersion', 'appBuild', 'appFingerprint', 'cliVersion', 'cliBuild', 'cliFingerprint')


def segment(daily):
    """Target and launcher the current work-daily segment is bound to (same rule as WorkDailyState.segment)."""
    attempts = daily.get('attempts') or []
    if attempts:
        return attempts[-1]['plan'], attempts[-1]['toolFingerprint']
    if daily.get('update'):
        return daily['update']['toPlan'], daily['update']['toToolFingerprint']
    return None, None


def continuity(info, daily, saved, installed_launcher):
    """Refuse a replacement the new launcher could not continue from: it must replace the segment's own
    launcher, and a version candidate must start its reviewed edge at the segment's official target.
    Before the first launcher visit nothing is bound yet and the completed setup is the segment."""
    plan, tool = segment(daily)
    if tool is None:
        setup = saved.get('workSetup') or {}
        require(len(setup.get('visits') or []) == 2 and not setup.get('pending'), '업무 설정 미완료: codex-split-work-setup --setup work 먼저')
        plan = setup['plan']
    else:
        require(tool == installed_launcher, '설치된 런처와 업무 기록 구간 불일치: 공식 앱이 그대로면 런처를 열어 현재 구간을 먼저 시작하고, '
                                            '이미 바뀌었으면 --restore-backup으로 구간의 런처를 복원한 뒤 업데이트 대응을 다시 실행하세요')
    if info['reviewID'] is not None:
        expected = json.loads((info['root'].parent / 'inspection.json').read_bytes(), object_pairs_hook=unique_object)['expected']
        require(all(expected[field] == plan[field] for field in PIN_FIELDS), '후보의 검토 edge가 현재 업무 구간 버전에서 시작하지 않음')


def bind(workspace, review_id, mode, launcher_sha, to_manifest_sha, review_bytes):
    # Read by the launcher before it offers a new acceptance segment; exclusive, private files.
    # UPDATE.json is written last: without it the launcher offers nothing.
    update = json.dumps({'schemaVersion': 1, 'reviewID': review_id, 'mode': mode, 'launcherSHA256': launcher_sha, 'toManifestSHA256': to_manifest_sha,
                         'reviewSHA256': hashlib.sha256(review_bytes).hexdigest()}, indent=2) + '\n'
    files = [] if (workspace / 'REVIEW.json').exists() else [('REVIEW.json', review_bytes)]
    for name, data in files + [('UPDATE.json', update.encode())]:
        fd = os.open(workspace / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as out:
            out.write(data); out.flush(); os.fsync(out.fileno())
    replacement.sync_directory(workspace)


def deploy(source_root, review_path, from_sha, to_sha, install, destination=DESTINATION, control=CONTROL,
           verify_signature=replacement.signed, check_idle=launcher_idle, official=official_pinned, base=BASE):
    info = candidate(source_root, base)
    bundle = info['root'] / '.build/CodexSplit-work-standalone.app'
    review_bytes, mode = review(review_path, info['reviewID'], to_sha)
    old, new = replacement.manifest(destination), replacement.manifest(bundle)
    require(replacement.manifest_digest(old) == from_sha and replacement.manifest_digest(new) == to_sha, '승인 전체 manifest 변경')
    require(old['Contents/MacOS/launcher'][0] != new['Contents/MacOS/launcher'][0], '같은 런처는 교체 대상 아님')
    require(ICON not in old or old[ICON] == new.get(ICON), '설치본의 아이콘이 후보에 없거나 다름: Assets/WorkIcon 확인')
    # Before taking the lock: a running launcher's observation must never meet a busy lock.
    check_idle()
    _, daily, saved = control_baseline(control)
    continuity(info, daily, saved, old['Contents/MacOS/launcher'][0])
    lock = os.open(control / 'state.lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        baseline, daily, saved = control_baseline(control)
        continuity(info, daily, saved, old['Contents/MacOS/launcher'][0])
        def preflight():
            require(control_baseline(control)[0] == baseline, '제어 기록 변경')
            official(info['root'])
        check_idle(); preflight(); verify_signature(destination); verify_signature(bundle)
        if not install:
            return {'phase': 'preflight', 'reviewID': info['reviewID']}
        record = replacement.replace(bundle, destination, old, new, from_sha, to_sha, verify_signature, check_idle, preflight)
        workspace = Path(record['backup']).parent
        bind(workspace, info['reviewID'], mode, new['Contents/MacOS/launcher'][0], to_sha, review_bytes)
        return {'phase': 'installed', 'receipt': str(workspace / 'RESULT.json'), 'backup': record['backup'], 'reviewID': info['reviewID']}
    finally:
        os.close(lock)


def rebind(receipt, source_root, review_path, destination=DESTINATION, verify_signature=replacement.signed, base=BASE):
    receipt = Path(receipt)
    record = json.loads(receipt.read_bytes(), object_pairs_hook=unique_object)
    info = candidate(source_root, base)
    proof = replacement.verify_receipt(receipt, destination, record['fromManifestSHA256'], record['toManifestSHA256'], verify_signature)
    require(proof['newManifest'] == replacement.manifest(info['root'] / '.build/CodexSplit-work-standalone.app'), '영수증과 후보 불일치')
    require(not (receipt.parent / 'UPDATE.json').exists(), 'binding 이미 존재')
    review_bytes, mode = review(review_path, info['reviewID'], proof['toManifestSHA256'])
    if (receipt.parent / 'REVIEW.json').exists():  # an interrupted bind leaves only the identical review copy
        require((receipt.parent / 'REVIEW.json').read_bytes() == review_bytes, '기존 검토 사본 불일치')
    bind(receipt.parent, info['reviewID'], mode, proof['newManifest']['Contents/MacOS/launcher'][0], proof['toManifestSHA256'], review_bytes)


def restore(receipt, destination=DESTINATION, control=CONTROL, verify_signature=replacement.signed, check_idle=launcher_idle):
    """Manual, explicit rollback of the launcher bundle only. Never touches records or the official app."""
    receipt = Path(receipt)
    record = json.loads(receipt.read_bytes(), object_pairs_hook=unique_object)
    workspace = receipt.parent
    require(not (workspace / 'RESTORE.json').exists(), '이미 복원 기록 존재')
    check_idle(); visit_idle(control)
    lock = os.open(control / 'state.lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        daily = visit_idle(control)
        proof = replacement.verify_receipt(receipt, destination, record['fromManifestSHA256'], record['toManifestSHA256'], verify_signature)
        # After the new segment exists, the previous launcher cannot read it; restoring would only block.
        require((daily.get('update') or {}).get('replacement', {}).get('receiptPath') != str(receipt), '새 구간 전환 후: 복원 대신 상태 확인 필요')
        check_idle()
        aside, backup = workspace / 'restored-from.app', workspace / 'previous.app'
        # Journal first: an interruption between the two moves is visible and recoverable by hand.
        replacement.journal(workspace / 'RESTORE.json', {'phase': 'restoring', 'restoredFrom': str(aside), 'destination': str(destination)})
        replacement.rename_exclusive(destination, aside); replacement.sync_directory(destination.parent); replacement.sync_directory(workspace)
        replacement.rename_exclusive(backup, destination); replacement.sync_directory(destination.parent); replacement.sync_directory(workspace)
        require(replacement.manifest(destination) == proof['oldManifest'] and replacement.manifest(aside) == proof['newManifest'], '복원 후 산출물 불일치')
        verify_signature(destination)
        replacement.journal(workspace / 'RESTORE.json', {'phase': 'restored', 'restoredFrom': str(aside), 'destination': str(destination)})
    finally:
        os.close(lock)


def install_new(source_root=BASE, destination=DESTINATION, verify_signature=replacement.signed, base=BASE):
    """First installation only: the launcher built in this checkout, into an absent destination."""
    info = candidate(source_root, base)
    require(info['reviewID'] is None, '처음 설치는 이 checkout의 빌드만 사용')
    require(not os.path.lexists(destination), '설치 경로가 이미 있음: 교체는 --install을 사용')
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    bundle = info['root'] / '.build/CodexSplit-work-standalone.app'
    new = replacement.manifest(bundle)
    verify_signature(bundle)
    staged = destination.parent / ('.CodexSplit-work-install-' + uuid.uuid4().hex)
    shutil.copytree(bundle, staged, copy_function=shutil.copy2)
    require(replacement.manifest(staged) == new, '복사 불일치')
    replacement.sync_bundle(staged)
    replacement.rename_exclusive(staged, destination)
    replacement.sync_directory(destination.parent)
    require(replacement.manifest(destination) == new, '설치 후 산출물 불일치')
    verify_signature(destination)
    return destination


def main(args):
    if args[:1] == ['--manifest']:  # values for --from/--to-manifest-sha256 and REVIEW.json
        require(len(args) == 2, '잘못된 인자')
        print(replacement.manifest_digest(replacement.manifest(Path(args[1]).resolve()))); return
    if args == ['--install-new']:
        print('설치 완료: ' + str(install_new()) + '; 앱 실행 없음. 업무 설정 뒤 런처를 열어 수용 시험을 시작하세요.'); return
    if args[:1] == ['--restore-backup']:
        require(len(args) == 3 and args[1] == '--receipt', '잘못된 인자')
        restore(args[2]); print('이전 런처 복원 완료; 업무 기록·공식 앱 변경 없음; 앱 실행 없음.'); return
    if args[:1] == ['--bind-update']:
        require(len(args) == 7 and args[1] == '--receipt' and args[3] == '--candidate-root' and args[5] == '--review', '잘못된 인자')
        rebind(args[2], args[4], args[6]); print('업데이트 binding 기록 완료; 앱 실행·구간 전환 없음.'); return
    require(len(args) == 9 and args[0] in ('--preflight', '--install') and args[1] == '--candidate-root' and args[3] == '--review'
            and args[5] == '--from-manifest-sha256' and args[7] == '--to-manifest-sha256', '잘못된 인자')
    result = deploy(args[2], args[4], args[6], args[8], args[0] == '--install')
    if result['phase'] == 'preflight':
        print('사전 확인 통과; 설치·전환·실행 없음.')
    else:
        print('교체·binding 완료; 백업=' + result['backup'] + '; 영수증=' + result['receipt']
              + '; 새 수용 구간은 런처에서 사용자가 별도로 동의해야 시작됩니다.')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except Exception as error:
        print('중단: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__)
              + '; 백업·영수증·업무 기록 보존; 자동 복원·재실행 없음.', file=sys.stderr)
        sys.exit(2)
