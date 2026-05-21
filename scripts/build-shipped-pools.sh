#!/usr/bin/env bash
# Maintainer-only: rebuild every biome pool against the live PokeAPI and
# copy the freshly-built JSON files into share/pools/ so they ship with
# the repo. End users never run this — `pokidle setup` copies the
# shipped pools into $POKIDLE_CACHE_DIR.
#
# Usage: scripts/build-shipped-pools.sh [--keep-cache]
#   --keep-cache  do not wipe $POKIDLE_CACHE_DIR/pools before rebuilding

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
keep_cache=0
case "${1-}" in
    --keep-cache) keep_cache=1 ;;
    "") ;;
    *) printf 'usage: %s [--keep-cache]\n' "$0" >&2; exit 2 ;;
esac

cache_dir="${POKIDLE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pokidle}"
ship_dir="$REPO_ROOT/share/pools"
mkdir -p -- "$ship_dir"

if (( ! keep_cache )); then
    printf 'wiping %s/pools\n' "$cache_dir"
    rm -rf -- "$cache_dir/pools"
fi

printf 'building pools (this can take ~2 hours due to PokeAPI rate-limit sleep)\n'
"$REPO_ROOT/pokidle" rebuild-pool --yes

printf 'copying %s/pools/*.json -> %s/\n' "$cache_dir" "$ship_dir"
cp -- "$cache_dir"/pools/*.json "$ship_dir/"

printf 'done: %d pool(s) in %s\n' "$(ls "$ship_dir"/*.json | wc -l)" "$ship_dir"
