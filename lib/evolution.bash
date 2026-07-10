#!/usr/bin/env bash
# Evolution-loop helpers.
# Depends on pokeapi_get (api.bash) and encounter_pool_load (encounter.bash).

# Dependencies: sourced once at load, guarded so standalone/test re-sourcing is
# a no-op. POKIDLE_REPO_ROOT is set by the entrypoint and by the tests. lib/db.bash
# is NOT loaded here: it hard-fails at source time unless POKIDLE_DB_PATH is set,
# and callers set that per-invocation, so the two db-touching functions below
# source it lazily at call time instead.
# shellcheck source=lib/encounter.bash disable=SC2154
command -v encounter_pool_load >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"
# shellcheck source=lib/showdown.bash disable=SC2154
command -v showdown_legal_abilities >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/showdown.bash"

# evolution_tier_lookup <biome> <species>
# Print the pool tier of <species> in <biome>; "common" if it isn't listed.
function evolution_tier_lookup {
    local biome="$1"
    local species="$2"
    local pool
    if ! pool="$(encounter_pool_load "${biome}" 2>/dev/null)"; then
        printf 'common'
        return
    fi
    local tier
    tier="$(jq -r --arg sp "${species}" '
        .tiers
        | to_entries
        | map(select(.value | map(.species) | index($sp)))
        | (.[0].key // "common")
    ' <<<"${pool}")"
    printf '%s' "${tier}"
}

# evolution_next_stages <chain_json> <species>
# Print a JSON array of {species, evolution_details} for each direct child of
# <species> in the evolution chain.
function evolution_next_stages {
    local chain_json="$1"
    local species="$2"
    jq -c --arg sp "${species}" '
        def find($node):
            if $node.species.name == $sp then
                [$node.evolves_to[] | {species: .species.name, evolution_details: .evolution_details}]
            else
                ($node.evolves_to[] | find(.))
            end;
        find(.chain)
    ' <<<"${chain_json}"
}

# evolution_stage_tier <chain_json> <species>
# Classify <species>'s position in <chain_json>. Prints:
#   1 = fully evolved (chain node is terminal — no evolves_to)
#   2 = mid-stage     (node found, still evolves, depth >= 1)
#   3 = base/unknown  (node found, still evolves, depth 0; or not in chain)
# Depth is the number of evolution steps from the chain root.
function evolution_stage_tier {
    local chain_json="$1"
    local species="$2"
    jq -r --arg sp "${species}" '
        def find($node; $d):
            if $node.species.name == $sp then
                {terminal: (($node.evolves_to | length) == 0), depth: $d}
            else
                ($node.evolves_to[]? | find(.; $d + 1))
            end;
        [ find(.chain; 0) ] | (.[0] // null) as $r
        | if $r == null then 3
          elif $r.terminal then 1
          elif $r.depth == 0 then 3
          else 2 end
    ' <<<"${chain_json}"
}

# _evolution_gender_required <code>
# Map a PokeAPI evolution_details.gender code to an encounter gender label.
# Canonical PokeAPI: 1=female, 2=male, 3=genderless. Empty for "no requirement".
function _evolution_gender_required {
    local code="$1"
    case "${code}" in
        1) printf 'F' ;;
        2) printf 'M' ;;
        3) printf 'genderless' ;;
        *) printf '' ;;
    esac
}

# _evolution_current_time_of_day
# Print "day" (06:00-17:59 local) or "night". Override with the
# EVOLUTION_TIME_OF_DAY env var (used in tests).
function _evolution_current_time_of_day {
    if [[ -n "${EVOLUTION_TIME_OF_DAY:-}" ]]; then
        printf '%s' "${EVOLUTION_TIME_OF_DAY}"
        return
    fi
    local h
    h="$(date +%H)"
    if ((10#${h} >= 6 && 10#${h} < 18)); then
        printf 'day'
    else
        printf 'night'
    fi
}

# evolution_check_hard_filters <encounter_json> <evo_detail_json>
# Return 0 if every hard requirement is satisfied, non-zero otherwise.
# Unmodeled or unverifiable requirements are treated as failures (conservative).
function evolution_check_hard_filters {
    local enc="$1"
    local evo="$2"

    # Gender
    local gcode
    gcode="$(jq -r '.gender // empty' <<<"${evo}")"
    if [[ -n "${gcode}" && "${gcode}" != "null" ]]; then
        local greq
        greq="$(_evolution_gender_required "${gcode}")"
        if [[ -n "${greq}" ]]; then
            local genc
            genc="$(jq -r '.gender' <<<"${enc}")"
            if [[ "${greq}" != "${genc}" ]]; then
                return 1
            fi
        fi
    fi

    # min_level
    local ml
    ml="$(jq -r '.min_level // empty' <<<"${evo}")"
    if [[ -n "${ml}" && "${ml}" != "null" ]]; then
        local lvl
        lvl="$(jq -r '.level' <<<"${enc}")"
        if ((lvl < ml)); then
            return 1
        fi
    fi

    # min_happiness
    local mh
    mh="$(jq -r '.min_happiness // empty' <<<"${evo}")"
    if [[ -n "${mh}" && "${mh}" != "null" ]]; then
        local fr
        fr="$(jq -r '.friendship' <<<"${enc}")"
        if ((fr < mh)); then
            return 1
        fi
    fi

    # time_of_day
    local tod
    tod="$(jq -r '.time_of_day // empty' <<<"${evo}")"
    if [[ -n "${tod}" && "${tod}" != "null" ]]; then
        local cur
        cur="$(_evolution_current_time_of_day)"
        if [[ "${tod}" != "${cur}" ]]; then
            return 1
        fi
    fi

    # known_move
    local km
    km="$(jq -r '.known_move.name // empty' <<<"${evo}")"
    if [[ -n "${km}" && "${km}" != "null" ]]; then
        if ! jq -e --arg m "${km}" '.moves | index($m)' <<<"${enc}" >/dev/null; then
            return 1
        fi
    fi

    # known_move_type - encounter.moves are names, not types; cannot verify.
    # Treat as unverifiable -> hard fail (conservative).
    local kmt
    kmt="$(jq -r '.known_move_type.name // empty' <<<"${evo}")"
    if [[ -n "${kmt}" && "${kmt}" != "null" ]]; then
        return 1
    fi

    # relative_physical_stats: 1 = atk>def, -1 = def>atk, 0 = atk==def
    local rps
    rps="$(jq -r '.relative_physical_stats // empty' <<<"${evo}")"
    if [[ -n "${rps}" && "${rps}" != "null" ]]; then
        local atk
        atk="$(jq -r '.stats[1]' <<<"${enc}")"
        local def
        def="$(jq -r '.stats[2]' <<<"${enc}")"
        case "${rps}" in
            1)
                if ((atk <= def)); then
                    return 1
                fi
                ;;
            -1)
                if ((def <= atk)); then
                    return 1
                fi
                ;;
            0)
                if [[ "${atk}" != "${def}" ]]; then
                    return 1
                fi
                ;;
            *) ;;
        esac
    fi

    # Unmodeled / unsatisfiable requirements -> hard fail (conservative).
    local val
    local fld
    # Object-or-scalar fields (PokeAPI gives {name,url} objects for these).
    for fld in location trade_species party_species party_type; do
        val="$(jq -r --arg f "${fld}" '.[$f].name // .[$f] // empty' <<<"${evo}")"
        if [[ -n "${val}" && "${val}" != "null" ]]; then
            return 1
        fi
    done
    # Numeric scalar requirements.
    for fld in min_affection min_beauty min_damage_taken; do
        val="$(jq -r --arg f "${fld}" '.[$f] // empty' <<<"${evo}")"
        if [[ -n "${val}" && "${val}" != "null" ]]; then
            return 1
        fi
    done
    # Boolean requirements.
    for fld in turn_upside_down needs_overworld_rain; do
        val="$(jq -r --arg f "${fld}" '.[$f] // false' <<<"${evo}")"
        if [[ "${val}" == "true" ]]; then
            return 1
        fi
    done

    # Trigger gate. level-up / use-item are modeled. trade is allowed only
    # when an item/held_item is consumed as a proxy for the trade. Any other
    # trigger (shed, spin, tower-*, three-critical-hits, take-damage,
    # style-move, recoil-damage, …) is unmodeled -> reject. Empty trigger
    # (synthetic test evos) is allowed.
    local trig
    trig="$(jq -r '.trigger.name // empty' <<<"${evo}")"
    local has_item
    has_item="$(jq -r '.item.name // .held_item.name // empty' <<<"${evo}")"
    case "${trig}" in
        "" | level-up | use-item) : ;;
        trade)
            if [[ -z "${has_item}" || "${has_item}" == "null" ]]; then
                return 1
            fi
            ;;
        *) return 1 ;;
    esac

    return 0
}

# evolution_path_kind <evo_detail_json>
# Print "item" if the evo requires a consumable item, else "synthetic".
function evolution_path_kind {
    local evo="$1"
    local has_item
    has_item="$(jq -r '.item.name // .held_item.name // empty' <<<"${evo}")"
    if [[ -n "${has_item}" && "${has_item}" != "null" ]]; then
        printf 'item'
    else
        printf 'synthetic'
    fi
}

# evolution_path_item_name <evo_detail_json>
# Print the required item name (kebab-case), or empty.
function evolution_path_item_name {
    local evo="$1"
    jq -r '.item.name // .held_item.name // empty' <<<"${evo}"
}

# _evolution_count_item_drops <item>
# Print the count of unconsumed item_drops rows for <item>.
function _evolution_count_item_drops {
    local item="$1"
    db_query "SELECT COUNT(*) FROM item_drops WHERE item='${item//\'/\'\'}' AND consumed_at IS NULL;"
}

# evolution_enumerate_viable_paths <encounter_json> <next_stages_json>
# Print a JSON array of viable evolution paths: {species, kind, item?, evo}.
function evolution_enumerate_viable_paths {
    local enc="$1"
    local stages="$2"
    # db sourced lazily: it requires POKIDLE_DB_PATH at source time (see header).
    # shellcheck source=lib/db.bash disable=SC2154
    command -v db_query >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/db.bash"
    local out='[]'
    local -i n
    n="$(jq 'length' <<<"${stages}")"
    local -i i
    for ((i = 0; i < n; i++)); do
        local stage
        stage="$(jq -c ".[${i}]" <<<"${stages}")"
        local species
        species="$(jq -r '.species' <<<"${stage}")"
        local -i m
        m="$(jq '.evolution_details | length' <<<"${stage}")"
        local -i j
        for ((j = 0; j < m; j++)); do
            local evo
            evo="$(jq -c ".evolution_details[${j}]" <<<"${stage}")"
            if ! evolution_check_hard_filters "${enc}" "${evo}"; then
                continue
            fi
            local kind
            kind="$(evolution_path_kind "${evo}")"
            if [[ "${kind}" == "item" ]]; then
                local item
                item="$(evolution_path_item_name "${evo}")"
                local cnt
                cnt="$(_evolution_count_item_drops "${item}")"
                if ((cnt <= 0)); then
                    continue
                fi
                out="$(jq -c --arg sp "${species}" --arg item "${item}" --argjson e "${evo}" \
                    '. + [{species:$sp, kind:"item", item:$item, evo:$e}]' <<<"${out}")"
            else
                out="$(jq -c --arg sp "${species}" --argjson e "${evo}" \
                    '. + [{species:$sp, kind:"synthetic", evo:$e}]' <<<"${out}")"
            fi
        done
    done
    printf '%s' "${out}"
}

# evolution_reconcile_ability <variety> <old_ability_slug>
# Keep <old_ability_slug> if it is legal for <variety> (recomputing is_hidden
# from the new species' table); otherwise re-roll from the new legal pool.
# Falls back to the legal roller when Showdown data is unavailable. Prints
# {"name","is_hidden"}.
function evolution_reconcile_ability {
    local variety="$1"
    local old="$2"
    local lines
    if ! lines="$(showdown_legal_abilities "${variety}")"; then
        encounter_roll_ability_legal "${variety}"
        return
    fi
    local slug hid
    while IFS=$'\t' read -r slug hid; do
        [[ -z "${slug}" ]] && continue
        if [[ "${slug}" == "${old}" ]]; then
            local h="false"
            [[ "${hid}" == "1" ]] && h="true"
            jq -nc --arg n "${old}" --argjson h "${h}" '{name:$n, is_hidden:$h}'
            return
        fi
    done <<<"${lines}"
    encounter_roll_ability_legal "${variety}"
}

# evolution_reconcile_moves <variety> <level> <old_moves_json> [fallback]
# Keep the old moves that are legal for <variety> (in original order, deduped),
# then refill empty slots from the new legal pool up to 4. Falls back to the
# legal roller when Showdown data is unavailable. Prints a JSON array of slugs.
function evolution_reconcile_moves {
    local variety="$1"
    local level="$2"
    local old="$3"
    local fallback="${4:-}"
    local pool
    if ! pool="$(showdown_legal_moves "${variety}")"; then
        encounter_roll_moves_legal "${variety}" "${level}" "${fallback}"
        return
    fi
    local -A legal=()
    local m
    while IFS= read -r m; do
        [[ -n "${m}" ]] && legal["${m}"]=1
    done <<<"${pool}"

    local -a kept=()
    local -A taken=()
    while IFS= read -r m; do
        [[ -z "${m}" ]] && continue
        if [[ -n "${legal[${m}]:-}" && -z "${taken[${m}]:-}" ]]; then
            kept+=("${m}")
            taken["${m}"]=1
        fi
    done < <(jq -r '.[]' <<<"${old}")

    local -a refill=()
    for m in "${!legal[@]}"; do
        [[ -z "${taken[${m}]:-}" ]] && refill+=("${m}")
    done
    while ((${#kept[@]} < 4 && ${#refill[@]} > 0)); do
        local -i idx=$((RANDOM % ${#refill[@]}))
        kept+=("${refill[idx]}")
        refill=("${refill[@]:0:idx}" "${refill[@]:idx+1}")
    done

    printf '['
    local sep="" i
    for i in "${kept[@]}"; do
        printf '%s"%s"' "${sep}" "${i}"
        sep=","
    done
    printf ']'
}

# evolution_apply <encounter_id> <path_json>
# Mutate the encounter row to the evolved species, recomputing stats. Consumes
# one item_drops row when path.kind == "item". Returns 1 on fetch failure.
function evolution_apply {
    local enc_id="$1"
    local path="$2"
    local kind
    kind="$(jq -r '.kind' <<<"${path}")"
    local species
    species="$(jq -r '.species' <<<"${path}")"

    # db sourced lazily: it requires POKIDLE_DB_PATH at source time (see header).
    # shellcheck source=lib/db.bash disable=SC2154
    command -v db_query >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/db.bash"

    if [[ "${kind}" == "item" ]]; then
        local item
        item="$(jq -r '.item' <<<"${path}")"
        db_consume_one_item_drop "${item}" >/dev/null
    fi

    # Re-fetch the encounter row to compose stat inputs.
    local enc_row
    enc_row="$(db_query_json "SELECT * FROM encounters WHERE id=${enc_id};" | jq -c '.[0]')"
    local nature
    nature="$(jq -r '.nature' <<<"${enc_row}")"
    local level
    level="$(jq -r '.level' <<<"${enc_row}")"
    local ivs
    ivs="$(jq -r '"\(.iv_hp) \(.iv_atk) \(.iv_def) \(.iv_spa) \(.iv_spd) \(.iv_spe)"' <<<"${enc_row}")"
    local evs
    evs="$(jq -r '"\(.ev_hp) \(.ev_atk) \(.ev_def) \(.ev_spa) \(.ev_spd) \(.ev_spe)"' <<<"${enc_row}")"
    local shiny
    shiny="$(jq -r '.shiny' <<<"${enc_row}")"

    # Forme-bearing evolved species (mimikyu, lycanroc, oricorio, …) need a
    # variety pick — /pokemon/<bare-species> 404s for them. Falls back to bare
    # name when the species has no variety table.
    local variety
    variety="$(encounter_pick_variety "${species}")"
    if [[ -z "${variety}" || "${variety}" == "null" ]]; then
        variety="${species}"
    fi

    local poke
    if ! poke="$(pokeapi_get "pokemon/${variety}")"; then
        return 1
    fi
    local dex_id
    dex_id="$(jq -r '.id' <<<"${poke}")"
    local sprite
    if [[ "${shiny}" == "1" ]]; then
        sprite="$(jq -r '.sprites.front_shiny // .sprites.front_default // ""' <<<"${poke}")"
    else
        sprite="$(jq -r '.sprites.front_default // ""' <<<"${poke}")"
    fi
    local base_stats
    base_stats="$(jq -c '.stats' <<<"${poke}")"
    local mods
    if ! mods="$(encounter_nature_mods "${nature}")"; then
        return 1
    fi
    local stats
    if ! stats="$(encounter_compute_all_stats "${base_stats}" "${ivs}" "${evs}" "${level}" "${mods}")"; then
        return 1
    fi

    # Cache the sprite under the resolved variety, not the bare species: a
    # regional/form evolution (e.g. linoone-galar) has a different sprite from
    # the base form, and keying by species would collide with — or reuse — the
    # base form's cached PNG, showing the wrong sprite.
    local sprite_url="${sprite}"
    local sprite_local=""
    if [[ -n "${sprite_url}" ]]; then
        sprite_local="${POKIDLE_CACHE_DIR:-${HOME}/.cache/pokidle}/sprites/${variety}.png"
        mkdir -p -- "${sprite_local%/*}"
        if [[ ! -f "${sprite_local}" ]]; then
            if ! curl --silent --show-error --output "${sprite_local}" "${sprite_url}"; then
                sprite_local=""
            fi
        fi
    fi

    # Reconcile the carried ability/moves against the new species: keep what is
    # still legal, re-roll the rest. Stale picks (e.g. meowth-alola -> persian)
    # would otherwise survive the evolution.
    local old_ability old_moves
    old_ability="$(jq -r '.ability // ""' <<<"${enc_row}")"
    old_moves="$(jq -c '.moves_json | fromjson? // []' <<<"${enc_row}")"
    local ability_obj
    ability_obj="$(evolution_reconcile_ability "${variety}" "${old_ability}")"
    local ability is_hidden
    ability="$(jq -r '.name' <<<"${ability_obj}")"
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<<"${ability_obj}")"
    local moves_json
    moves_json="$(evolution_reconcile_moves "${variety}" "${level}" "${old_moves}" "${species}")"

    if ! db_update_encounter_evolved "${enc_id}" "${species}" "${dex_id}" "${sprite_local}" "${stats}" "${variety}" "${ability}" "${is_hidden}" "${moves_json}"; then
        return 1
    fi
    # Echo the resolved result form so the caller can show it (e.g. the evolution
    # notification's "→ <to>"). This is the function's only stdout, so the caller
    # can capture it directly.
    printf '%s' "${variety}"
}
