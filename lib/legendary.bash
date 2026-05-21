#!/usr/bin/env bash
# lib/legendary.bash — static legendary roster + roll helper.

# species -> space-separated PokeAPI types (1 or 2).
declare -gA LEGENDARY_TYPES=(
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
    [ho-oh]="fire flying"
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
    [type-null]="normal"
    [silvally]="normal"
    [tapu-koko]="electric fairy"
    [tapu-lele]="psychic fairy"
    [tapu-bulu]="grass fairy"
    [tapu-fini]="water fairy"
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
)

# legendary_roll_species_for_biome <biome_id>
# Picks a random legendary whose types intersect the biome's types.
# Falls back to any legendary if no intersection (defensive — should never
# trigger given current roster covers all 18 types).
legendary_roll_species_for_biome() {
    local biome="$1"
    if ! command -v biome_types_for > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/biome.bash"
    fi

    local btypes
    btypes="$(biome_types_for "$biome")" || return 1

    local -a candidates=()
    local sp types t bt match
    for sp in "${!LEGENDARY_TYPES[@]}"; do
        types="${LEGENDARY_TYPES[$sp]}"
        match=0
        for t in $types; do
            while IFS= read -r bt; do
                [[ -z "$bt" ]] && continue
                if [[ "$t" == "$bt" ]]; then match=1; break; fi
            done <<< "$btypes"
            (( match )) && break
        done
        (( match )) && candidates+=("$sp")
    done

    local n="${#candidates[@]}"
    if (( n == 0 )); then
        printf 'legendary_roll_species_for_biome: no legendary matches biome %s types\n' "$biome" >&2
        return 1
    fi
    printf '%s' "${candidates[$((RANDOM % n))]}"
}

# legendary_build_encounter <species> <biome_id>
# Emits a JSON encounter object ready for db_insert_encounter (after
# adding session_id, encountered_at, sprite_path). Always sets
# .is_legendary=true and .held_berry=null.
legendary_build_encounter() {
    local sp="$1" biome="$2"
    if ! command -v encounter_natures_list > /dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/encounter.bash"
    fi
    # Forme-bearing legendaries (shaymin, deoxys, giratina, landorus, …) have
    # no /pokemon/<species-name> resource — only /pokemon/<variety>. Roll a
    # random variety per encounter; falls back to bare species name.
    local variety
    variety="$(encounter_pick_variety "$sp")"
    [[ -z "$variety" || "$variety" == "null" ]] && variety="$sp"
    local poke
    poke="$(pokeapi_get "pokemon/$variety")" || return 1
    local dex_id sprite_url sprite_url_shiny
    dex_id="$(jq -r '.id' <<< "$poke")"
    sprite_url="$(jq -r '.sprites.front_default // ""' <<< "$poke")"
    sprite_url_shiny="$(jq -r '.sprites.front_shiny // ""' <<< "$poke")"

    local lo="${POKIDLE_LEGENDARY_LEVEL_MIN:-50}"
    local hi="${POKIDLE_LEGENDARY_LEVEL_MAX:-70}"
    local level ivs evs
    level="$(encounter_roll_level "$lo" "$hi")"
    ivs="$(encounter_roll_ivs)"
    evs="$(encounter_ev_split "$((RANDOM % 511))")"

    local natures n nature mods
    mapfile -t natures < <(encounter_natures_list)
    n="${#natures[@]}"
    nature="${natures[$((RANDOM % n))]}"
    mods="$(encounter_nature_mods "$nature")" || return 1

    local ability_obj ability is_hidden
    ability_obj="$(encounter_roll_ability "$variety")" || return 1
    ability="$(jq -r '.name' <<< "$ability_obj")"
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<< "$ability_obj")"

    local moves_json gender shiny
    moves_json="$(encounter_roll_moves "$variety" "$level")" || return 1
    gender="$(encounter_roll_gender "$sp")" || return 1
    shiny="$(encounter_roll_shiny)"

    local friendship
    friendship="$(encounter_roll_friendship "$sp")" || return 1

    local base_stats stats
    base_stats="$(jq -c '.stats' <<< "$poke")"
    stats="$(encounter_compute_all_stats "$base_stats" "$ivs" "$evs" "$level" "$mods")" || return 1

    local final_sprite="$sprite_url"
    [[ "$shiny" == "1" && -n "$sprite_url_shiny" ]] && final_sprite="$sprite_url_shiny"

    local ivs_json evs_json stats_json
    ivs_json="[$(printf '%s,' $ivs | sed 's/,$//')]"
    evs_json="[$(printf '%s,' $evs | sed 's/,$//')]"
    stats_json="[$(printf '%s,' $stats | sed 's/,$//')]"

    jq -n \
        --arg sp "$sp" --argjson dex "$dex_id" --argjson lvl "$level" \
        --arg nature "$nature" --arg ability "$ability" --argjson hidden "$is_hidden" \
        --arg gender "$gender" --argjson shiny "$shiny" \
        --argjson friendship "$friendship" \
        --argjson ivs "$ivs_json" --argjson evs "$evs_json" --argjson stats "$stats_json" \
        --argjson moves "$moves_json" --arg sprite "$final_sprite" '{
            species: $sp, dex_id: $dex, level: $lvl,
            nature: $nature, ability: $ability, is_hidden_ability: $hidden,
            gender: $gender, shiny: $shiny, held_berry: null,
            friendship: $friendship,
            ivs: $ivs, evs: $evs, stats: $stats,
            moves: $moves, sprite_url: $sprite,
            is_legendary: true
        }'
}
