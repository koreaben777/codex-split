"""First-install orchestration; subprocesses are replaced so no real app/profile is opened."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/install-work.py'


class FirstInstallTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(), 'one-command installer is missing')
        spec = importlib.util.spec_from_file_location('first_install', SOURCE)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        output = patch('builtins.print')
        output.start(); self.addCleanup(output.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve()
        self.base = root / 'checkout with spaces'
        self.base.mkdir()
        self.work = root / 'work'
        self.destination = root / 'CodexSplit-work.app'
        self.app = root / 'ChatGPT.app'
        self.app.mkdir()
        for name, value in [('BASE', self.base), ('WORK_ROOT', self.work),
                            ('DESTINATION', self.destination), ('OFFICIAL_APP', self.app)]:
            p = patch.object(self.m, name, value)
            p.start(); self.addCleanup(p.stop)
        for target, value in [('sys.platform', 'darwin'), ('os.geteuid', 501),
                              ('sys.stdin.isatty', True), ('sys.stdout.isatty', True),
                              ('shutil.which', '/fixture/tool')]:
            p = patch(target, **({'new': value} if target == 'sys.platform' else {'return_value': value}))
            p.start(); self.addCleanup(p.stop)
        self.calls = []
        self.fail = None
        def run(args, **kwargs):
            self.calls.append(args)
            if args[0] != 'xcrun':
                self.assertEqual(kwargs['cwd'], self.base)
                self.assertEqual(kwargs['env']['CODEXSPLIT_SOURCE_ROOT'], str(self.base))
            if self.fail and self.fail in args:
                raise subprocess.CalledProcessError(2, args)
            return subprocess.CompletedProcess(args, 0)
        p = patch.object(self.m.subprocess, 'run', side_effect=run)
        p.start(); self.addCleanup(p.stop)

    def test_build_pin_check_setup_verify_install_in_order(self):
        self.m.main([])
        commands = [call for call in self.calls if call[0] != 'xcrun']
        self.assertEqual(commands, [
            ['sh', 'scripts/build.sh'],
            [self.m.sys.executable, 'scripts/update-work.py', '--pin-installed'],
            ['sh', 'scripts/check.sh'],
            [str(self.base / '.build/codex-split-work-setup'), '--setup', 'work'],
            [str(self.base / '.build/codex-split'), 'update-check', 'work', '--json'],
            [self.m.sys.executable, 'scripts/install-work-update-approved.py', '--install-new'],
        ])

    def test_failure_never_continues_to_later_stages(self):
        for failed in ['scripts/build.sh', 'scripts/update-work.py', 'scripts/check.sh',
                       '--setup', 'update-check', '--install-new']:
            with self.subTest(failed=failed):
                self.calls.clear(); self.fail = failed
                with self.assertRaises(subprocess.CalledProcessError): self.m.main([])
                self.assertIn(failed, self.calls[-1])

    def test_existing_profile_or_launcher_is_preserved_even_dangling_symlinks(self):
        for path in [self.work, self.destination]:
            for symlink in [False, True]:
                with self.subTest(path=path, symlink=symlink):
                    if symlink: path.symlink_to(path.parent / 'absent')
                    else: path.write_bytes(b'preserve')
                    with self.assertRaises(RuntimeError): self.m.main([])
                    self.assertFalse(self.calls)
                    if not symlink: self.assertEqual(path.read_bytes(), b'preserve')
                    path.unlink()

    def test_missing_app_tools_nonterminal_root_and_other_os_stop_before_build(self):
        cases = [('sys.platform', {'new': 'linux'}), ('os.geteuid', {'return_value': 0}),
                 ('sys.stdin.isatty', {'return_value': False}),
                 ('sys.stdout.isatty', {'return_value': False}),
                 ('shutil.which', {'return_value': None})]
        for target, kwargs in cases:
            with self.subTest(target=target), patch(target, **kwargs):
                with self.assertRaises(RuntimeError): self.m.main([])
                self.assertFalse(self.calls)
        self.app.rmdir()
        with self.assertRaises(RuntimeError): self.m.main([])
        self.assertFalse(self.calls)

    def test_unusable_xcode_tool_stops_before_build(self):
        self.fail = '--find'
        with self.assertRaises(subprocess.CalledProcessError): self.m.main([])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], 'xcrun')

    def test_help_needs_no_prerequisites_and_unknown_args_do_not_install(self):
        with patch('sys.platform', 'linux'):
            self.m.main(['--help'])
            with self.assertRaises(RuntimeError): self.m.main(['--force'])
        self.assertFalse(self.calls)


if __name__ == '__main__':
    unittest.main()
