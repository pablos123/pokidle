#!/usr/bin/env bash
# `pokidle export` — random Pokémon Showdown team from stored encounters.

# pokidle_export_help
# Print the `pokidle export` subcommand help.
function pokidle_export_help {
    cat <<'EOF'
pokidle export — build a random Pokémon Showdown team (up to 6 species) from
stored encounters. Default window: current ISO week (--since/--until to
override). Same options as `encounters`.

Usage:
  pokidle export [options]

Options:
  --force-level N   Set every mon's level to N
  --force-perfect   31 IVs across the board
  --force-mega      Pull mons you hold a mega stone for first
  --force-z         Pull mons you hold a Z-crystal for first
  --force-legendary Pull legendary/mythical mons first
  --force-evolved   Prefer mons you hold in a more-evolved form
  --force-shiny     Pull species you own a shiny of first
  --force-hidden    Pull species you own a hidden-ability form of first
  --force-nature    Set every mon's nature (one of the 25)
  --force-best-ivs  Prefer higher total-IV mons when filling the team
  -h, --help        Show this help
EOF
}

# _export_valid_nature <name>
# True (exit 0) when <name> is one of the 25 canonical natures (lowercase slug).
# Static list keeps the export path offline — the roller's network nature list
# is not consulted here.
function _export_valid_nature {
    case "$1" in
        hardy | lonely | brave | adamant | naughty | bold | docile | relaxed | impish | lax | \
            timid | hasty | serious | jolly | naive | modest | mild | quiet | bashful | rash | \
            calm | gentle | sassy | careful | quirky)
            return 0
            ;;
        *) return 1 ;;
    esac
}

# _export_mark_forced <rows_json> <jq_predicate> <forced_array_nameref>
# Append the species (deduped against what's already there) whose rows match the
# jq predicate to the pull-first forced set. Predicate is a trusted literal.
function _export_mark_forced {
    local rows="$1"
    local pred="$2"
    local -n _forced="$3"
    local -a cand=()
    mapfile -t cand < <(jq -r "[.[] | select(${pred}) | .species] | unique | .[]" <<<"${rows}")
    local c
    for c in "${cand[@]}"; do
        [[ " ${_forced[*]} " == *" ${c} "* ]] && continue
        _forced+=("${c}")
    done
}

# _export_sort_by_iv_desc <array_nameref>
# Reorder the named species array by best available summed-IV-total, descending.
# Reads the caller-scoped `best_iv` assoc (species -> best IV total). Ties keep
# sort(1)'s order; that's fine — the caller only needs highest-first.
function _export_sort_by_iv_desc {
    local -n _sortarr="$1"
    ((${#_sortarr[@]} == 0)) && return 0
    local -a sorted=()
    local x
    mapfile -t sorted < <(
        for x in "${_sortarr[@]}"; do
            printf '%s\t%s\n' "${best_iv[${x}]:-0}" "${x}"
        done | sort -rn -k1,1 | cut -f2
    )
    _sortarr=("${sorted[@]}")
}

# _pokidle_shuffle <array_name>
# Fisher-Yates shuffle of a named array, in place, using $RANDOM.
function _pokidle_shuffle {
    local -n _arr="$1"
    local -i i
    local -i j
    local tmp
    for ((i = ${#_arr[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp="${_arr[i]}"
        _arr[i]="${_arr[j]}"
        _arr[j]="${tmp}"
    done
}

# pokidle_export [options...]
# Print a random Pokémon Showdown team built from stored encounters.
# Picks up to 6 distinct species within a window (default: current ISO week,
# overridable via --since/--until), one random encounter per species. Encounters
# are born legal (abilities, moves, IVs, EVs rolled at capture time), so no
# move-trimming or event-only filtering is needed here. Held items are drawn from
# item_drops in the same window — distinct across the team — with each mon's own
# berry as one additional candidate. Only items Showdown accepts are assigned (the
# one legality filter applied at export). Other list options
# (--shiny/--species/--biome/--nature/--min-iv-total) constrain the encounter
# pool.
function pokidle_export {
    db_init
    local _db_list_errctx="export"
    local -a filters=()
    local since_ts=""
    local until_ts=""
    local force_level=""
    local -i force_perfect=0
    local -i force_mega=0
    local -i force_z=0
    local -i force_legendary=0
    local -i force_evolved=0
    local -i force_shiny=0
    local -i force_hidden=0
    local force_nature=""
    local -i force_best_ivs=0
    while (($# > 0)); do
        case "$1" in
            --force-level)
                force_level="$2"
                if ! [[ "${force_level}" =~ ^[0-9]+$ ]]; then
                    _pokidle_usage_error pokidle_export_help 'export: --force-level needs an integer'
                    return
                fi
                shift 2
                ;;
            --force-perfect)
                force_perfect=1
                shift
                ;;
            --force-mega)
                force_mega=1
                shift
                ;;
            --force-z)
                force_z=1
                shift
                ;;
            --force-legendary)
                force_legendary=1
                shift
                ;;
            --force-evolved)
                force_evolved=1
                shift
                ;;
            --force-shiny)
                force_shiny=1
                shift
                ;;
            --force-hidden)
                force_hidden=1
                shift
                ;;
            --force-best-ivs)
                force_best_ivs=1
                shift
                ;;
            --force-nature)
                force_nature="$2"
                if ! _export_valid_nature "${force_nature}"; then
                    _pokidle_usage_error pokidle_export_help 'export: --force-nature: unknown nature'
                    return
                fi
                shift 2
                ;;
            --since)
                if ! since_ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                shift 2
                ;;
            --until)
                if ! until_ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                shift 2
                ;;
            -h | --help | help)
                pokidle_export_help
                return 0
                ;;
            *)
                filters+=("$1")
                shift
                ;;
        esac
    done

    # Default window = current ISO week (Mon 00:00 .. Sun 23:59:59) when the
    # caller gave neither bound.
    if [[ -z "${since_ts}" && -z "${until_ts}" ]]; then
        local dow
        dow="$(date +%u)"
        since_ts="$(date -d "$((dow - 1)) days ago $(date +%F) 00:00:00" +%s)"
        until_ts=$((since_ts + 7 * 86400 - 1))
    fi

    local -a enc_args=("${filters[@]}" --limit 1000)
    if [[ -n "${since_ts}" ]]; then
        enc_args+=(--since "@${since_ts}")
    fi
    if [[ -n "${until_ts}" ]]; then
        enc_args+=(--until "@${until_ts}")
    fi
    local rows rc=0
    rows="$(db_list_encounters "${enc_args[@]}")" || rc=$?
    if ((rc != 0)); then
        # shellcheck disable=SC2154  # POKIDLE_RC_USAGE is defined in lib/db.bash
        ((rc == POKIDLE_RC_USAGE)) && {
            pokidle_export_help >&2
            return 2
        }
        return "${rc}"
    fi

    local -a all_species=()
    mapfile -t all_species < <(jq -r '[.[].species] | unique | .[]' <<<"${rows}")
    if ((${#all_species[@]} == 0)); then
        return 0
    fi

    local -a item_args=(--limit 1000)
    if [[ -n "${since_ts}" ]]; then
        item_args+=(--since "@${since_ts}")
    fi
    if [[ -n "${until_ts}" ]]; then
        item_args+=(--until "@${until_ts}")
    fi
    local -a cand_items=()
    mapfile -t cand_items < <(db_list_item_drops "${item_args[@]}" | jq -r '[.[].item] | unique | .[]')
    local -a items=()
    local it
    for it in "${cand_items[@]}"; do
        # Positive gate: only items Showdown accepts on a set survive, so the
        # team is always importable even when the window holds legacy junk drops
        # (items since removed from the pool) or trade-evo items.
        if ! showdown_item_is_holdable "${it}"; then
            continue
        fi
        items+=("${it}")
    done
    _pokidle_shuffle items

    # Held form-items in the window (mega stones, primal orbs, signature
    # Z-crystals). They are isNonstandard:Past, so they never enter the general
    # holdable pool above; instead they are force-assigned to their matching mon.
    local -a form_slugs=()
    mapfile -t form_slugs < <(showdown_form_item_slugs 2>/dev/null)
    local -a form_held=()
    if ((${#form_slugs[@]} > 0)); then
        for it in "${cand_items[@]}"; do
            if [[ " ${form_slugs[*]} " == *" ${it} "* ]]; then
                form_held+=("${it}")
            fi
        done
    fi

    # --force-mega/--force-z: species/varieties a held form-item of the requested
    # class is eligible for. `wanted_el` (JSON array) also steers the per-species
    # encounter pick toward the matching form (e.g. raichu-alola for a Z-crystal).
    local wanted_el='[]'
    if ((force_mega || force_z)) && ((${#form_held[@]} > 0)); then
        local -a want_classes=()
        ((force_mega)) && want_classes+=("mega")
        ((force_z)) && want_classes+=("z")
        local held_re classes_re
        held_re="$(
            IFS='|'
            printf '%s' "${form_held[*]}"
        )"
        classes_re="$(
            IFS='|'
            printf '%s' "${want_classes[*]}"
        )"
        wanted_el="$(showdown_form_items_meta 2>/dev/null |
            awk -F'\t' -v h="^(${held_re})$" -v c="^(${classes_re})$" '$1 ~ h && $3 ~ c {print $2}' |
            jq -R . | jq -s 'unique')"
    fi

    # Selection: forced-eligible species first (shuffled), then fill to 6.
    local -a forced_species=()
    if [[ "${wanted_el}" != "[]" ]]; then
        mapfile -t forced_species < <(jq -r --argjson el "${wanted_el}" \
            '[.[] | select(((.species) as $s | $el | index($s)) or ((.variety) as $v | $v != null and ($el | index($v)))) | .species] | unique | .[]' <<<"${rows}")
    fi
    # --force-legendary: pull legendary/mythical species first, alongside any
    # held-item eligibles. Union (deduped) into the same pull-first set. Reads
    # the stored is_legendary column (rows already carry it via SELECT e.*) —
    # no PokeAPI lookup needed.
    if ((force_legendary)); then
        _export_mark_forced "${rows}" '.is_legendary==1' forced_species
    fi
    if ((force_shiny)); then
        _export_mark_forced "${rows}" '.shiny==1' forced_species
    fi
    if ((force_hidden)); then
        _export_mark_forced "${rows}" '.is_hidden_ability==1' forced_species
    fi
    _pokidle_shuffle forced_species
    local -a species=("${forced_species[@]:0:6}")
    local -a rest=()
    local s
    for s in "${all_species[@]}"; do
        if [[ " ${species[*]} " != *" ${s} "* ]]; then
            rest+=("${s}")
        fi
    done
    local -A best_iv=()
    if ((force_best_ivs)); then
        local _sp _tot
        while IFS=$'\t' read -r _sp _tot; do
            [[ -n "${_sp}" ]] && best_iv["${_sp}"]="${_tot}"
        done < <(jq -r '
            group_by(.species)[]
            | [ .[0].species,
                ([.[] | (.iv_hp + .iv_atk + .iv_def + .iv_spa + .iv_spd + .iv_spe)] | max) ]
            | @tsv' <<<"${rows}")
    fi
    if ((force_evolved)); then
        # Prefer more-evolved mons in the fill: bucket by stage tier (1=final,
        # 2=mid, 3=base/unknown), then order within each, then concatenate.
        local -a evo_t1=()
        local -a evo_t2=()
        local -a evo_t3=()
        local rs
        local tier
        for rs in "${rest[@]}"; do
            tier="$(evolution_species_tier "${rs}")"
            case "${tier}" in
                1) evo_t1+=("${rs}") ;;
                2) evo_t2+=("${rs}") ;;
                *) evo_t3+=("${rs}") ;;
            esac
        done
        if ((force_best_ivs)); then
            _export_sort_by_iv_desc evo_t1
            _export_sort_by_iv_desc evo_t2
            _export_sort_by_iv_desc evo_t3
        else
            _pokidle_shuffle evo_t1
            _pokidle_shuffle evo_t2
            _pokidle_shuffle evo_t3
        fi
        rest=("${evo_t1[@]}" "${evo_t2[@]}" "${evo_t3[@]}")
    elif ((force_best_ivs)); then
        _export_sort_by_iv_desc rest
    else
        _pokidle_shuffle rest
    fi
    local -i need=$((6 - ${#species[@]}))
    if ((need > 0 && ${#rest[@]} > 0)); then
        species+=("${rest[@]:0:need}")
    fi

    local used="|"
    local sep=""
    local sp
    local US=$'\037'
    for sp in "${species[@]}"; do
        # Pick one random stored encounter for this species in a single jq pass:
        # RANDOM seeds the index, jq mods it by the group size (no separate
        # count fork).
        # Prefer an encounter whose form matches a wanted form-item (so a forced
        # Z-crystal lands on raichu-alola, not base raichu); else any of this
        # species at random.
        local enc
        enc="$(jq -c --arg s "${sp}" --argjson rnd "${RANDOM}" --argjson el "${wanted_el}" \
            --argjson fshiny "${force_shiny}" --argjson fhidden "${force_hidden}" '
             [.[] | select(.species==$s)] as $g
             | ([$g[] | . + {"_score":
                   ((if (($el | length) > 0 and (((.variety // .species)) as $v | ($el | index($v)))) then 3 else 0 end)
                  + (if ($fshiny == 1 and .shiny == 1) then 1 else 0 end)
                  + (if ($fhidden == 1 and .is_hidden_ability == 1) then 1 else 0 end))}]) as $scored
             | ($scored | map(._score) | max) as $mx
             | [$scored[] | select(._score == $mx)] as $best
             | ($best[$rnd % ($best | length)] | del(._score))' <<<"${rows}")"

        # One jq read pulls the fields the loop needs: form name, the stored
        # moveset (.moves_json is already a JSON-array string, usable as-is via
        # --argjson), and the held berry. Moves are born legal (rolled at capture
        # time), so they are used as-is without any trimming.
        local variety moves_json berry
        IFS="${US}" read -r variety moves_json berry < <(jq -r --arg US "${US}" \
            '[(.variety // .species), (.moves_json // "[]"), (.held_berry // "")] | join($US)' <<<"${enc}")

        # A held form-item eligible for this mon always wins over a random item
        # (e.g. Charizard @ Charizardite X). One stone -> one mon via `used`.
        local chosen=""
        if ((${#form_held[@]} > 0)); then
            local elig e
            if elig="$(showdown_form_items_for_species "${sp}" "${variety}" 2>/dev/null)"; then
                while IFS= read -r e; do
                    [[ -z "${e}" ]] && continue
                    if [[ " ${form_held[*]} " == *" ${e} "* && "${used}" != *"|${e}|"* ]]; then
                        chosen="${e}"
                        used+="${chosen}|"
                        break
                    fi
                done <<<"${elig}"
            fi
        fi

        # Otherwise: unused window items + this mon's own berry (bare berry slug
        # normalized to "<name>-berry").
        if [[ -z "${chosen}" ]]; then
            local -a cands=()
            for it in "${items[@]}"; do
                if [[ "${used}" == *"|${it}|"* ]]; then
                    continue
                fi
                cands+=("${it}")
            done
            if [[ -n "${berry}" && "${berry}" != "null" ]]; then
                local berry_item="${berry}-berry"
                if [[ "${used}" != *"|${berry_item}|"* ]] &&
                    showdown_item_is_holdable "${berry_item}"; then
                    cands+=("${berry_item}")
                fi
            fi
            if ((${#cands[@]} > 0)); then
                chosen="${cands[$((RANDOM % ${#cands[@]}))]}"
                used+="${chosen}|"
            fi
        fi

        local norm
        norm="$(jq -c --arg item "${chosen}" --argjson moves "${moves_json}" \
            --arg fl "${force_level}" --argjson fp "${force_perfect}" --arg fn "${force_nature}" '{
            species: (.variety // .species),
            level: (if $fl != "" then ($fl | tonumber) else .level end),
            nature: (if $fn != "" then $fn else .nature end),
            ability, is_hidden_ability, shiny, gender,
            held_item: ($item | select(. != "") // null),
            ivs: (if $fp == 1 then [31,31,31,31,31,31]
                  else [.iv_hp,.iv_atk,.iv_def,.iv_spa,.iv_spd,.iv_spe] end),
            evs: [.ev_hp,.ev_atk,.ev_def,.ev_spa,.ev_spd,.ev_spe],
            moves: $moves
        }' <<<"${enc}")"
        local block
        if ! block="$(export_format "${norm}")"; then
            printf 'export: skipping %s — no Showdown name\n' "${sp}" >&2
            continue
        fi
        # Blank line between sets (sep is "" before the first, "\n" after) plus
        # a single terminating newline — no trailing blank line. block itself has
        # no trailing newline; command substitution stripped it.
        printf '%s%s\n' "${sep}" "${block}"
        sep=$'\n'
    done
}
