#!/usr/bin/env bash
# pokeapi.bash — bash wrapper for https://pokeapi.co with filesystem caching.

set -euo pipefail

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/cache.bash
source "${LIB_DIR}/cache.bash"
# shellcheck source=lib/http.bash
source "${LIB_DIR}/http.bash"
# shellcheck source=lib/api.bash
source "${LIB_DIR}/api.bash"

function usage() {
    cat <<'EOF'
pokeapi.bash — bash wrapper for https://pokeapi.co with filesystem caching.

Usage:
  pokeapi.bash <command> [args...]

Commands:
  get <endpoint>           Raw JSON for any endpoint (e.g. pokemon/metagross)
  pokemon <name|id>        Pokemon resource JSON
  move <name|id>           Move resource JSON
  ability <name|id>        Ability resource JSON
  type <name|id>           Type resource JSON
  species <name|id>        Pokemon-species resource JSON
  item <name|id>           Item resource JSON
  nature <name|id>         Nature resource JSON

  natures                          List all nature names
  stats <pokemon>                  Base stats table (name: value)
  types <pokemon>                  Type names, one per line
  moves <pokemon>                  Move names, one per line
  id <pokemon>                     Numeric id
  name <pokemon>                   Pokemon name (id -> name)
  forms <pokemon>                  List all forms/varieties of pokemon's species
  sprite-url <pokemon> [variant]   Sprite URL (default variant: front_default)
  sprite <pokemon> [variant]       Download sprite, print cached file path

  cache-path <endpoint>    Print cache file path for endpoint
  cache-clear [endpoint]   Purge cache (all, or one endpoint)

  help, -h, --help         Show this help

Environment:
  POKEAPI_CACHE_DIR        Cache root (default: $XDG_CACHE_HOME/pokeapi)
  POKEAPI_BASE_URL         API base (default: https://pokeapi.co/api/v2)
  POKEAPI_USER_AGENT       User-Agent header (default: pokeapi-bash/0.1)
EOF
}

function main() {
    local cmd="${1-}"
    [[ -n "${cmd}" ]] || { usage >&2; return 2; }
    shift

    case "${cmd}" in
        get)            pokeapi_get "$@" ;;
        pokemon)        pokemon "$@" ;;
        move)           move "$@" ;;
        ability)        ability "$@" ;;
        type)           type_ "$@" ;;
        species)        species "$@" ;;
        item)           item "$@" ;;
        nature)         nature "$@" ;;
        natures)        natures "$@" ;;
        stats)          pokemon_stats "$@" ;;
        types)          pokemon_types "$@" ;;
        moves)          pokemon_moves "$@" ;;
        id)             pokemon_id "$@" ;;
        name)           pokemon_name "$@" ;;
        forms)          pokemon_forms "$@" ;;
        sprite-url)     pokemon_sprite_url "$@" ;;
        sprite)         pokemon_sprite "$@" ;;
        cache-clear)    cache_clear "${1-}" ;;
        cache-path)     cache_path "$@" ;;
        help|-h|--help) usage ;;
        *) printf 'unknown command: %s\n' "${cmd}" >&2; usage >&2; return 2 ;;
    esac
}

main "$@"
