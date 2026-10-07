"""Exercise the entire update pipeline using fixtures, never production app/profile data."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('update_work', Path(__file__).resolve().parents[1] / 'scripts/update-work.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


SEED = 'Self(appVersion: "1.0", appBuild: "1", appFingerprint: "' + '0' * 64 + '", cliVersion: "2.0", cliBuild: "2", cliFingerprint: "' + 'a' * 64 + '", resourcesSHA256: "' + 'b' * 64 + '")'
MANAGED = ('struct WorkAppPins {\n    // BEGIN update-work managed pins\n    static let current: Self = ' + SEED + '\n'
           '    static let history: [Self] = [\n    ]\n    static let updateReviewID: String? = nil\n'
           '    // END update-work managed pins\n}\n')


def PASSING(bundle):
    return {name: {'required': ['X'], 'missing': []} for name in module.ISOLATION_MARKERS}


class FakeReplacement:
    @staticmethod
    def manifest(path): return str(path)
    @staticmethod
    def manifest_digest(value): return ('1' if value.endswith('standalone.app') else '2') * 64


def report():
    expected = dict(requestID='old', requestedAt=1, root='/synthetic/work', bundlePath='/synthetic/App.app',
                    executablePath='/synthetic/App.app/Contents/MacOS/App', cliExecutablePath='/synthetic/App.app/Contents/MacOS/codex',
                    appVersion='1.0', appBuild='1', appFingerprint='0' * 64, cliVersion='2.0', cliBuild='2', cliFingerprint='a' * 64)
    binary = dict(path=expected['executablePath'], version='2.0', build='2', fingerprint='a' * 64)
    cli = dict(binary, path=expected['cliExecutablePath'])
    signature = dict(state='valid-openai', team='2DC432GLL2', cdhash='1234')
    return dict(schemaVersion=1, status='review-required', expected=expected, expectedResourcesSHA256='b' * 64,
                launchPermitted=False, approvalChanged=False, observed=dict(app=binary, cli=cli,
                appSignature=signature, cliSignature=signature, resourcesSHA256='c' * 64))


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / 'repo'
        self.base.mkdir()
        for directory in ('Sources', 'Tests', 'Assets', 'scripts', '.profiles'):
            (self.base / directory).mkdir()
        self.secret = self.base / '.profiles/DO-NOT-COPY'
        self.secret.write_text('synthetic-private-marker')
        (self.base / 'Sources/AppTrial.swift').write_text(MANAGED)
        (self.base / 'Sources/WorkSetup.swift').write_text('static let resourcesFingerprint = "' + 'b' * 64 + '"\n')
        self.run = Path(self.temp.name) / 'run'
        self.run.mkdir()
        self.calls = 0
        self.observation = report()

    def inspector(self, base):
        self.calls += 1
        value = copy.deepcopy(self.observation)
        value['expected']['requestID'] = str(self.calls)
        value['expected']['requestedAt'] = self.calls
        return value

    def test_stage_and_reinspect_without_promoting(self):
        original = (self.base / 'Sources/AppTrial.swift').read_bytes()
        setup = (self.base / 'Sources/WorkSetup.swift').read_bytes()
        def checks(source, log):
            self.assertFalse((source / '.profiles').exists())
            staged = (source / 'Sources/AppTrial.swift').read_text()
            self.assertIn('static let current: Self = Self(appVersion: "2.0", appBuild: "2", appFingerprint: "' + 'a' * 64, staged)
            self.assertIn('resourcesSHA256: "' + 'c' * 64 + '")', staged)
            self.assertIn('    static let history: [Self] = [\n        ' + SEED + ',\n    ]\n', staged)
            self.assertRegex(staged, r'updateReviewID: String\? = "work-update-[0-9a-f]{32}"')
            # Staging touches only the managed pin block, never other sources.
            self.assertEqual((source / 'Sources/WorkSetup.swift').read_bytes(), setup)
            self.assertEqual((self.base / 'Sources/AppTrial.swift').read_bytes(), original)
            return True
        result = module.pipeline(self.base, self.run, self.inspector, checks, probe=PASSING)
        self.assertEqual(result['phase'], 'awaiting-compatibility-review')
        self.assertIn(result['reviewID'], (self.run / 'candidate/Sources/AppTrial.swift').read_text())
        self.assertEqual(self.calls, 2)
        self.assertFalse(result['liveTransitionPerformed'])
        self.assertFalse(result['launchPermitted'])
        self.assertEqual(self.secret.read_text(), 'synthetic-private-marker')

    def test_tests_failure_preserves_candidate(self):
        result = module.pipeline(self.base, self.run, self.inspector, lambda *_: False, probe=PASSING)
        self.assertEqual(result['phase'], 'blocked-tests')
        self.assertEqual(self.calls, 1)
        self.assertTrue((self.run / 'candidate').is_dir())

    def test_app_changes_during_tests(self):
        def checks(*_):
            self.observation['observed']['app']['fingerprint'] = 'd' * 64
            return True
        with self.assertRaises(RuntimeError):
            module.pipeline(self.base, self.run, self.inspector, checks, probe=PASSING)
        self.assertEqual(json.loads((self.run / 'RESULT.json').read_text())['phase'], 'blocked-error')

    def test_unchanged_and_unverified_do_not_build(self):
        for status in ('pinned', 'unverified'):
            run = self.run / status
            run.mkdir()
            self.observation['status'] = status
            result = module.pipeline(self.base, run, self.inspector, lambda *_: self.fail('must not build'), probe=PASSING)
            self.assertEqual(result['phase'], 'unchanged' if status == 'pinned' else 'blocked-unverified')
            self.assertFalse((run / 'candidate').exists())

    def test_source_links_rejected(self):
        (self.base / 'Sources/linked').symlink_to(self.secret)
        with self.assertRaises(RuntimeError):
            module.pipeline(self.base, self.run, self.inspector, lambda *_: True, probe=PASSING)

    def test_untrusted_metadata_rejected(self):
        for value in ('bad\nmetadata', '\\(arbitraryCode())', '../path', ''):
            candidate = report()
            candidate['observed']['app']['version'] = value
            with self.assertRaises(RuntimeError):
                module.validate_candidate(candidate)
        candidate = report()
        candidate['observed']['appSignature']['team'] = 'foreign'
        with self.assertRaises(RuntimeError):
            module.validate_candidate(candidate)

    def test_second_update_extends_history_once(self):
        source = self.base / 'Sources'
        module.stage_pins(self.base, report(), 'work-update-' + '1' * 32)
        second = report()
        second['observed']['app'].update(version='3.0', build='3', fingerprint='e' * 64)
        module.stage_pins(self.base, second, 'work-update-' + '2' * 32)
        staged = (source / 'AppTrial.swift').read_text()
        self.assertIn('appVersion: "3.0"', staged.split('static let history')[0])
        history = staged.split('static let history: [Self] = [\n')[1].split('    ]\n')[0].splitlines()
        self.assertEqual(len(history), 2)
        self.assertIn('appVersion: "2.0"', history[0])
        self.assertEqual(history[1], '        ' + SEED + ',')
        self.assertIn('work-update-' + '2' * 32, staged)
        with self.assertRaises(RuntimeError):  # same target again is not a new edge
            module.stage_pins(self.base, second, 'work-update-' + '3' * 32)

    def test_managed_block_tampering_rejected(self):
        trial = self.base / 'Sources/AppTrial.swift'
        for broken in (MANAGED.replace(SEED, 'arbitraryCode()'), MANAGED.replace('// END', '// FIN'),
                       MANAGED.replace('    ]\n', '        Self(appVersion: "x"),\n    ]\n')):
            trial.write_text(broken)
            with self.assertRaises(RuntimeError):
                module.stage_pins(self.base, report(), 'work-update-' + '1' * 32)
        trial.write_text(MANAGED)
        with self.assertRaises(RuntimeError):
            module.stage_pins(self.base, report(), 'work-update-bad')

    def test_resource_only_change_is_not_a_version_edge(self):
        candidate = report()
        for name, prefix in (('app', 'app'), ('cli', 'cli')):
            for field, suffix in (('version', 'Version'), ('build', 'Build'), ('fingerprint', 'Fingerprint')):
                candidate['observed'][name][field] = candidate['expected'][prefix + suffix]
        with self.assertRaises(RuntimeError):
            module.validate_candidate(candidate)

    def test_missing_isolation_marker_stops_before_build(self):
        def missing(bundle):
            return {name: {'required': ['CODEX_HOME'], 'missing': ['CODEX_HOME']} for name in module.ISOLATION_MARKERS}
        result = module.pipeline(self.base, self.run, self.inspector, lambda *_: self.fail('must not build'), probe=missing)
        self.assertEqual(result['phase'], 'blocked-incompatible')
        self.assertFalse((self.run / 'candidate').exists())

    def test_isolation_probe_finds_markers_across_chunks(self):
        bundle = Path(self.temp.name) / 'App.app'
        for relative, markers in module.ISOLATION_MARKERS.items():
            path = bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            # first marker straddles the 8 MiB read boundary
            path.write_bytes(b'x' * ((8 << 20) - 5) + b' '.join(markers))
        result = module.isolation_markers(bundle.resolve())
        self.assertTrue(all(not value['missing'] for value in result.values()))
        asar = bundle / 'Contents/Resources/app.asar'
        asar.write_bytes(asar.read_bytes().replace(b'CODEX_ELECTRON_USER_DATA_PATH', b'REMOVED'))
        self.assertEqual(module.isolation_markers(bundle.resolve())['Contents/Resources/app.asar']['missing'], ['CODEX_ELECTRON_USER_DATA_PATH'])

    def automatic(self, deploy=None, idle_failures=0, consent_age=0, pipeline_run=None):
        alerts, sleeps, calls = [], [], []
        idle_state = {'remaining': idle_failures}
        def idle():
            if idle_state['remaining']:
                idle_state['remaining'] -= 1
                raise RuntimeError('런처 실행 중')
        def default_deploy(root, review, from_sha, to_sha, install):
            calls.append((root, json.loads(Path(review).read_text()), from_sha, to_sha, install))
            return {'receipt': '/receipt/RESULT.json', 'backup': '/receipt/previous.app'}
        installer = type('Installer', (), dict(replacement=FakeReplacement, DESTINATION=Path('/installed.app'),
                                               launcher_idle=staticmethod(idle), deploy=staticmethod(deploy or default_deploy)))
        def run_pipeline(base, run):
            return module.pipeline(base, run, self.inspector, lambda *_: True, probe=PASSING)
        state = module.automatic(self.base, self.run, 1000.0, now=lambda: 1000.0 + consent_age, pipeline_run=pipeline_run or run_pipeline,
                                 installer=installer, sleep=sleeps.append, alert=alerts.append)
        return state, alerts, sleeps, calls

    def test_automatic_response_installs_after_launcher_closes(self):
        state, alerts, sleeps, calls = self.automatic(idle_failures=2)
        self.assertEqual(state['phase'], 'installed')
        self.assertEqual(sleeps, [10, 10])
        root, review, from_sha, to_sha, install = calls[0]
        self.assertEqual((root, from_sha, to_sha, install), (self.run / 'candidate', '2' * 64, '1' * 64, True))
        self.assertEqual(review['mode'], 'automatic')
        self.assertEqual(review['reviewID'], state['reviewID'])
        self.assertTrue(all(item['result'] == 'automatic' for item in review['items'].values()))
        self.assertIn('사람이 검토하지 않음', review['items']['release-evidence']['evidence'])
        self.assertIn('교체했습니다', alerts[-1])
        self.assertEqual(json.loads((self.run / 'RESULT.json').read_text())['phase'], 'installed')

    def test_automatic_response_keeps_old_launcher_on_install_failure(self):
        def refused(*_): raise RuntimeError('미해결 업무 실행 존재')
        state, alerts, _, _ = self.automatic(deploy=refused)
        self.assertEqual(state['phase'], 'blocked-install')
        self.assertEqual(state['errorMessage'], '미해결 업무 실행 존재')
        self.assertIn('교체를 하지 않았습니다', alerts[-1])

    def test_automatic_response_stops_on_failed_checks_or_stale_consent(self):
        def failing(base, run): return module.pipeline(base, run, self.inspector, lambda *_: False, probe=PASSING)
        state, alerts, _, calls = self.automatic(pipeline_run=failing)
        self.assertEqual((state['phase'], calls), ('blocked-tests', []))
        self.assertIn('blocked-tests', alerts[-1])
        with self.assertRaises(RuntimeError):
            self.automatic(consent_age=121)

    def test_next_candidate_stages_from_the_installed_candidate(self):
        runs = Path(self.temp.name) / 'runs'
        installed = Path(self.temp.name) / 'installed-launcher'
        installed.write_bytes(b'deployed')
        self.assertEqual(module.deployed_source(self.base, runs, installed), self.base)
        for name, phase, content in (('a' * 32, 'installed', b'older'), ('b' * 32, 'installed', b'deployed'), ('c' * 32, 'blocked-tests', b'deployed')):
            launcher = runs / name / 'candidate/.build/CodexSplit-work-standalone.app/Contents/MacOS'
            launcher.mkdir(parents=True)
            (launcher / 'launcher').write_bytes(content)
            (runs / name / 'RESULT.json').write_text(json.dumps({'phase': phase}))
        self.assertEqual(module.deployed_source(self.base, runs, installed), runs / ('b' * 32) / 'candidate')
        installed.write_bytes(b'unknown')
        self.assertEqual(module.deployed_source(self.base, runs, installed), self.base)

    def test_automatic_loads_installer_from_operational_checkout(self):
        loaded = []
        original = module.load_installer
        module.load_installer = lambda base: loaded.append(base) or (_ for _ in ()).throw(RuntimeError('stop'))
        try:
            with self.assertRaises(RuntimeError):
                module.automatic(self.base / 'elsewhere', self.run, 1000.0, now=lambda: 1000.0, alert=lambda _: None)
        finally:
            module.load_installer = original
        self.assertEqual(loaded, [module.BASE])

    def test_pin_installed_only_before_first_setup(self):
        profile = Path(self.temp.name) / 'profiles/work'
        self.observation['observed']['app']['version'] = '9.9'
        self.assertEqual(module.pin_installed(self.base, self.inspector, PASSING, profile), 'pinned')
        trial = (self.base / 'Sources/AppTrial.swift').read_text()
        self.assertIn('static let current: Self = Self(appVersion: "9.9"', trial)
        self.assertIn('    static let history: [Self] = [\n    ]\n', trial)
        self.assertIn('updateReviewID: String? = nil', trial)
        profile.mkdir(parents=True)
        with self.assertRaises(RuntimeError):  # an existing work profile changes versions only through updates
            module.pin_installed(self.base, self.inspector, PASSING, profile)

    def test_pin_installed_requires_signature_and_isolation_markers(self):
        profile = Path(self.temp.name) / 'absent'
        self.observation['observed']['appSignature']['team'] = 'foreign'
        with self.assertRaises(RuntimeError):
            module.pin_installed(self.base, self.inspector, PASSING, profile)
        self.observation = report()
        def missing(bundle):
            return {name: {'required': ['CODEX_HOME'], 'missing': ['CODEX_HOME']} for name in module.ISOLATION_MARKERS}
        with self.assertRaises(RuntimeError):
            module.pin_installed(self.base, self.inspector, missing, profile)
        self.assertEqual((self.base / 'Sources/AppTrial.swift').read_text(), MANAGED)

    def test_candidate_checks_run_full_suite_with_operational_source(self):
        candidate = Path(self.temp.name) / 'candidate'
        (candidate / 'scripts').mkdir(parents=True)
        (candidate / 'scripts/check.sh').write_text(
            '#!/bin/sh\nset -eu\ntest "$#" -eq 0\n'
            'test "$CODEXSPLIT_SOURCE_ROOT" = "' + str(module.BASE) + '"\necho "candidate contract reached"\n')
        log = candidate / 'checks.log'
        self.assertTrue(module.run_checks(candidate, log), log.read_text())
        self.assertIn('candidate contract reached', log.read_text())

    def test_path_change_requires_review(self):
        candidate = report()
        candidate['observed']['cli']['path'] = '/elsewhere'
        with self.assertRaises(RuntimeError):
            module.validate_candidate(candidate)


if __name__ == '__main__':
    unittest.main()
