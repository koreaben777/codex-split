#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for role in personal work; do
    bundle="$PWD/.build/CodexSplit-$role.app"
    test -x "$bundle/Contents/MacOS/launcher"
    plist="$bundle/Contents/Info.plist"
    /usr/bin/plutil -lint "$plist"
    test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")" = "local.codexsplit.dev.$role"
    test "$(/usr/bin/plutil -extract CodexSplitProfile raw -o - "$plist")" = "$role"
    test "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist")" = launcher
    if [ "$role" = work ]; then label="CodexSplit 업무용 (개발)"; else label="CodexSplit 개인용 (개발)"; fi
    test "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$plist")" = "$label"
done
echo "Shortcut structure checks passed (apps not opened)"
