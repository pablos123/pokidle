#!/usr/bin/env bash
# Lint gate: run shfmt and shellcheck over every shell source in the repo.
#
# shfmt enforces formatting (`-i 4 -ci`: four-space indent, case arms indented);
# `--diff` fails with a patch when a file is not already formatted.
# ShellCheck runs with every optional check enabled — note the flag is
# `--enable=all` (ShellCheck has no `--enable-all`; that misspelling errors out
# before scanning anything). `-x` follows `source` directives into lib/ so
# sourced files are analysed too.
#
# Both tools are required. A missing tool is a hard failure with an install
# hint, not a silent skip — a gate that quietly does nothing is worse than no
# gate. Neither short-circuits the other: both always run so a single pass
# reports every problem.
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${REPO_ROOT}"

# _require_cmd <name> <install-hint>
# Print a clear error and return 1 when <name> is not on PATH.
function _require_cmd {
    local name="$1"
    local hint="$2"
    if ! command -v "${name}" >/dev/null 2>&1; then
        printf 'lint: %s not found — install it (%s)\n' "${name}" "${hint}" >&2
        return 1
    fi
}

# Every executable/sourced shell file in the repo.
mapfile -t files < <(printf '%s\n' \
    pokidle \
    lib/*.bash \
    commands/*.bash \
    scripts/*.bash)

# Verify both tools up front so a missing one is reported before either runs.
missing=0
_require_cmd shfmt 'https://github.com/mvdan/sh' || missing=1
_require_cmd shellcheck 'https://www.shellcheck.net' || missing=1
if ((missing)); then
    exit 1
fi

# Run both regardless of the other's outcome, then aggregate.
rc=0
if ! shfmt -i 4 -ci --diff -- "${files[@]}"; then
    printf 'lint: shfmt found formatting issues (run: shfmt -i 4 -ci -w <file>)\n' >&2
    rc=1
fi
if ! shellcheck -x --enable=all -- "${files[@]}"; then
    rc=1
fi
exit "${rc}"
