#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test ! -L .build
mkdir -p .build/module-cache
test ! -L .build/module-cache
. scripts/sources.sh
xcrun clang -Wall -Wextra -Werror -c Sources/Native.c -o .build/Native.o
for target in "codex-split Sources/main.swift" "codex-split-work-setup Sources/work-setup/main.swift" "codex-split-update-progress Sources/update-progress/main.swift"; do
    set -- $target
    xcrun swiftc -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY "$2" -o ".build/$1"
done
