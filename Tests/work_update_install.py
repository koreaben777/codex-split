"""Update deployment on fixture directories only: no installed launcher, official app or work profile."""
import hashlib, importlib.util, json, os, stat, tempfile, unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/install-work-update-approved.py'
spec = importlib.util.spec_from_file_location('install_update', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
PLAN = {'appVersion': '1.0', 'appBuild': '1', 'appFingerprint': '0' * 64, 'cliVersion': '2.0', 'cliBuild': '2', 'cliFingerprint': 'a' * 64}
OLD_TOOL = hashlib.sha256(b'old').hexdigest()
ITEMS = ('baseline', 'release-evidence', 'identity', 'storage-auth-ipc', 'preservation-recovery', 'trial-consent')


def private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as out: out.write(data)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        self.base = root / 'repo'
        self.bundle = self.base / '.build/CodexSplit-work-standalone.app'
        apps = root / 'Applications'; apps.mkdir(mode=0o700)
        self.destination = apps / 'CodexSplit-work.app'
        for bundle, text in [(self.bundle, 'new'), (self.destination, 'old')]:
            (bundle / 'Contents/MacOS').mkdir(parents=True); (bundle / 'Contents/MacOS/launcher').write_text(text)
        self.control = root / 'control'; self.control.mkdir(mode=0o700)
        private(self.control / 'state.lock', b'')
        private(self.control / 'state.json', b'{"setup":"preserved"}')
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved', 'plan': PLAN, 'toolFingerprint': OLD_TOOL}]})
        self.old, self.new = m.replacement.manifest(self.destination), m.replacement.manifest(self.bundle)
        self.from_sha, self.to_sha = m.replacement.manifest_digest(self.old), m.replacement.manifest_digest(self.new)
        self.review_path = root / 'REVIEW.json'
        self.review()
        self.official_calls = 0

    def daily(self, value):
        path = self.control / 'work-daily.json'
        if path.exists(): path.unlink()
        private(path, json.dumps(value).encode())

    def review(self, review_id=None, manifest=None, items=None, mode='reviewed'):
        value = {'schemaVersion': 1, 'mode': mode, 'reviewID': review_id, 'candidateManifestSHA256': manifest or self.to_sha,
                 'items': items or {name: {'result': 'accepted' if mode == 'reviewed' else 'automatic', 'evidence': name + ' 근거'} for name in ITEMS}}
        self.review_path.write_text(json.dumps(value))

    def official(self, root):
        self.official_calls += 1

    def deploy(self, install=True, root=None, **kw):
        args = dict(destination=self.destination, control=self.control, verify_signature=lambda p: None,
                    check_idle=lambda: None, official=self.official, base=self.base)
        args.update(kw)
        return m.deploy(root or self.base, self.review_path, self.from_sha, self.to_sha, install, **args)

    def assert_untouched(self):
        self.assertEqual(m.replacement.manifest(self.destination), self.old)
        self.assertEqual(list(self.destination.parent.glob('.CodexSplit-work-replacement-*')), [])

    def test_preflight_changes_nothing(self):
        self.assertEqual(self.deploy(install=False)['phase'], 'preflight')
        self.assert_untouched()
        self.assertGreater(self.official_calls, 0)

    def test_launcher_only_install_backs_up_and_binds(self):
        result = self.deploy()
        workspace = Path(result['receipt']).parent
        self.assertEqual(m.replacement.manifest(self.destination), self.new)
        self.assertEqual(m.replacement.manifest(Path(result['backup'])), self.old)
        binding = json.loads((workspace / 'UPDATE.json').read_text())
        self.assertEqual(binding, {'schemaVersion': 1, 'reviewID': None, 'mode': 'reviewed', 'toManifestSHA256': self.to_sha,
                                   'launcherSHA256': hashlib.sha256(b'new').hexdigest(),
                                   'reviewSHA256': hashlib.sha256(self.review_path.read_bytes()).hexdigest()})
        self.assertEqual((workspace / 'REVIEW.json').read_bytes(), self.review_path.read_bytes())
        for name in ('RESULT.json', 'UPDATE.json', 'REVIEW.json'):
            self.assertEqual(stat.S_IMODE((workspace / name).stat().st_mode), 0o600)
        self.assertEqual((self.control / 'state.json').read_bytes(), b'{"setup":"preserved"}')
        with self.assertRaises(RuntimeError):  # a binding is written exactly once
            m.rebind(result['receipt'], self.base, self.review_path, destination=self.destination,
                     verify_signature=lambda p: None, base=self.base)

    def test_incomplete_review_blocks(self):
        for items in ({name: {'result': 'not-reviewed', 'evidence': 'x'} for name in ITEMS},
                      {name: {'result': 'accepted', 'evidence': ' '} for name in ITEMS},
                      {name: {'result': 'accepted', 'evidence': 'x'} for name in ITEMS[:-1]}):
            self.review(items=items)
            with self.assertRaises(RuntimeError): self.deploy()
        self.review(manifest='0' * 64)
        with self.assertRaises(RuntimeError): self.deploy()
        self.review(review_id='work-update-' + '1' * 32)
        with self.assertRaises(RuntimeError): self.deploy()
        self.assert_untouched()

    def test_pending_daily_or_running_launcher_blocks(self):
        self.daily({'schemaVersion': 3, 'attempts': [{'phase': 'active'}]})
        with self.assertRaises(RuntimeError): self.deploy()
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitUnobserved'}]})
        m.visit_idle(self.control)  # closed on kernel proof: not a running visit
        self.daily({'schemaVersion': 3, 'attempts': []})
        def busy(): raise RuntimeError('런처 실행 중')
        with self.assertRaises(RuntimeError): self.deploy(check_idle=busy)
        self.assert_untouched()

    def test_official_mismatch_blocks(self):
        def mismatch(root): raise RuntimeError('pin 불일치')
        with self.assertRaises(RuntimeError): self.deploy(official=mismatch)
        self.assert_untouched()

    def test_official_update_mid_replacement_preserves_old_launcher(self):
        def late(root):
            self.official_calls += 1
            if self.official_calls == 3: raise RuntimeError('검사 중 업데이트')
        with self.assertRaises(RuntimeError): self.deploy(official=late)
        self.assertEqual(m.replacement.manifest(self.destination), self.old)
        record = json.loads(next(self.destination.parent.glob('.CodexSplit-work-replacement-*/RESULT.json')).read_text())
        self.assertEqual(record['phase'], 'staged')

    def test_control_change_mid_replacement_blocks(self):
        def change(root):
            self.official_calls += 1
            if self.official_calls == 2: self.daily({'schemaVersion': 3, 'attempts': []})
        with self.assertRaises(RuntimeError): self.deploy(official=change)
        self.assertEqual(m.replacement.manifest(self.destination), self.old)

    def test_same_launcher_or_changed_manifest_blocks(self):
        (self.bundle / 'Contents/MacOS/launcher').write_text('old')
        with self.assertRaises(RuntimeError): self.deploy()
        (self.bundle / 'Contents/MacOS/launcher').write_text('changed')
        with self.assertRaises(RuntimeError): self.deploy()
        self.assert_untouched()

    def candidate(self, phase='awaiting-compatibility-review', review_id='work-update-' + 'a' * 32, source_id=None):
        run = self.base / '.build/work-updates' / ('b' * 32)
        root = run / 'candidate'
        (root / 'Sources').mkdir(parents=True)
        (root / 'Sources/AppTrial.swift').write_text('    static let updateReviewID: String? = "' + (source_id or review_id) + '"\n')
        bundle = root / '.build/CodexSplit-work-standalone.app/Contents/MacOS'
        bundle.mkdir(parents=True); (bundle / 'launcher').write_text('new')
        (run / 'inspection.json').write_text(json.dumps({'expected': dict(PLAN, requestID='x', root='/synthetic')}))
        (run / 'RESULT.json').write_text(json.dumps({'phase': phase, 'liveTransitionPerformed': False, 'reviewID': review_id,
                                                     'candidateLauncher': str(root / '.build/CodexSplit-work-standalone.app')}))
        return root

    def test_reviewed_update_candidate(self):
        review_id = 'work-update-' + 'a' * 32
        root = self.candidate()
        self.review(review_id=review_id)
        result = self.deploy(root=root)
        self.assertEqual(result['reviewID'], review_id)
        self.assertEqual(json.loads((Path(result['receipt']).parent / 'UPDATE.json').read_text())['reviewID'], review_id)

    def test_automatic_mode_only_for_signed_version_candidate(self):
        self.review(mode='automatic')  # launcher-only replacement keeps a human review
        with self.assertRaises(RuntimeError): self.deploy()
        review_id = 'work-update-' + 'a' * 32
        root = self.candidate()
        self.review(review_id=review_id, mode='automatic',
                    items={name: {'result': 'accepted', 'evidence': 'x'} for name in ITEMS})
        with self.assertRaises(RuntimeError): self.deploy(root=root)  # automatic records never claim acceptance
        self.review(review_id=review_id, mode='automatic')
        result = self.deploy(root=root)
        self.assertEqual(json.loads((Path(result['receipt']).parent / 'UPDATE.json').read_text())['mode'], 'automatic')

    def test_replacement_must_continue_the_current_segment(self):
        # the installed launcher is not the one the work records are bound to (segment never started)
        self.daily({'schemaVersion': 3, 'attempts': [], 'update': {'toPlan': PLAN, 'toToolFingerprint': 'f' * 64}})
        with self.assertRaisesRegex(RuntimeError, '구간을 먼저 시작'): self.deploy()
        self.assert_untouched()
        # a version candidate staged from a source whose pins are not the segment's target
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved', 'plan': dict(PLAN, appBuild='9'), 'toolFingerprint': OLD_TOOL}]})
        root = self.candidate()
        self.review(review_id='work-update-' + 'a' * 32, mode='automatic')
        with self.assertRaisesRegex(RuntimeError, 'edge'): self.deploy(root=root)
        self.assert_untouched()

    def test_launcher_detection_uses_executable_paths(self):
        app = '/Users/x/Applications/CodexSplit-work.app/Contents/MacOS/launcher'
        self.assertTrue(m.launcher_running('/usr/bin/login\n' + app + '\n'))
        self.assertTrue(m.launcher_running('/Users/x/Projects/s/.build/CodexSplit-work-standalone.app/Contents/MacOS/launcher\n'))
        self.assertFalse(m.launcher_running('/usr/bin/shasum\n/bin/zsh\n'))  # comm never carries arguments
        self.assertFalse(m.launcher_running(app + '.bak\n'))

    def test_installed_icon_must_be_kept(self):
        (self.destination / 'Contents/Resources').mkdir()
        (self.destination / 'Contents/Resources/CodexSplit-work.icns').write_bytes(b'icns-local')
        self.old = m.replacement.manifest(self.destination); self.from_sha = m.replacement.manifest_digest(self.old)
        with self.assertRaisesRegex(RuntimeError, '아이콘'): self.deploy()
        (self.bundle / 'Contents/Resources').mkdir()
        (self.bundle / 'Contents/Resources/CodexSplit-work.icns').write_bytes(b'icns-local')
        (self.bundle / 'Contents/Resources/CodexSplit-work.icns').chmod(0o600)  # automatic builds run under umask 077
        self.new = m.replacement.manifest(self.bundle); self.to_sha = m.replacement.manifest_digest(self.new)
        self.review()
        self.assertEqual(self.deploy()['phase'], 'installed')

    def test_first_install_only_into_absent_destination(self):
        with self.assertRaises(RuntimeError):
            m.install_new(self.base, destination=self.destination, verify_signature=lambda p: None, base=self.base)
        fresh = self.destination.parent / 'Fresh.app'
        self.assertEqual(m.install_new(self.base, destination=fresh, verify_signature=lambda p: None, base=self.base), fresh)
        self.assertEqual(m.replacement.manifest(fresh), self.new)
        self.assertEqual(list(fresh.parent.glob('.CodexSplit-work-install-*')), [])
        root = self.candidate()
        with self.assertRaises(RuntimeError):  # update candidates replace, never first-install
            m.install_new(root, destination=self.destination.parent / 'Other.app', verify_signature=lambda p: None, base=self.base)

    def test_update_before_first_launcher_visit_continues_from_setup(self):
        (self.control / 'work-daily.json').unlink()
        (self.control / 'state.json').unlink()
        setup = {'workSetup': {'plan': PLAN, 'pending': False, 'visits': [{}, {}]}}
        private(self.control / 'state.json', json.dumps(setup).encode())
        root = self.candidate()
        self.review(review_id='work-update-' + 'a' * 32, mode='automatic')
        self.assertEqual(self.deploy(root=root)['phase'], 'installed')

    def test_update_before_setup_or_from_other_version_blocks(self):
        (self.control / 'work-daily.json').unlink()
        root = self.candidate()
        self.review(review_id='work-update-' + 'a' * 32, mode='automatic')
        with self.assertRaisesRegex(RuntimeError, '설정 미완료'): self.deploy(root=root)
        (self.control / 'state.json').unlink()
        private(self.control / 'state.json', json.dumps({'workSetup': {'plan': dict(PLAN, appBuild='9'), 'pending': False, 'visits': [{}, {}]}}).encode())
        with self.assertRaisesRegex(RuntimeError, 'edge'): self.deploy(root=root)
        self.assert_untouched()

    def test_install_new_retires_earlier_launcher_without_deleting(self):
        legacy = Path(self.tmp.name).resolve() / 'legacy'
        def busy(): raise RuntimeError('런처 실행 중')
        with self.assertRaises(RuntimeError):
            m.install_new(self.base, destination=self.destination, verify_signature=lambda p: None, base=self.base,
                          retire_existing=True, legacy=legacy, check_idle=busy)
        self.assertEqual(m.replacement.manifest(self.destination), self.old)
        m.install_new(self.base, destination=self.destination, verify_signature=lambda p: None, base=self.base,
                      retire_existing=True, legacy=legacy, check_idle=lambda: None)
        self.assertEqual(m.replacement.manifest(self.destination), self.new)
        retired = list(legacy.glob('launcher-*.app'))
        self.assertEqual(len(retired), 1)
        self.assertEqual(m.replacement.manifest(retired[0]), self.old)

    def test_unreviewed_or_foreign_candidate_blocks(self):
        for kw in ({'phase': 'blocked-tests'}, {'source_id': 'work-update-' + 'c' * 32}):
            root = self.candidate(**kw)
            self.review(review_id='work-update-' + 'a' * 32)
            with self.assertRaises(RuntimeError): self.deploy(root=root)
            import shutil; shutil.rmtree(self.base / '.build/work-updates')
        outside = Path(self.tmp.name).resolve() / 'elsewhere'
        outside.mkdir()
        with self.assertRaises(RuntimeError): self.deploy(root=outside)
        self.assert_untouched()

    def test_rejected_report_or_pending_setup_blocks(self):
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved', 'account': 'mismatch'}]})
        with self.assertRaises(RuntimeError): self.deploy()
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved'}]})
        (self.control / 'state.json').unlink(); private(self.control / 'state.json', b'{"workSetup":{"pending":true}}')
        with self.assertRaises(RuntimeError): self.deploy()
        self.assert_untouched()

    def test_running_launcher_detected_before_lock(self):
        import fcntl
        held = os.open(self.control / 'state.lock', os.O_RDONLY)
        fcntl.flock(held, fcntl.LOCK_EX)  # a launcher transaction in progress
        self.addCleanup(os.close, held)
        def busy(): raise RuntimeError('런처 실행 중')
        with self.assertRaisesRegex(RuntimeError, '런처 실행 중'): self.deploy(check_idle=busy)
        self.assert_untouched()

    def test_interrupted_bind_can_be_completed_once(self):
        original = m.bind
        def partial(workspace, review_id, mode, launcher_sha, to_sha, review_bytes):
            private(workspace / 'REVIEW.json', review_bytes); raise OSError('중단')
        m.bind = partial
        try:
            with self.assertRaises(OSError): self.deploy()
        finally:
            m.bind = original
        receipt = next(self.destination.parent.glob('.CodexSplit-work-replacement-*/RESULT.json'))
        self.assertFalse((receipt.parent / 'UPDATE.json').exists())
        m.rebind(receipt, self.base, self.review_path, destination=self.destination, verify_signature=lambda p: None, base=self.base)
        self.assertEqual(json.loads((receipt.parent / 'UPDATE.json').read_text())['launcherSHA256'], hashlib.sha256(b'new').hexdigest())

    def test_restore_before_transition_only(self):
        result = self.deploy()
        receipt = Path(result['receipt'])
        self.daily({'schemaVersion': 3, 'attempts': [], 'update': {'replacement': {'receiptPath': str(receipt)}}})
        with self.assertRaises(RuntimeError):
            m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)
        self.assertEqual(m.replacement.manifest(self.destination), self.new)
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved'}]})
        m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)
        self.assertEqual(m.replacement.manifest(self.destination), self.old)
        self.assertEqual(m.replacement.manifest(receipt.parent / 'restored-from.app'), self.new)
        self.assertEqual(json.loads((receipt.parent / 'RESTORE.json').read_text())['phase'], 'restored')
        self.assertEqual((self.control / 'state.json').read_bytes(), b'{"setup":"preserved"}')
        with self.assertRaises(RuntimeError):  # one restore per receipt
            m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)

    def test_restore_allowed_after_rejected_report_but_not_during_visit(self):
        receipt = Path(self.deploy()['receipt'])
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'active'}]})
        with self.assertRaises(RuntimeError):
            m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)
        self.assertEqual(m.replacement.manifest(self.destination), self.new)
        self.daily({'schemaVersion': 2, 'attempts': [{'phase': 'exitObserved', 'account': 'mismatch'}]})
        m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)
        self.assertEqual(m.replacement.manifest(self.destination), self.old)

    def test_interrupted_restore_is_journaled(self):
        result = self.deploy()
        receipt = Path(result['receipt'])
        original = m.replacement.rename_exclusive
        calls = []
        def interrupt(source, destination):
            calls.append(source)
            if len(calls) == 2: raise OSError('중단')
            original(source, destination)
        m.replacement.rename_exclusive = interrupt
        try:
            with self.assertRaises(OSError):
                m.restore(receipt, destination=self.destination, control=self.control, verify_signature=lambda p: None, check_idle=lambda: None)
        finally:
            m.replacement.rename_exclusive = original
        self.assertEqual(json.loads((receipt.parent / 'RESTORE.json').read_text())['phase'], 'restoring')
        self.assertFalse(self.destination.exists())
        self.assertEqual(m.replacement.manifest(receipt.parent / 'previous.app'), self.old)
        self.assertEqual(m.replacement.manifest(receipt.parent / 'restored-from.app'), self.new)


if __name__ == '__main__':
    unittest.main()
