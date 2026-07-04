#!/usr/bin/env bash
# Roll legendaries from the active biome's pool. The roster is built dynamically
# by encounter_build_pool and shipped inside each pool file's .legendaries[];
# there is no static species list here.

# Dependencies: sourced once at load, guarded so standalone/test re-sourcing is
# a no-op. POKIDLE_REPO_ROOT is set by the entrypoint and by the tests.
# shellcheck source=lib/encounter.bash disable=SC2154
command -v encounter_pool_load >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"

# legendary_roll_species_for_biome <biome_id>
# Print a random {species, varieties} entry from the biome pool's .legendaries.
# Returns 1 if the biome has no pool or no legendaries.
function legendary_roll_species_for_biome {
    local biome="$1"
    local pool
    if ! pool="$(encounter_pool_load "${biome}" 2>/dev/null)"; then
        printf 'legendary_roll_species_for_biome: no pool for biome %s\n' "${biome}" >&2
        return 1
    fi
    local -i n
    n="$(jq '(.legendaries // []) | length' <<<"${pool}" 2>/dev/null)"
    if ((n == 0)); then
        printf 'legendary_roll_species_for_biome: no legendaries in biome %s pool\n' "${biome}" >&2
        return 1
    fi
    jq -c --argjson i "$((RANDOM % n))" '.legendaries[$i]' <<<"${pool}"
}

# legendary_roll_importable <biome_id> [tries]
# Roll a legendary that is born importable, re-rolling the species on each
# attempt. A build fails when the species has no Showdown-legal ability/move data
# or the Showdown source is unavailable; retry up to <tries> (default 3), then
# return 1 so the caller skips the tick. Prints the encounter JSON on success.
function legendary_roll_importable {
    local biome="$1"
    local -i tries="${2:-3}"
    local -i i
    local entry enc
    for ((i = 0; i < tries; i++)); do
        if ! entry="$(legendary_roll_species_for_biome "${biome}")"; then
            continue
        fi
        if enc="$(legendary_build_encounter "${entry}" "${biome}")"; then
            printf '%s' "${enc}"
            return 0
        fi
    done
    return 1
}

# legendary_build_encounter <entry_json> <biome_id>
# Print a JSON encounter object ready for db_insert_encounter (after adding
# session_id, encountered_at, sprite_path). Always sets .is_legendary=true and
# .held_berry=null. <entry_json> is a {species, varieties} object from
# legendary_roll_species_for_biome. Returns 1 if any roll step fails.
function legendary_build_encounter {
    local entry="$1"
    local biome="$2"
    local sp
    sp="$(jq -r '.species' <<<"${entry}")"
    # Pick the encountered form from the entry's biome-type-coherent, wild-legal
    # varieties[] (mirrors encounter_roll_pokemon). The encounter's species field
    # stays bare; /pokemon and ability/move fetches use the variety.
    local -a vlist=()
    mapfile -t vlist < <(jq -r '.varieties[]' <<<"${entry}")
    if ((${#vlist[@]} == 0)); then
        vlist=("${sp}")
    fi
    local variety="${vlist[$((RANDOM % ${#vlist[@]}))]}"
    local poke
    if ! poke="$(pokeapi_get "pokemon/${variety}")"; then
        return 1
    fi
    local dex_id
    dex_id="$(jq -r '.id' <<<"${poke}")"
    local sprite_url
    sprite_url="$(jq -r '.sprites.front_default // ""' <<<"${poke}")"
    local sprite_url_shiny
    sprite_url_shiny="$(jq -r '.sprites.front_shiny // ""' <<<"${poke}")"

    local -i lo="${POKIDLE_LEGENDARY_LEVEL_MIN:-50}"
    local -i hi="${POKIDLE_LEGENDARY_LEVEL_MAX:-70}"
    local level
    level="$(encounter_roll_level "${lo}" "${hi}")"
    local ivs
    ivs="$(encounter_roll_ivs)"
    local evs
    evs="$(encounter_roll_evs)"

    local -a natures
    mapfile -t natures < <(encounter_natures_list)
    local -i nat_count="${#natures[@]}"
    local nature="${natures[$((RANDOM % nat_count))]}"
    local mods
    if ! mods="$(encounter_nature_mods "${nature}")"; then
        return 1
    fi

    local ability_obj
    if ! ability_obj="$(encounter_roll_ability_legal "${variety}")"; then
        return 1
    fi
    local ability
    ability="$(jq -r '.name' <<<"${ability_obj}")"
    local is_hidden
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<<"${ability_obj}")"

    local moves_json
    if ! moves_json="$(encounter_roll_moves_legal "${variety}" "${level}" "${sp}")"; then
        return 1
    fi
    local gender
    if ! gender="$(encounter_roll_gender "${sp}")"; then
        return 1
    fi
    local shiny
    shiny="$(encounter_roll_shiny)"

    local friendship
    if ! friendship="$(encounter_roll_friendship "${sp}")"; then
        return 1
    fi

    local base_stats
    base_stats="$(jq -c '.stats' <<<"${poke}")"
    local stats
    if ! stats="$(encounter_compute_all_stats "${base_stats}" "${ivs}" "${evs}" "${level}" "${mods}")"; then
        return 1
    fi

    local final_sprite="${sprite_url}"
    if [[ "${shiny}" == "1" && -n "${sprite_url_shiny}" ]]; then
        final_sprite="${sprite_url_shiny}"
    fi

    local ivs_json
    ivs_json="$(_json_int_array "${ivs}")"
    local evs_json
    evs_json="$(_json_int_array "${evs}")"
    local stats_json
    stats_json="$(_json_int_array "${stats}")"

    jq -n \
        --arg sp "${sp}" --arg variety "${variety}" --argjson dex "${dex_id}" --argjson lvl "${level}" \
        --arg nature "${nature}" --arg ability "${ability}" --argjson hidden "${is_hidden}" \
        --arg gender "${gender}" --argjson shiny "${shiny}" \
        --argjson friendship "${friendship}" \
        --argjson ivs "${ivs_json}" --argjson evs "${evs_json}" --argjson stats "${stats_json}" \
        --argjson moves "${moves_json}" --arg sprite "${final_sprite}" '{
            species: $sp, variety: $variety, dex_id: $dex, level: $lvl,
            nature: $nature, ability: $ability, is_hidden_ability: $hidden,
            gender: $gender, shiny: $shiny, held_berry: null,
            friendship: $friendship,
            ivs: $ivs, evs: $evs, stats: $stats,
            moves: $moves, sprite_url: $sprite,
            is_legendary: true
        }'
}
