#!/usr/bin/env bash
# `pokidle switch-biome` — close the active session and open a new one.

# pokidle_switch_biome_help
# Print the `pokidle switch-biome` subcommand help.
function pokidle_switch_biome_help {
    cat <<'EOF'
pokidle switch-biome — close the active biome session and open a new one.

Usage:
  pokidle switch-biome <biome>

<biome> must be one of the catalog ids (see `pokidle biomes`).

Options:
  -h, --help    Show this help
EOF
}

# pokidle_switch_biome <biome>
# Close the active session and open a new one in <biome>. Returns 2 on a
# missing or unknown biome.
function pokidle_switch_biome {
    case "${1-}" in
        -h | --help | help)
            pokidle_switch_biome_help
            return 0
            ;;
        *) ;;
    esac
    local biome="${1-}"
    if [[ -z "${biome}" ]]; then
        printf 'switch-biome: missing biome id\n' >&2
        return 2
    fi
    if [[ "${biome}" == -* ]]; then
        printf 'switch-biome: unknown option %s\n' "${biome}" >&2
        return 2
    fi
    if ! biome_exists "${biome}"; then
        printf 'switch-biome: unknown biome %s\n' "${biome}" >&2
        return 2
    fi
    db_init
    local active
    active="$(db_active_biome_session)"
    if [[ -n "${active}" ]]; then
        local sid
        IFS=$'\t' read -r sid _ _ <<<"${active}"
        db_close_biome_session "${sid}" "$(date +%s)"
    fi
    local new_sid
    new_sid="$(db_open_biome_session "${biome}" "$(date +%s)")"
    printf 'switched to %s (session %s)\n' "$(_pokidle_biome_display "${biome}")" "${new_sid}"
}
