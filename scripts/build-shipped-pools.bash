#!/usr/bin/env bash
# Maintainer-only: rebuild every biome pool against the live PokeAPI and
# copy the freshly-built JSON files into share/pools/ so they ship with
# the repo. End users never run this — `pokidle setup` copies the
# shipped pools into $POKIDLE_CACHE_DIR.
#
# Usage: scripts/build-shipped-pools.bash [--keep-cache]
#   --keep-cache  do not wipe $POKIDLE_CACHE_DIR/pools before rebuilding

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r REPO_ROOT

declare -i keep_cache=0
case "${1-}" in
    --keep-cache) keep_cache=1 ;;
    "") ;;
    *)
        printf 'usage: %s [--keep-cache]\n' "$0" >&2
        exit 2
        ;;
esac

declare -r CACHE_DIR="${POKIDLE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/pokidle}"
declare -r SHIP_DIR="${REPO_ROOT}/share/pools"
mkdir -p -- "${SHIP_DIR}"

if ((!keep_cache)); then
    printf 'wiping %s/pools\n' "${CACHE_DIR}"
    rm -rf -- "${CACHE_DIR}/pools"
fi

printf 'building pools (a few minutes: pool data now comes from cached GraphQL queries)\n'
"${REPO_ROOT}/pokidle" rebuild-pool --yes

printf 'copying %s/pools/*.json -> %s/\n' "${CACHE_DIR}" "${SHIP_DIR}"
cp -- "${CACHE_DIR}"/pools/*.json "${SHIP_DIR}/"

printf 'copying Showdown artifacts -> %s/\n' "${REPO_ROOT}/share"
mkdir -p -- "${REPO_ROOT}/share"
# Sort on copy so the shipped artifacts are deterministic (the builders emit in
# items.js order); keeps git diffs to real content changes across rebuilds.
sort -- "${CACHE_DIR}/showdown/items-holdable.tsv" >"${REPO_ROOT}/share/items-holdable.tsv"
sort -- "${CACHE_DIR}/showdown/form-items.tsv" >"${REPO_ROOT}/share/form-items.tsv"

shipped=("${SHIP_DIR}"/*.json)
printf 'done: %d pool(s) in %s\n' "${#shipped[@]}" "${SHIP_DIR}"
