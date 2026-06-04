#!/usr/bin/env bash
# Static legendary roster + roll helper.

# species -> space-separated PokeAPI types (1 or 2). Guarded so the readonly
# global survives the repeated re-sourcing the test harness does.
if [[ -z "${LEGENDARY_TYPES[*]:-}" ]]; then
    declare -grA LEGENDARY_TYPES=(
        # Gen 1
        [articuno]="ice flying"
        [zapdos]="electric flying"
        [moltres]="fire flying"
        [mewtwo]="psychic"
        [mew]="psychic"
        # Gen 2
        [raikou]="electric"
        [entei]="fire"
        [suicune]="water"
        [lugia]="psychic flying"
        ["ho-oh"]="fire flying"
        [celebi]="psychic grass"
        # Gen 3
        [regirock]="rock"
        [regice]="ice"
        [registeel]="steel"
        [latias]="dragon psychic"
        [latios]="dragon psychic"
        [kyogre]="water"
        [groudon]="ground"
        [rayquaza]="dragon flying"
        [jirachi]="steel psychic"
        [deoxys]="psychic"
        # Gen 4
        [uxie]="psychic"
        [mesprit]="psychic"
        [azelf]="psychic"
        [dialga]="steel dragon"
        [palkia]="water dragon"
        [heatran]="fire steel"
        [regigigas]="normal"
        [giratina]="ghost dragon"
        [cresselia]="psychic"
        [phione]="water"
        [manaphy]="water"
        [darkrai]="dark"
        [shaymin]="grass"
        [arceus]="normal"
        # Gen 5
        [victini]="psychic fire"
        [cobalion]="steel fighting"
        [terrakion]="rock fighting"
        [virizion]="grass fighting"
        [tornadus]="flying"
        [thundurus]="electric flying"
        [reshiram]="dragon fire"
        [zekrom]="dragon electric"
        [landorus]="ground flying"
        [kyurem]="dragon ice"
        [keldeo]="water fighting"
        [meloetta]="normal psychic"
        [genesect]="bug steel"
        # Gen 6
        [xerneas]="fairy"
        [yveltal]="dark flying"
        [zygarde]="dragon ground"
        [diancie]="rock fairy"
        [hoopa]="psychic ghost"
        [volcanion]="fire water"
        # Gen 7
        ["type-null"]="normal"
        [silvally]="normal"
        ["tapu-koko"]="electric fairy"
        ["tapu-lele"]="psychic fairy"
        ["tapu-bulu"]="grass fairy"
        ["tapu-fini"]="water fairy"
        [cosmog]="psychic"
        [cosmoem]="psychic"
        [solgaleo]="psychic steel"
        [lunala]="psychic ghost"
        [nihilego]="rock poison"
        [buzzwole]="bug fighting"
        [pheromosa]="bug fighting"
        [xurkitree]="electric"
        [celesteela]="steel flying"
        [kartana]="grass steel"
        [guzzlord]="dark dragon"
        [necrozma]="psychic"
        [magearna]="steel fairy"
        [marshadow]="fighting ghost"
        [poipole]="poison"
        [naganadel]="poison dragon"
        [stakataka]="rock steel"
        [blacephalon]="fire ghost"
        [zeraora]="electric"
        [meltan]="steel"
        [melmetal]="steel"
        # Gen 8
        [zacian]="fairy"
        [zamazenta]="fighting"
        [eternatus]="poison dragon"
        [kubfu]="fighting"
        [urshifu]="fighting dark"
        [zarude]="dark grass"
        [regieleki]="electric"
        [regidrago]="dragon"
        [glastrier]="ice"
        [spectrier]="ghost"
        [calyrex]="psychic grass"
        # Gen 9
        [koraidon]="fighting dragon"
        [miraidon]="electric dragon"
        ["wo-chien"]="dark grass"
        ["chien-pao"]="dark ice"
        ["ting-lu"]="dark ground"
        ["chi-yu"]="dark fire"
        [okidogi]="poison fighting"
        [munkidori]="poison psychic"
        [fezandipiti]="poison fairy"
        [ogerpon]="grass"
        [terapagos]="normal"
        [pecharunt]="poison ghost"
    )
fi

# _json_int_array <space-separated-ints>
# Print a JSON array literal from space-separated integers.
function _json_int_array {
    local -a parts
    read -ra parts <<<"$1"
    local IFS=,
    printf '[%s]' "${parts[*]}"
}

# legendary_roll_species_for_biome <biome_id>
# Print a random legendary whose types intersect the biome's types. Falls back
# to any legendary if none intersect (defensive — should never trigger given
# the current roster covers all 18 types). Returns 1 if the biome is unknown.
function legendary_roll_species_for_biome {
    local biome="$1"
    if ! command -v biome_types_for >/dev/null; then
        # shellcheck disable=SC1091,SC2154  # POKIDLE_REPO_ROOT exported by the pokidle entrypoint
        source "${POKIDLE_REPO_ROOT}/lib/biome.bash"
    fi

    local btypes
    if ! btypes="$(biome_types_for "${biome}")"; then
        return 1
    fi

    local -a candidates=()
    local sp
    for sp in "${!LEGENDARY_TYPES[@]}"; do
        local -a type_list
        read -ra type_list <<<"${LEGENDARY_TYPES[${sp}]}"
        local -i match=0
        local t
        for t in "${type_list[@]}"; do
            local bt
            while IFS= read -r bt; do
                if [[ -z "${bt}" ]]; then
                    continue
                fi
                if [[ "${t}" == "${bt}" ]]; then
                    match=1
                    break
                fi
            done <<<"${btypes}"
            if ((match)); then
                break
            fi
        done
        if ((match)); then
            candidates+=("${sp}")
        fi
    done

    local -i n="${#candidates[@]}"
    if ((n == 0)); then
        printf 'legendary_roll_species_for_biome: no legendary matches biome %s types\n' "${biome}" >&2
        return 1
    fi
    printf '%s' "${candidates[$((RANDOM % n))]}"
}

# legendary_build_encounter <species> <biome_id>
# Print a JSON encounter object ready for db_insert_encounter (after adding
# session_id, encountered_at, sprite_path). Always sets .is_legendary=true and
# .held_berry=null. Returns 1 if any roll step fails.
function legendary_build_encounter {
    local sp="$1"
    local biome="$2"
    if ! command -v encounter_natures_list >/dev/null; then
        # shellcheck disable=SC1091,SC2154  # POKIDLE_REPO_ROOT exported by the pokidle entrypoint
        source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"
    fi
    # Forme-bearing legendaries (shaymin, deoxys, giratina, landorus, …) have
    # no /pokemon/<species-name> resource — only /pokemon/<variety>. Roll a
    # random variety per encounter; falls back to bare species name.
    local variety
    variety="$(encounter_pick_variety "${sp}")"
    if [[ -z "${variety}" || "${variety}" == "null" ]]; then
        variety="${sp}"
    fi
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
    evs="$(encounter_ev_split "$((RANDOM % 511))")"

    local -a natures
    mapfile -t natures < <(encounter_natures_list)
    local -i nat_count="${#natures[@]}"
    local nature="${natures[$((RANDOM % nat_count))]}"
    local mods
    if ! mods="$(encounter_nature_mods "${nature}")"; then
        return 1
    fi

    local ability_obj
    if ! ability_obj="$(encounter_roll_ability "${variety}")"; then
        return 1
    fi
    local ability
    ability="$(jq -r '.name' <<<"${ability_obj}")"
    local is_hidden
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<<"${ability_obj}")"

    local moves_json
    if ! moves_json="$(encounter_roll_moves "${variety}" "${level}" "${sp}")"; then
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
        --arg sp "${sp}" --argjson dex "${dex_id}" --argjson lvl "${level}" \
        --arg nature "${nature}" --arg ability "${ability}" --argjson hidden "${is_hidden}" \
        --arg gender "${gender}" --argjson shiny "${shiny}" \
        --argjson friendship "${friendship}" \
        --argjson ivs "${ivs_json}" --argjson evs "${evs_json}" --argjson stats "${stats_json}" \
        --argjson moves "${moves_json}" --arg sprite "${final_sprite}" '{
            species: $sp, dex_id: $dex, level: $lvl,
            nature: $nature, ability: $ability, is_hidden_ability: $hidden,
            gender: $gender, shiny: $shiny, held_berry: null,
            friendship: $friendship,
            ivs: $ivs, evs: $evs, stats: $stats,
            moves: $moves, sprite_url: $sprite,
            is_legendary: true
        }'
}
