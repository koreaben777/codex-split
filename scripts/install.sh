#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if ! command -v python3 >/dev/null 2>&1; then
    echo 'python3가 필요합니다. macOS에서 xcode-select --install 완료 후 다시 실행하세요.' >&2
    exit 2
fi
exec python3 scripts/install-work.py "$@"
