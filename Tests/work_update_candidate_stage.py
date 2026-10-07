"""Stage synthetic new pins into a copied source tree with update-work.py and compile it."""
from pathlib import Path
import copy, importlib.util, shutil, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stage_update', ROOT / 'scripts/update-work.py')
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)
SOURCES = sorted(p.stem for p in (ROOT / 'Sources').glob('*.swift') if p.name not in ('main.swift', 'Launcher.swift', 'WorkDailyUI.swift'))


class CandidateStageTests(unittest.TestCase):
    def test_staged_candidate_reads_previous_target_but_cannot_launch_it(self):
        with tempfile.TemporaryDirectory(prefix='candidate-stage-', dir=ROOT / '.test-data') as directory:
            candidate = Path(directory)
            shutil.copytree(ROOT / 'Sources', candidate / 'Sources')
            binary = dict(path='/Applications/ChatGPT.app/Contents/MacOS/ChatGPT', version='26.999.1', build='99999', fingerprint='e' * 64)
            cli = dict(path='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
                       version='0.999.0', build='1', fingerprint='d' * 64)
            report = dict(observed=dict(app=binary, cli=cli, resourcesSHA256='f' * 64))
            update.stage_pins(candidate, copy.deepcopy(report), 'work-update-' + '9' * 32)
            output = candidate / 'candidate-check'
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(ROOT / '.build/module-cache'), '-import-objc-header',
                            str(ROOT / 'Sources/Native.h'), str(ROOT / '.build/Native.o')]
                           + [str(candidate / 'Sources' / (name + '.swift')) for name in SOURCES]
                           + [str(ROOT / 'Tests/work-update-candidate/main.swift'), '-o', str(output)], check=True)
            result = subprocess.run([str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip(), file=sys.stderr)


if __name__ == '__main__':
    unittest.main()
