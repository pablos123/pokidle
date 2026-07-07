#!/usr/bin/env bash
# `pokidle current` — active biome summary and candidate drop/encounter pools.

# pokidle_current_help
# Print the `pokidle current` subcommand help.
function pokidle_current_help {
    cat <<'EOF'
pokidle current — active biome status.

Usage:
  pokidle current [items|berries|encounters] [--no-images]

Bare: active biome, time remaining, session + all-time counts, with the biome
image above it.

Modes:
  items         Candidate item drops (excludes berries).
  berries       Candidate berry drops for the biome.
  encounters    Candidate species, grouped by tier.

Options:
  --no-images   Skip the biome image (summary only).
  -h, --help    Show this help
EOF
}

# pokidle_current [items|berries|encounters] [--no-images]
# Bare: active biome, time remaining, this-session and all-time counts, with the
#   biome image rendered above the summary (suppress with --no-images).
# items: candidate item drops for the active biome, berries excluded (one slug
#   per line).
# berries: candidate berry drops for the active biome (one slug per line).
# encounters: candidate species grouped by tier; lines like "audino (L5-15)".
function pokidle_current {
    db_init
    local mode="summary"
    local -i no_images=0
    local -i kind_set=0
    while (($# > 0)); do
        case "$1" in
            --no-images)
                no_images=1
                shift
                ;;
            -h | --help | help)
                pokidle_current_help
                return 0
                ;;
            -*)
                _pokidle_usage_error pokidle_current_help 'current: unknown option %s' "$1"
                return
                ;;
            items | berries | encounters)
                if ((kind_set)); then
                    _pokidle_usage_error pokidle_current_help 'current: only one of items|berries|encounters'
                    return
                fi
                mode="$1"
                kind_set=1
                shift
                ;;
            *)
                _pokidle_usage_error pokidle_current_help 'current: unknown subcommand %s (want items|berries|encounters)' "$1"
                return
                ;;
        esac
    done

    local row
    row="$(db_active_biome_session)"
    if [[ -z "${row}" ]]; then
        printf 'no active biome\n'
        return 0
    fi
    local id
    local biome
    local started_at
    IFS=$'\t' read -r id biome started_at <<<"${row}"

    case "${mode}" in
        items)
            _pokidle_current_items "${biome}"
            ;;
        berries)
            _pokidle_current_berries "${biome}"
            ;;
        encounters)
            _pokidle_current_encounters "${biome}"
            ;;
        summary)
            _pokidle_current_summary "${id}" "${biome}" "${started_at}" "${no_images}"
            ;;
        *)
            printf 'current: unknown mode %s\n' "${mode}" >&2
            return 2
            ;;
    esac
}

# _pokidle_biome_time_left <started_at> <now>
# Print the active session's time-left until rotation as "<N>s", floored at zero.
# A session that has outlived POKIDLE_BIOME_HOURS — e.g. left open across a long
# shutdown, before the daemon rotates it on its next loop — would otherwise print
# a negative figure, so report "0s (rotation pending)" instead.
function _pokidle_biome_time_left {
    local -i started_at="$1"
    local -i now="$2"
    local -i remaining=$((${POKIDLE_BIOME_HOURS:-3} * 3600 - (now - started_at)))
    if ((remaining <= 0)); then
        printf '0s (rotation pending)'
        return
    fi
    printf '%ds' "${remaining}"
}

# _pokidle_current_summary <session_id> <biome> <started_at> [no_images]
# Print the active-biome summary: biome name, session id, pool/item-pool sizes,
# start time, time remaining, and session encounter/item counts. Unless
# no_images is 1, the biome image is rendered as a column to the right.
function _pokidle_current_summary {
    local id="$1"
    local biome="$2"
    local started_at="$3"
    local -i no_images="${4:-0}"
    local now
    now="$(date +%s)"
    local -i poss_enc=0
    local pool
    if pool="$(encounter_pool_load "${biome}" 2>/dev/null)"; then
        poss_enc="$(jq '[.tiers[] | length] | add // 0' <<<"${pool}")"
    fi
    # Item pool counts: berries and non-berry items reported separately so
    # the two figures don't double-count. Reuse the pool loaded above.
    local pool_json="${pool}"
    [[ -z "${pool_json}" ]] && pool_json='{}'
    local -i poss_item poss_berry
    poss_item="$(jq -r '(.items // []) | length' <<<"${pool_json}")"
    poss_berry="$(jq -r '(.berries // []) | length' <<<"${pool_json}")"
    local enc_count
    enc_count="$(db_query "SELECT COUNT(*) FROM encounters WHERE session_id=${id};")"
    local item_count
    item_count="$(db_query "SELECT COUNT(*) FROM item_drops WHERE session_id=${id};")"
    local -a btypes=()
    mapfile -t btypes < <(biome_types_for "${biome}" 2>/dev/null)
    local types_csv=""
    if ((${#btypes[@]} > 0)); then
        printf -v types_csv '%s, ' "${btypes[@]}"
        types_csv="${types_csv%, }"
    fi
    # Biome image above the summary, rendered with the same chafa call the
    # encounters/items lists use (native terminal graphics when available).
    # Padded with blank lines so it stands clear of the surrounding text — but
    # only when an image will actually render, so the text-only summary keeps
    # its tight layout.
    if ((!no_images)); then
        local icon
        icon="$(_biome_icon_path "${biome}")"
        if [[ -n "${icon}" ]] && command -v chafa >/dev/null; then
            printf '\n'
            _pokidle_render_sprite "${icon}"
            printf '\n'
        fi
    fi
    printf 'Active biome: %s  (session #%s)\n' "$(_pokidle_biome_display "${biome}")" "${id}"
    printf 'Types: %s\n' "${types_csv}"
    printf 'Possible encounters: %s   Possible items: %s   Berries: %s\n' "${poss_enc}" "${poss_item}" "${poss_berry}"
    printf 'Started: %s\n' "$(date -d "@${started_at}")"
    printf 'Time remaining: %s\n' "$(_pokidle_biome_time_left "${started_at}" "${now}")"
    printf 'Encounters: %s   Items: %s\n' "${enc_count}" "${item_count}"
}

# _pokidle_current_items <biome>
# Print the item drop pool for biome, berries excluded (they are listed by
# _pokidle_current_berries), alphabetical, one slug per line.
function _pokidle_current_items {
    local biome="$1"
    encounter_pool_load "${biome}" 2>/dev/null | jq -r '(.items // [])[]' | LC_ALL=C sort -u
}

# _pokidle_current_berries <biome>
# Print the berry drops for biome — item-pool slugs ending in -berry —
# alphabetical, one slug per line.
function _pokidle_current_berries {
    local biome="$1"
    # Pool berries are stored bare; drops carry the "-berry" item slug (see
    # encounter_roll_item), so show that slug here to match what the tick logs.
    encounter_pool_load "${biome}" 2>/dev/null |
        jq -r '(.berries // [])[] | . + "-berry"' | LC_ALL=C sort -u
}

# _pokidle_current_encounters <biome>
# Print the encounter pool for biome, grouped by tier (common, uncommon, rare,
# very_rare). Empty tiers are skipped. Each entry's qualifying forms
# (varieties[], e.g. meowth-galar in a steel biome) are listed by their form
# name. Sorted by displayed name within each tier.
function _pokidle_current_encounters {
    local biome="$1"
    local pool
    if ! pool="$(encounter_pool_load "${biome}")"; then
        return 1
    fi
    local US=$'\037'
    local -i first=1
    local tier
    for tier in common uncommon rare very_rare; do
        # jq emits name<US>min<US>max per qualifying form, still sorted by slug;
        # the bash loop prettifies each name to its Showdown display name.
        local rows
        rows="$(jq -r --arg t "${tier}" --arg US "${US}" '
            [ .tiers[$t][]? as $e | $e.varieties[] | {name: ., min: $e.min, max: $e.max} ]
            | sort_by(.name) | .[] | [.name, (.min | tostring), (.max | tostring)] | join($US)' \
            <<<"${pool}")"
        if [[ -z "${rows}" ]]; then
            continue
        fi
        if ((!first)); then
            printf '\n'
        fi
        printf '%s:\n' "${tier}"
        local name min max
        while IFS="${US}" read -r name min max; do
            printf '  %s (L%s-%s)\n' "$(species_display_name "${name}")" "${min}" "${max}"
        done <<<"${rows}"
        first=0
    done
}
