#!/bin/sh
set -eu
[ "$#" -eq 0 ] || { echo "Usage: sh scripts/check.sh" >&2; exit 64; }
cd "$(dirname "$0")/.."
test ! -L .build
test ! -L .test-data
test ! -L .build/module-cache
mkdir -p .build/module-cache .test-data
. scripts/sources.sh
swift_check() { # name, test entry, extra sources...
    name=$1; entry=$2; shift 2
    xcrun swiftc -module-cache-path "$PWD/.build/module-cache" -import-objc-header Sources/Native.h .build/Native.o $SWIFT_LIBRARY "$@" "$entry" -o ".build/$name"
}
python3 Tests/harness_ownership_test.py
xcrun clang -Wall -Wextra -Werror -c Sources/Native.c -o .build/Native.o
xcrun clang -Wall -Wextra -Werror Tests/NativeObserver.c .build/Native.o -o .build/native-observer-check
.build/native-observer-check "$PWD/.test-data/native-observer-$$.marker"
xcrun clang -Wall -Wextra -Werror Tests/NativePreparation.c .build/Native.o -o .build/native-preparation-check
.build/native-preparation-check
for suite in app-opening app-approval app-runtime app-trial; do
    swift_check "$suite-check" "Tests/$suite/main.swift"
    ".build/$suite-check"
done
python3 Tests/terminal_eof.py
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" Tests/FakeCLI.swift -o .build/fake-cli
swift_check check Tests/main.swift
swift_check readiness-check Tests/readiness/main.swift
.build/readiness-check
xcrun clang -Wall -Wextra -Werror Tests/NativeSignalRace.c -o .build/native-signal-race
python3 Tests/terminal.py
.build/check
sh scripts/build.sh
sh Tests/cli.sh
sh scripts/build-shortcuts.sh
sh Tests/shortcuts.sh
sh Tests/work_update.sh
python3 Tests/work_update_automation.py
sh Tests/work_update_transition.sh
python3 Tests/launcher_replacement_test.py
python3 Tests/work_update_install.py
python3 Tests/work_update_candidate_stage.py
sh Tests/work_daily.sh
sh Tests/gui_dispatch.sh
sh scripts/build-work-daily.sh
