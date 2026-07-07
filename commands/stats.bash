#!/usr/bin/env bash
# `pokidle stats` — aggregate encounter statistics.

# pokidle_stats_help
# Print the `pokidle stats` subcommand help.
function pokidle_stats_help {
    cat <<'EOF'
pokidle stats — aggregate statistics over all recorded encounters.

Usage:
  pokidle stats

Prints total encounters, shiny count and rate, per-biome counts, and the
top species. Takes no options.

Options:
  -h, --help    Show this help
EOF
}

# pokidle_stats
# Print aggregate stats: total encounters, shinies (with rate), per-biome
# counts, and the top species.
function pokidle_stats {
    case "${1-}" in
        -h | --help | help)
            pokidle_stats_help
            return 0
            ;;
        "") ;;
        -*)
            _pokidle_usage_error pokidle_stats_help 'stats: unknown option %s' "$1"
            return
            ;;
        *)
            _pokidle_usage_error pokidle_stats_help 'stats: unexpected argument %s' "$1"
            return
            ;;
    esac
    db_init
    local total
    total="$(db_query "SELECT COUNT(*) FROM encounters;")"
    local shinies
    shinies="$(db_query "SELECT COUNT(*) FROM encounters WHERE shiny=1;")"
    printf 'Total encounters:  %s\n' "${total}"
    printf 'Shinies:           %s' "${shinies}"
    if [[ "${shinies}" != "0" && "${total}" != "0" ]]; then
        printf '   (1 / %.1f)' "$(awk -v t="${total}" -v s="${shinies}" 'BEGIN { printf "%.1f", t/s }')"
    fi
    printf '\n\nBy biome:\n'
    # biome_id -> label and species slug -> Showdown display name happen in bash
    # (awk can't call them), keeping the same aligned columns.
    local biome_id count shiny
    while IFS=$'\t' read -r biome_id count shiny; do
        [[ -z "${biome_id}" ]] && continue
        printf '  %-16s %5d   (%d shiny)\n' "$(_pokidle_biome_display "${biome_id}")" "${count}" "${shiny}"
    done < <(db_query "SELECT s.biome_id, COUNT(*), SUM(e.shiny)
              FROM encounters e JOIN biome_sessions s ON s.id=e.session_id
              GROUP BY s.biome_id ORDER BY 2 DESC;")
    printf '\nTop species:\n'
    local species scount
    while IFS=$'\t' read -r species scount; do
        [[ -z "${species}" ]] && continue
        printf '  %-16s %5d\n' "$(species_display_name "${species}")" "${scount}"
    done < <(db_query "SELECT species, COUNT(*) FROM encounters
              GROUP BY species ORDER BY 2 DESC LIMIT 10;")
}
