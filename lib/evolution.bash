#!/usr/bin/env bash
# lib/evolution.bash — evolution-loop helpers.
# Depends on pokeapi_get (api.bash) and encounter_pool_load (encounter.bash).

# Look up the tier of a species in a biome's pool.
# Defaults to "common" if the species isn't in any tier.
evolution_tier_lookup() {
    local biome="$1" species="$2"
    if ! command -v encounter_pool_load > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"
    fi
    local pool
    pool="$(encounter_pool_load "$biome" 2>/dev/null)" || { printf 'common'; return; }
    local tier
    tier="$(jq -r --arg sp "$species" '
        .tiers
        | to_entries
        | map(select(.value | map(.species) | index($sp)))
        | (.[0].key // "common")
    ' <<< "$pool")"
    printf '%s' "$tier"
}

# Given an evolution-chain JSON and a species name, return JSON array of
# {species, evolution_details} for each direct child of that species in the chain.
evolution_next_stages() {
    local chain_json="$1" species="$2"
    jq -c --arg sp "$species" '
        def find($node):
            if $node.species.name == $sp then
                [$node.evolves_to[] | {species: .species.name, evolution_details: .evolution_details}]
            else
                ($node.evolves_to[] | find(.))
            end;
        find(.chain)
    ' <<< "$chain_json"
}

# PokeAPI evolution_details.gender code -> encounter gender label.
# Canonical PokeAPI: 1=female, 2=male, 3=genderless. Empty for "no requirement".
_evolution_gender_required() {
    local code="$1"
    case "$code" in
        1) printf 'F' ;;
        2) printf 'M' ;;
        3) printf 'genderless' ;;
        *) printf '' ;;
    esac
}

# Returns "day" or "night" based on local hour. 6:00-17:59 = day; else night.
# Override with EVOLUTION_TIME_OF_DAY env var (used in tests).
_evolution_current_time_of_day() {
    if [[ -n "${EVOLUTION_TIME_OF_DAY:-}" ]]; then
        printf '%s' "$EVOLUTION_TIME_OF_DAY"
        return
    fi
    local h
    h=$(date +%H)
    if (( 10#$h >= 6 && 10#$h < 18 )); then
        printf 'day'
    else
        printf 'night'
    fi
}

# evolution_check_hard_filters <encounter_json> <evo_detail_json>
# Returns 0 if all hard filters pass, non-zero otherwise.
evolution_check_hard_filters() {
    local enc="$1" evo="$2"

    # Gender
    local gcode greq genc
    gcode="$(jq -r '.gender // empty' <<< "$evo")"
    if [[ -n "$gcode" && "$gcode" != "null" ]]; then
        greq="$(_evolution_gender_required "$gcode")"
        if [[ -n "$greq" ]]; then
            genc="$(jq -r '.gender' <<< "$enc")"
            [[ "$greq" == "$genc" ]] || return 1
        fi
    fi

    # min_level
    local ml lvl
    ml="$(jq -r '.min_level // empty' <<< "$evo")"
    if [[ -n "$ml" && "$ml" != "null" ]]; then
        lvl="$(jq -r '.level' <<< "$enc")"
        (( lvl >= ml )) || return 1
    fi

    # min_happiness
    local mh fr
    mh="$(jq -r '.min_happiness // empty' <<< "$evo")"
    if [[ -n "$mh" && "$mh" != "null" ]]; then
        fr="$(jq -r '.friendship' <<< "$enc")"
        (( fr >= mh )) || return 1
    fi

    # time_of_day
    local tod cur
    tod="$(jq -r '.time_of_day // empty' <<< "$evo")"
    if [[ -n "$tod" && "$tod" != "null" && "$tod" != "" ]]; then
        cur="$(_evolution_current_time_of_day)"
        [[ "$tod" == "$cur" ]] || return 1
    fi

    # known_move
    local km
    km="$(jq -r '.known_move.name // empty' <<< "$evo")"
    if [[ -n "$km" && "$km" != "null" ]]; then
        jq -e --arg m "$km" '.moves | index($m)' <<< "$enc" > /dev/null || return 1
    fi

    # known_move_type - encounter.moves are names, not types; cannot verify.
    # Treat as unverifiable -> hard fail (conservative).
    local kmt
    kmt="$(jq -r '.known_move_type.name // empty' <<< "$evo")"
    [[ -n "$kmt" && "$kmt" != "null" ]] && return 1

    # relative_physical_stats: 1 = atk>def, -1 = def>atk, 0 = atk==def
    local rps atk def
    rps="$(jq -r '.relative_physical_stats // empty' <<< "$evo")"
    if [[ -n "$rps" && "$rps" != "null" ]]; then
        atk="$(jq -r '.stats[1]' <<< "$enc")"
        def="$(jq -r '.stats[2]' <<< "$enc")"
        case "$rps" in
            1)  (( atk > def )) || return 1 ;;
            -1) (( def > atk )) || return 1 ;;
            0)  [[ "$atk" == "$def" ]] || return 1 ;;
        esac
    fi

    return 0
}

# evolution_path_kind <evo_detail_json>
# "item" if the evo requires a consumable item, else "synthetic".
evolution_path_kind() {
    local evo="$1"
    local has_item
    has_item="$(jq -r '.item.name // .held_item.name // empty' <<< "$evo")"
    if [[ -n "$has_item" && "$has_item" != "null" ]]; then
        printf 'item'
    else
        printf 'synthetic'
    fi
}

# evolution_path_item_name <evo_detail_json>
# Returns item name (kebab-case) or empty.
evolution_path_item_name() {
    local evo="$1"
    jq -r '.item.name // .held_item.name // empty' <<< "$evo"
}

# Count item_drops rows for a given item name. Wraps a sqlite query.
_evolution_count_item_drops() {
    local item="$1"
    db_query "SELECT COUNT(*) FROM item_drops WHERE item='${item//\'/\'\'}';"
}

# evolution_enumerate_viable_paths <encounter_json> <next_stages_json>
# Emits JSON array of viable paths: {species, kind, item?, evo}.
evolution_enumerate_viable_paths() {
    local enc="$1" stages="$2"
    if ! command -v db_query > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/db.bash"
    fi
    local out='[]'
    local n
    n="$(jq 'length' <<< "$stages")"
    local i
    for (( i=0; i<n; i++ )); do
        local stage
        stage="$(jq -c ".[$i]" <<< "$stages")"
        local species
        species="$(jq -r '.species' <<< "$stage")"
        local m j
        m="$(jq '.evolution_details | length' <<< "$stage")"
        for (( j=0; j<m; j++ )); do
            local evo
            evo="$(jq -c ".evolution_details[$j]" <<< "$stage")"
            evolution_check_hard_filters "$enc" "$evo" || continue
            local kind item
            kind="$(evolution_path_kind "$evo")"
            if [[ "$kind" == "item" ]]; then
                item="$(evolution_path_item_name "$evo")"
                local cnt
                cnt="$(_evolution_count_item_drops "$item")"
                (( cnt > 0 )) || continue
                out="$(jq -c --arg sp "$species" --arg item "$item" --argjson e "$evo" \
                    '. + [{species:$sp, kind:"item", item:$item, evo:$e}]' <<< "$out")"
            else
                out="$(jq -c --arg sp "$species" --argjson e "$evo" \
                    '. + [{species:$sp, kind:"synthetic", evo:$e}]' <<< "$out")"
            fi
        done
    done
    printf '%s' "$out"
}

# evolution_apply <encounter_id> <path_json>
# Mutates the encounter row to the evolved species. Consumes one item_drops
# row if path.kind == "item".
evolution_apply() {
    local enc_id="$1" path="$2"
    local kind species item
    kind="$(jq -r '.kind' <<< "$path")"
    species="$(jq -r '.species' <<< "$path")"

    if ! command -v db_query > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/db.bash"
    fi
    if ! command -v encounter_nature_mods > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"
    fi

    if [[ "$kind" == "item" ]]; then
        item="$(jq -r '.item' <<< "$path")"
        db_delete_one_item_drop "$item" > /dev/null
    fi

    # Re-fetch the encounter row to compose stat inputs.
    local enc_row
    enc_row="$(db_query_json "SELECT * FROM encounters WHERE id=$enc_id;" | jq -c '.[0]')"
    local nature level ivs evs
    nature="$(jq -r '.nature' <<< "$enc_row")"
    level="$(jq -r '.level' <<< "$enc_row")"
    ivs="$(jq -r '"\(.iv_hp) \(.iv_atk) \(.iv_def) \(.iv_spa) \(.iv_spd) \(.iv_spe)"' <<< "$enc_row")"
    evs="$(jq -r '"\(.ev_hp) \(.ev_atk) \(.ev_def) \(.ev_spa) \(.ev_spd) \(.ev_spe)"' <<< "$enc_row")"
    local shiny
    shiny="$(jq -r '.shiny' <<< "$enc_row")"

    # Forme-bearing evolved species (mimikyu, lycanroc, oricorio, …) need a
    # variety pick — /pokemon/<bare-species> 404s for them. Falls back to bare
    # name when the species has no variety table.
    local variety
    variety="$(encounter_pick_variety "$species")"
    [[ -z "$variety" || "$variety" == "null" ]] && variety="$species"

    local poke base_stats sprite mods stats dex_id
    poke="$(pokeapi_get "pokemon/$variety")" || return 1
    dex_id="$(jq -r '.id' <<< "$poke")"
    if [[ "$shiny" == "1" ]]; then
        sprite="$(jq -r '.sprites.front_shiny // .sprites.front_default // ""' <<< "$poke")"
    else
        sprite="$(jq -r '.sprites.front_default // ""' <<< "$poke")"
    fi
    base_stats="$(jq -c '.stats' <<< "$poke")"
    mods="$(encounter_nature_mods "$nature")" || return 1
    stats="$(encounter_compute_all_stats "$base_stats" "$ivs" "$evs" "$level" "$mods")" || return 1

    local sprite_url="$sprite"
    local sprite_local=""
    if [[ -n "$sprite_url" ]]; then
        sprite_local="${POKIDLE_CACHE_DIR:-$HOME/.cache/pokidle}/sprites/$species.png"
        mkdir -p -- "$(dirname -- "$sprite_local")"
        [[ -f "$sprite_local" ]] || curl -sS -o "$sprite_local" "$sprite_url" || sprite_local=""
    fi

    db_update_encounter_evolved "$enc_id" "$species" "$dex_id" "$sprite_local" "$stats"
}
