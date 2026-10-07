#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test ! -L .build
test ! -L .build/module-cache
mkdir -p .build/module-cache
. scripts/sources.sh
bundle="$PWD/.build/CodexSplit-work-standalone.app"
test ! -L "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
test ! -L "$bundle/Contents"
test ! -L "$bundle/Contents/MacOS"
test ! -L "$bundle/Contents/Resources"
test ! -L "$bundle/Contents/MacOS/launcher"
xcrun clang -Wall -Wextra -Werror -c Sources/Native.c -o .build/Native.o
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY Sources/WorkDailyUI.swift -o "$bundle/Contents/MacOS/launcher"
# The checkout the launcher may stage update candidates from. Candidates built by
# scripts/update-work.py keep pointing at the operational checkout.
source_root="${CODEXSPLIT_SOURCE_ROOT:-$(pwd -P)}"
case "$source_root" in /*) ;; *) echo "CODEXSPLIT_SOURCE_ROOT must be absolute" >&2; exit 64 ;; esac
printf '%s\n' "$source_root" > "$bundle/Contents/Resources/source-root"
# Optional local icon (not distributed): Assets/WorkIcon/CodexSplit-work.icns
icon_key=""
rm -f "$bundle/Contents/Resources/CodexSplit-work.icns"
if [ -f Assets/WorkIcon/CodexSplit-work.icns ]; then
    test ! -L Assets/WorkIcon/CodexSplit-work.icns
    cp Assets/WorkIcon/CodexSplit-work.icns "$bundle/Contents/Resources/CodexSplit-work.icns"
    icon_key="<key>CFBundleIconFile</key><string>CodexSplit-work.icns</string>"
fi
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codexsplit.work</string>
<key>CFBundleName</key><string>CodexSplit-work</string>
<key>CFBundleDisplayName</key><string>CodexSplit 업무용</string>
<key>CFBundleExecutable</key><string>launcher</string>
$icon_key
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier local.codexsplit.work "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
python3 Tests/work_daily_bundle.py
