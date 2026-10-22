#!/bin/sh
set -eu
[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --checker-only ]; } || { echo "Usage: sh scripts/build.sh [--checker-only]" >&2; exit 64; }
cd "$(dirname "$0")/.."
test ! -L .build
mkdir -p .build/module-cache
test ! -L .build/module-cache
. scripts/sources.sh
xcrun clang -Wall -Wextra -Werror -c Sources/Native.c -o .build/Native.o
targets="codex-split Sources/main.swift"
if [ "$#" -eq 0 ]; then
    targets="$targets
codex-split-work-setup Sources/work-setup/main.swift
codex-split-update-progress Sources/update-progress/main.swift"
fi
printf '%s\n' "$targets" | while read -r name entry; do
    xcrun swiftc -whole-module-optimization -Onone -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY "$entry" -o ".build/$name"
done
