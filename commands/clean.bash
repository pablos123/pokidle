#!/usr/bin/env bash
# `pokidle clean` — wipe caches and/or the database.
# shellcheck disable=SC2154  # POKIDLE_*/POKIDLE_POKEAPI_* dirs come from the entrypoint + libs

# pokidle_clean_help
# Print the `pokidle clean` subcommand help.
function pokidle_clean_help {
    cat <<'EOF'
pokidle clean — wipe caches and/or the database.

Usage:
  pokidle clean <pools|db|showdown|pokeapi|all> [--yes]

Targets:
  pools       Wipe the pool cache.
  db          Wipe the sqlite database.
  showdown    Wipe the Showdown cache.
  pokeapi     Wipe the PokeAPI cache.
  all         Wipe pools + showdown + pokeapi + the database.

Options:
  --yes, -y     Skip the confirmation prompt.
  -h, --help    Show this help
EOF
}

function pokidle_clean {
    local -i force=0
    local target=""
    while (($# > 0)); do
        case "$1" in
            --yes | -y)
                force=1
                shift
                ;;
            -h | --help | help)
                pokidle_clean_help
                return 0
                ;;
            pools | db | showdown | pokeapi | all)
                target="$1"
                shift
                ;;
            -*)
                _pokidle_usage_error pokidle_clean_help 'clean: unknown option %s' "$1"
                return
                ;;
            *)
                _pokidle_usage_error pokidle_clean_help 'clean: unknown target %s' "$1"
                return
                ;;
        esac
    done
    if [[ -z "${target}" ]]; then
        printf 'usage: pokidle clean <pools|db|showdown|pokeapi|all> [--yes]\n' >&2
        return 2
    fi

    local prompt
    case "${target}" in
        pools) prompt="Wipe ${POKIDLE_CACHE_DIR}/pools?" ;;
        db) prompt="Wipe ${POKIDLE_DB_PATH}?" ;;
        showdown) prompt="Wipe ${POKIDLE_SHOWDOWN_CACHE_DIR}?" ;;
        pokeapi) prompt="Wipe ${POKIDLE_POKEAPI_CACHE_DIR}?" ;;
        all) prompt="Wipe pools, ${POKIDLE_SHOWDOWN_CACHE_DIR}, ${POKIDLE_POKEAPI_CACHE_DIR} AND ${POKIDLE_DB_PATH}?" ;;
        *) ;;
    esac

    if ((!force)); then
        printf '%s [y/N] ' "${prompt}"
        local ans
        read -r ans
        if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
            printf 'aborted\n'
            return 0
        fi
    fi

    case "${target}" in
        pools)
            rm -rf -- "${POKIDLE_CACHE_DIR}/pools"
            printf 'cleaned: pools/\n'
            ;;
        db)
            rm -f -- "${POKIDLE_DB_PATH}"
            printf 'cleaned: %s\n' "${POKIDLE_DB_PATH}"
            ;;
        showdown)
            rm -rf -- "${POKIDLE_SHOWDOWN_CACHE_DIR}"
            printf 'cleaned: %s\n' "${POKIDLE_SHOWDOWN_CACHE_DIR}"
            ;;
        pokeapi)
            rm -rf -- "${POKIDLE_POKEAPI_CACHE_DIR}"
            printf 'cleaned: %s\n' "${POKIDLE_POKEAPI_CACHE_DIR}"
            ;;
        all)
            rm -rf -- "${POKIDLE_CACHE_DIR}/pools" "${POKIDLE_SHOWDOWN_CACHE_DIR}" "${POKIDLE_POKEAPI_CACHE_DIR}"
            rm -f -- "${POKIDLE_DB_PATH}"
            printf 'cleaned: pools/ + showdown + pokeapi + %s\n' "${POKIDLE_DB_PATH}"
            ;;
        *) ;;
    esac
}
