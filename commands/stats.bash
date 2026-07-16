#!/usr/bin/env bash
# `pokidle stats` — aggregate encounter statistics.

# pokidle_stats_help
# Print the `pokidle stats` subcommand help.
function pokidle_stats_help {
    cat <<'EOF'
pokidle stats — aggregate statistics over recorded encounters and item drops.

Usage:
  pokidle stats [options]

Prints total encounters, shiny count and rate, legendary count, per-biome
counts, the top species, and item-drop totals. Accepts the same filters as
`pokidle encounters` to scope the aggregates.

Options:
  --shiny                Only shiny encounters
  --legendary             Only legendary encounters
  --since DATE            Only encounters/items on or after DATE
  --until DATE            Only encounters/items on or before DATE
  --biome ID              Only encounters/items from biome ID
  --species NAME          Only encounters matching NAME (substring)
  --nature NAME           Only encounters with nature NAME
  --min-iv-total N        Only encounters with IV total >= N
  --max-iv-total N        Only encounters with IV total <= N
  --ability SLUG          Only encounters with ability SLUG
  --gender M|F|genderless Only encounters with the given gender
  --move SLUG             Only encounters that know move SLUG
  --berry SLUG            Only encounters holding berry SLUG
  --min-level N           Only encounters with level >= N
  --max-level N           Only encounters with level <= N
  --json                  Emit the aggregates as JSON instead of text
  -h, --help              Show this help
EOF
}

# pokidle_stats [options]
# Print aggregate stats over encounters (optionally filtered) and item drops:
# total encounters, shinies (with rate), legendaries, per-biome counts, the
# top species, and item-drop totals. Filters mirror `pokidle encounters`;
# --since/--until/--biome also scope the item-drop aggregate. --json emits
# the same aggregate object as machine-readable JSON.
function pokidle_stats {
    db_init
    local -i json_mode=0
    local -a enc_args=()
    local -a item_args=()
    while (($# > 0)); do
        case "$1" in
            -h | --help | help)
                pokidle_stats_help
                return 0
                ;;
            --json)
                json_mode=1
                shift
                ;;
            --since | --until | --biome)
                # Shared with item drops: forward to both engines.
                enc_args+=("$1" "$2")
                item_args+=("$1" "$2")
                shift 2
                ;;
            *)
                # Everything else (encounter-only filters) goes to the list engine,
                # which validates it.
                enc_args+=("$1")
                shift
                ;;
        esac
    done

    local rows rc=0
    local _db_list_errctx="stats"
    rows="$(db_list_encounters "${enc_args[@]}" --limit 1000000)" || rc=$?
    if ((rc != 0)); then
        # shellcheck disable=SC2154
        ((rc == POKIDLE_RC_USAGE)) && {
            pokidle_stats_help >&2
            return 2
        }
        return "${rc}"
    fi
    # sqlite3 -json prints nothing (not "[]") for an empty result set; normalize
    # so --argjson below always receives valid JSON.
    [[ -z "${rows}" ]] && rows="[]"
    local idrops
    idrops="$(db_list_item_drops "${item_args[@]}" --include-consumed --limit 1000000)"
    [[ -z "${idrops}" ]] && idrops="[]"

    # Aggregate object built once; both the text and --json paths read from it.
    local agg
    agg="$(jq -c -n --argjson e "${rows}" --argjson d "${idrops}" '
        ($e | length) as $total
        | ($e | map(select(.shiny==1)) | length) as $shinies
        | ($e | map(select(.is_legendary==1)) | length) as $legendaries
        | {
            total: $total,
            shinies: $shinies,
            shiny_rate: (if $shinies>0 and $total>0 then ($total/$shinies) else null end),
            legendaries: $legendaries,
            by_biome: ($e | group_by(.biome_id) | map({
                biome: .[0].biome_id, count: length,
                shiny: (map(select(.shiny==1)) | length)
            }) | sort_by(-.count)),
            top_species: ($e | group_by(.species) | map({
                species: .[0].species, count: length
            }) | sort_by(-.count) | .[0:10]),
            items: {
                total: ($d | length),
                item: ($d | map(select(.kind=="item")) | length),
                pickup: ($d | map(select(.kind=="pickup")) | length),
                consumed: ($d | map(select(.consumed_at != null)) | length)
            }
        }')"

    if ((json_mode)); then
        printf '%s\n' "${agg}"
        return 0
    fi

    # Text render: scalars + tables. biome/species display names resolve in bash.
    local total shinies legendaries
    total="$(jq -r '.total' <<<"${agg}")"
    shinies="$(jq -r '.shinies' <<<"${agg}")"
    legendaries="$(jq -r '.legendaries' <<<"${agg}")"
    printf 'Total encounters:  %s\n' "${total}"
    printf 'Shinies:           %s' "${shinies}"
    if [[ "${shinies}" != "0" && "${total}" != "0" ]]; then
        printf '   (1 / %.1f)' "$(jq -r '.shiny_rate' <<<"${agg}")"
    fi
    printf '\n'
    printf 'Legendaries:       %s\n' "${legendaries}"
    printf '\nBy biome:\n'
    local biome_id count shiny
    while IFS=$'\t' read -r biome_id count shiny; do
        [[ -z "${biome_id}" ]] && continue
        printf '  %-16s %5d   (%d shiny)\n' "$(_pokidle_biome_display "${biome_id}")" "${count}" "${shiny}"
    done < <(jq -r '.by_biome[] | [.biome, .count, .shiny] | @tsv' <<<"${agg}")
    printf '\nTop species:\n'
    local species scount
    while IFS=$'\t' read -r species scount; do
        [[ -z "${species}" ]] && continue
        printf '  %-16s %5d\n' "$(species_display_name "${species}")" "${scount}"
    done < <(jq -r '.top_species[] | [.species, .count] | @tsv' <<<"${agg}")
    printf '\nItem drops:\n'
    printf '  %-16s %5d   (%d held, %d pickup, %d consumed)\n' "total" \
        "$(jq -r '.items.total' <<<"${agg}")" \
        "$(jq -r '.items.item' <<<"${agg}")" \
        "$(jq -r '.items.pickup' <<<"${agg}")" \
        "$(jq -r '.items.consumed' <<<"${agg}")"
}
