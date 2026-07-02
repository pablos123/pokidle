#!/usr/bin/env bash
# Public API: cache-aware fetchers and resource helpers.

# pokeapi_get <endpoint>
# Print endpoint JSON from cache, or fetch, cache, then print it. Returns 1
# on fetch failure.
function pokeapi_get {
    local endpoint="$1"
    if cache_has "${endpoint}"; then
        cache_get "${endpoint}"
        return 0
    fi
    local body
    if ! body="$(http_get "${endpoint}")"; then
        return 1
    fi
    printf '%s' "${body}" | cache_put "${endpoint}"
    cache_get "${endpoint}"
}

# pokeapi_graphql <cache-key> <query>
# Print the JSON response for a GraphQL <query>, cached on disk under
# "graphql/<cache-key>" (permanent, like the REST cache). Serves the cache when
# present; otherwise runs the query, caches, and prints it. Returns 1 only when
# the query fails and nothing is cached. <cache-key> names the query's purpose,
# so distinct queries must use distinct keys; reuse this for any future query.
function pokeapi_graphql {
    local key="graphql/$1"
    local query="$2"
    if cache_has "${key}"; then
        cache_get "${key}"
        return 0
    fi
    local body
    if ! body="$(http_graphql "${query}")"; then
        return 1
    fi
    printf '%s' "${body}" | cache_put "${key}"
    cache_get "${key}"
}

# Resource fetchers: each takes <name-or-id> and prints the raw endpoint JSON.
function pokemon { pokeapi_get "pokemon/$1"; }
function move { pokeapi_get "move/$1"; }
function ability { pokeapi_get "ability/$1"; }
function type_ { pokeapi_get "type/$1"; }
function species { pokeapi_get "pokemon-species/$1"; }
function item { pokeapi_get "item/$1"; }
function nature { pokeapi_get "nature/$1"; }

# natures
# Print all nature names, one per line.
function natures { pokeapi_get "nature?limit=100" | jq -r '.results[].name'; }

# Field extractors: each takes <name-or-id> and prints the named field(s).
function pokemon_types { pokemon "$1" | jq -r '.types[].type.name'; }
function pokemon_stats { pokemon "$1" | jq -r '.stats[] | "\(.stat.name): \(.base_stat)"'; }
function pokemon_moves { pokemon "$1" | jq -r '.moves[].move.name'; }
function pokemon_id { pokemon "$1" | jq -r '.id'; }
function pokemon_name { pokemon "$1" | jq -r '.name'; }

# pokemon_forms <name-or-id>
# Print every variety (form) name in the species, one per line. Accepts either
# a species key or a pokemon key; returns 1 if neither resolves.
function pokemon_forms {
    local key="$1"
    local sp_json
    if sp_json="$(species "${key}" 2>/dev/null)"; then
        printf '%s' "${sp_json}" | jq -r '.varieties[].pokemon.name'
        return
    fi
    local sp
    if ! sp="$(pokemon "${key}" | jq -r '.species.name')"; then
        return 1
    fi
    species "${sp}" | jq -r '.varieties[].pokemon.name'
}

# pokemon_sprite_url <name> [variant=front_default]
# Print the sprite URL for variant; return 1 if that variant has no sprite.
function pokemon_sprite_url {
    local name="$1"
    local variant="${2:-front_default}"
    local url
    url="$(pokemon "${name}" | jq -r --arg v "${variant}" '.sprites[$v] // empty')"
    if [[ -z "${url}" ]]; then
        printf 'pokemon_sprite_url: no sprite "%s" for %s\n' "${variant}" "${name}" >&2
        return 1
    fi
    printf '%s' "${url}"
}

# pokemon_sprite <name> [variant=front_default]
# Download the sprite (if not already cached) and print its local path.
# Returns 1 if the sprite URL or download fails.
function pokemon_sprite {
    local name="$1"
    local variant="${2:-front_default}"
    local url
    if ! url="$(pokemon_sprite_url "${name}" "${variant}")"; then
        return 1
    fi
    local ext="${url##*.}"
    if [[ ! "${ext}" =~ ^[a-zA-Z0-9]{1,5}$ ]]; then
        ext=png
    fi
    local path
    path="$(cache_blob_path "sprites/${name}-${variant}" "${ext}")"
    if [[ ! -f "${path}" ]]; then
        if ! http_download_url "${url}" "${path}"; then
            return 1
        fi
    fi
    printf '%s\n' "${path}"
}

# item_sprite_url <name>
# Print the default sprite URL for an item; return 1 if it has none.
function item_sprite_url {
    local name="$1"
    local url
    url="$(item "${name}" | jq -r '.sprites.default // empty')"
    if [[ -z "${url}" ]]; then
        printf 'item_sprite_url: no sprite for %s\n' "${name}" >&2
        return 1
    fi
    printf '%s' "${url}"
}

# item_sprite <name>
# Download the item sprite (if not already cached) and print its local path.
# Returns 1 if the sprite URL or download fails.
function item_sprite {
    local name="$1"
    local url
    if ! url="$(item_sprite_url "${name}")"; then
        return 1
    fi
    local ext="${url##*.}"
    if [[ ! "${ext}" =~ ^[a-zA-Z0-9]{1,5}$ ]]; then
        ext=png
    fi
    local path
    path="$(cache_blob_path "sprites/items/${name}" "${ext}")"
    if [[ ! -f "${path}" ]]; then
        if ! http_download_url "${url}" "${path}"; then
            return 1
        fi
    fi
    printf '%s\n' "${path}"
}

# _pokeapi_cli_usage
# Print the `pokidle pokeapi` subcommand help.
function _pokeapi_cli_usage {
    cat <<'EOF'
pokidle pokeapi — cached wrapper over https://pokeapi.co.

Usage:
  pokidle pokeapi <command> [args...]

Commands:
  get <endpoint>           Raw JSON for any endpoint (e.g. pokemon/metagross)
  pokemon <name|id>        Pokemon resource JSON
  move <name|id>           Move resource JSON
  ability <name|id>        Ability resource JSON
  type <name|id>           Type resource JSON
  species <name|id>        Pokemon-species resource JSON
  item <name|id>           Item resource JSON
  nature <name|id>         Nature resource JSON
  natures                  List all nature names
  stats <pokemon>          Base stats table (name: value)
  types <pokemon>          Type names, one per line
  moves <pokemon>          Move names, one per line
  id <pokemon>             Numeric id
  name <pokemon>           Pokemon name (id -> name)
  forms <pokemon>          List all forms/varieties of pokemon's species
  sprite-url <pokemon> [variant]   Sprite URL (default variant: front_default)
  sprite <pokemon> [variant]       Download sprite, print cached file path
  cache-path <endpoint>    Print cache file path for endpoint
  cache-clear [endpoint]   Purge cache (all, or one endpoint)
  help, -h, --help         Show this help
EOF
}

# pokeapi_cli [args...]
# Dispatch for the `pokidle pokeapi` subcommand: a thin wrapper over the cached
# PokeAPI helpers. Returns 2 on a missing or unknown command.
function pokeapi_cli {
    local cmd="${1-}"
    if [[ -z "${cmd}" ]]; then
        _pokeapi_cli_usage >&2
        return 2
    fi
    shift
    case "${cmd}" in
        get) pokeapi_get "$@" ;;
        pokemon) pokemon "$@" ;;
        move) move "$@" ;;
        ability) ability "$@" ;;
        type) type_ "$@" ;;
        species) species "$@" ;;
        item) item "$@" ;;
        nature) nature "$@" ;;
        natures) natures "$@" ;;
        stats) pokemon_stats "$@" ;;
        types) pokemon_types "$@" ;;
        moves) pokemon_moves "$@" ;;
        id) pokemon_id "$@" ;;
        name) pokemon_name "$@" ;;
        forms) pokemon_forms "$@" ;;
        sprite-url) pokemon_sprite_url "$@" ;;
        sprite) pokemon_sprite "$@" ;;
        cache-clear) cache_clear "${1-}" ;;
        cache-path) cache_path "$@" ;;
        help | -h | --help) _pokeapi_cli_usage ;;
        *)
            printf 'unknown command: %s\n' "${cmd}" >&2
            _pokeapi_cli_usage >&2
            return 2
            ;;
    esac
}
