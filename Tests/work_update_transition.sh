#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. scripts/sources.sh
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY Tests/work-update-transition/main.swift -o .build/work-update-transition-check
.build/work-update-transition-check
