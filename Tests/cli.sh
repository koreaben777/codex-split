#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch="$PWD/.test-data/cli-$$"
mkdir -m 700 "$scratch"
trap 'rm -rf "$scratch"' EXIT
cli="$PWD/.build/codex-split"
if ! "$cli" status personal --json > "$scratch/status.json"; then
    echo "FAIL: read-only status command"
    exit 1
fi
test "$(/usr/bin/plutil -extract process.state raw -o - "$scratch/status.json")" = unknown
test "$(/usr/bin/plutil -extract localConnection.state raw -o - "$scratch/status.json")" = unknown
test "$(/usr/bin/plutil -extract localConnection.capability raw -o - "$scratch/status.json")" = manual-only
"$cli" profiles > "$scratch/profiles.json"
test "$(/usr/bin/plutil -extract 0.profileId raw -o - "$scratch/profiles.json")" = personal
test "$(/usr/bin/plutil -extract 1.profileId raw -o - "$scratch/profiles.json")" = work
"$cli" help > "$scratch/help"
for command in cli app login verify-auth approve; do
    set +e
    case "$command" in
        cli) "$cli" cli work --cwd "$scratch" > "$scratch/result" ;;
        approve) "$cli" approve work --target cli --stage day --cwd "$scratch" > "$scratch/result" ;;
        *) "$cli" "$command" work > "$scratch/result" ;;
    esac
    result=$?
    set -e
    test "$result" -eq 2
done
set +e
"$cli" cli work --cwd "$scratch" --force > "$scratch/result"
result=$?
set -e
test "$result" -eq 64
test ! -e "$scratch/state.json"
set +e
"$cli" app work --json > "$scratch/app-reply.json"
result=$?
set -e
test "$result" -eq 2
test "$(/usr/bin/plutil -extract state raw -o - "$scratch/app-reply.json")" = blocked
test "$(/usr/bin/plutil -extract reason raw -o - "$scratch/app-reply.json")" = PROFILE_UNCONFIGURED
test "$(/usr/bin/plutil -extract profileId raw -o - "$scratch/app-reply.json")" = work
test "$(/usr/bin/plutil -extract launchConfirmed raw -o - "$scratch/app-reply.json")" = false
set +e
"$cli" app work --json --force > "$scratch/result"
result=$?
set -e
test "$result" -eq 64
set +e
.build/codex-split-work-setup --unknown work < /dev/null > "$scratch/work-ui-result"
setup_result=$?
.build/codex-split-work-setup --adopt work --from relative/root < /dev/null > "$scratch/work-ui-result"
adopt_result=$?
set -e
test "$setup_result" -eq 64
test "$adopt_result" -eq 64
for command in update-check update-plan; do
    set +e
    "$cli" "$command" work --force > "$scratch/result"
    result=$?
    set -e
    test "$result" -eq 64
    set +e
    "$cli" "$command" personal > "$scratch/result"
    result=$?
    set -e
    test "$result" -eq 64
done
echo "CLI integration checks passed"
