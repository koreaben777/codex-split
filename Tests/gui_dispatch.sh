#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. scripts/sources.sh
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY Tests/gui-dispatch/main.swift -o .build/gui-dispatch-check
.build/gui-dispatch-check
