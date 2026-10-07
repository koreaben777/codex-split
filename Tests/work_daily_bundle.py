"""Check the standalone launcher bundle structure without opening it."""
from pathlib import Path
import os
import plistlib

bundle = Path('.build/CodexSplit-work-standalone.app')
assert bundle.exists(), 'standalone work launcher not built'
with (bundle / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleIdentifier'] == 'local.codexsplit.work'
assert info['CFBundleDisplayName'] == 'CodexSplit 업무용'
assert info['CFBundleExecutable'] == 'launcher'
assert info['LSUIElement'] is True
icon = bundle / 'Contents/Resources/CodexSplit-work.icns'
assert ('CFBundleIconFile' in info) == icon.is_file()
if icon.is_file():
    assert info['CFBundleIconFile'] == 'CodexSplit-work.icns' and not icon.is_symlink() and icon.read_bytes()[:4] == b'icns'
root = (bundle / 'Contents/Resources/source-root').read_text().strip()
assert root == os.environ.get('CODEXSPLIT_SOURCE_ROOT', os.path.realpath(os.getcwd())) and root.startswith('/')
assert (bundle / 'Contents/MacOS/launcher').is_file() and not (bundle / 'Contents/MacOS/launcher').is_symlink()
assert sorted(p.name for p in (bundle / 'Contents/MacOS').iterdir()) == ['launcher']
assert not (bundle / 'Contents/Resources/codex-split').exists()
print('standalone launcher bundle structure ok (not opened)')
