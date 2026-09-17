#!/usr/bin/env bash
# Test runner: bats over tests/, one job per CPU when GNU parallel is available
# (bats needs it for --jobs; without it the suite runs serially, ~4x slower).
# Extra arguments pass through to bats (a file, --filter, --timing, …).
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${REPO_ROOT}"

if ! command -v bats >/dev/null 2>&1; then
    printf 'test: bats not found — install it (apt install bats)\n' >&2
    exit 1
fi

jobs_args=()
if command -v parallel >/dev/null 2>&1; then
    jobs_args=(--jobs "$(nproc)")
fi

if (($# == 0)); then
    set -- tests/
fi
exec bats "${jobs_args[@]}" "$@"
