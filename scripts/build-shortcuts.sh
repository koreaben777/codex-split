#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test ! -L .build
test -x .build/codex-split
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" Sources/LauncherProtocol.swift Sources/Launcher.swift -o .build/launcher
for role in personal work; do
    if [ "$role" = work ]; then label="CodexSplit 업무용 (개발)"; else label="CodexSplit 개인용 (개발)"; fi
    bundle="$PWD/.build/CodexSplit-$role.app"
    test ! -L "$bundle"
    mkdir -p "$bundle/Contents/MacOS"
    cp .build/launcher "$bundle/Contents/MacOS/launcher"
    cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codexsplit.dev.$role</string>
<key>CFBundleName</key><string>CodexSplit-$role</string>
<key>CFBundleDisplayName</key><string>$label</string>
<key>CFBundleExecutable</key><string>launcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>CodexSplitProfile</key><string>$role</string>
</dict></plist>
EOF
done
