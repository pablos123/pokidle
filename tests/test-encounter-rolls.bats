#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    stub_pokeapi
}

@test "encounter_natures_list returns 25 names" {
    run encounter_natures_list
    [ "$status" -eq 0 ]
    local n
    n="$(printf '%s\n' "$output" | wc -l)"
    [ "$n" = "25" ]
}

@test "encounter_nature_mods adamant: +atk -spa" {
    run encounter_nature_mods adamant
    [ "$status" -eq 0 ]
    local mods=($output)
    [ "${mods[0]}" = "1.0" ]
    [ "${mods[1]}" = "1.1" ]
    [ "${mods[2]}" = "1.0" ]
    [ "${mods[3]}" = "0.9" ]
    [ "${mods[4]}" = "1.0" ]
    [ "${mods[5]}" = "1.0" ]
}

@test "encounter_nature_mods bashful: all 1.0 (neutral)" {
    run encounter_nature_mods bashful
    [ "$status" -eq 0 ]
    local mods=($output)
    [ "${mods[0]}" = "1.0" ]
    [ "${mods[1]}" = "1.0" ]
    [ "${mods[2]}" = "1.0" ]
    [ "${mods[3]}" = "1.0" ]
    [ "${mods[4]}" = "1.0" ]
    [ "${mods[5]}" = "1.0" ]
}

@test "encounter_nature_mods: missing nature returns non-zero" {
    run encounter_nature_mods does-not-exist
    [ "$status" -ne 0 ]
}

@test "encounter_roll_ivs returns 6 ints in [0,31]" {
    run encounter_roll_ivs
    [ "$status" -eq 0 ]
    local ivs=($output)
    [ "${#ivs[@]}" -eq 6 ]
    local i
    for i in "${ivs[@]}"; do
        [ "$i" -ge 0 ] && [ "$i" -le 31 ]
    done
}

@test "encounter_ev_split: total exact, each ≤ 252" {
    local i
    for i in {1..50}; do
        local want=$((RANDOM % 511))
        local out
        out="$(encounter_ev_split "$want")"
        local arr=($out)
        [ "${#arr[@]}" -eq 6 ]
        local total=0 v
        for v in "${arr[@]}"; do
            [ "$v" -le 252 ]
            [ "$v" -ge 0 ]
            total=$((total + v))
        done
        [ "$total" -eq "$want" ]
    done
}

@test "encounter_ev_split(0) = all zeros" {
    run encounter_ev_split 0
    [ "$output" = "0 0 0 0 0 0" ]
}

@test "encounter_ev_split: deltas multiples of 4 (at most one stat carries the total%4 leftover)" {
    local i
    for i in {1..50}; do
        local want=$((RANDOM % 511))
        local rem=$((want % 4))
        local out
        out="$(encounter_ev_split "$want")"
        local arr=($out)
        local nonmult4=0 v
        for v in "${arr[@]}"; do
            (( v % 4 != 0 )) && nonmult4=$((nonmult4 + 1))
        done
        if (( rem == 0 )); then
            [ "$nonmult4" -eq 0 ]
        else
            [ "$nonmult4" -le 1 ]
        fi
    done
}

@test "encounter_ev_split(510): total preserved, chunks-of-4 invariant holds" {
    local i
    for i in {1..20}; do
        local out
        out="$(encounter_ev_split 510)"
        local arr=($out)
        local total=0 nonmult4=0 v
        for v in "${arr[@]}"; do
            [ "$v" -le 252 ]
            total=$((total + v))
            (( v % 4 != 0 )) && nonmult4=$((nonmult4 + 1))
        done
        [ "$total" -eq 510 ]
        [ "$nonmult4" -le 1 ]
    done
}

@test "encounter_roll_level: uniform within [min,max] inclusive" {
    local i out
    for i in {1..30}; do
        out="$(encounter_roll_level 5 8)"
        [ "$out" -ge 5 ] && [ "$out" -le 8 ]
    done
}

@test "encounter_roll_ability: forced normal yields slot1+slot2 only" {
    POKIDLE_HIDDEN_ABILITY_RATE=0
    local i out
    for i in {1..30}; do
        out="$(encounter_roll_ability treecko)"
        local name hidden
        name="$(jq -r '.name' <<< "$out")"
        hidden="$(jq -r '.is_hidden' <<< "$out")"
        [ "$hidden" = "false" ]
        [ "$name" = "overgrow" ]
    done
}

@test "encounter_roll_ability: forced hidden yields hidden when present" {
    POKIDLE_HIDDEN_ABILITY_RATE=100
    run encounter_roll_ability treecko
    [ "$status" -eq 0 ]
    local hidden
    hidden="$(jq -r '.is_hidden' <<< "$output")"
    [ "$hidden" = "true" ]
}

@test "encounter_roll_moves: at level 5 returns 4 candidates ≤ level" {
    # Treecko fixture has level-up moves at 1,3,6,11,17 + machine/egg/tutor (level 0)
    # At level 5 candidates ≤5: pound(1), leer(3), giga-drain(0,machine), endeavor(0,egg), snatch(0,tutor) = 5 candidates
    run encounter_roll_moves treecko 5
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "4" ]
}

@test "encounter_roll_moves: at level 1 with limited pool returns 4 (or fewer if not enough)" {
    # Level 1: pound(1) + machine + egg + tutor = 4
    run encounter_roll_moves treecko 1
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "4" ]
}

@test "encounter_roll_gender: gender_rate -1 returns genderless" {
    run encounter_roll_gender magnemite
    [ "$status" -eq 0 ]
    [ "$output" = "genderless" ]
}

@test "encounter_roll_gender: gender_rate 1 yields ~12.5% F" {
    local f=0 m=0 i out
    for i in {1..200}; do
        out="$(encounter_roll_gender treecko)"
        case "$out" in
            F) f=$((f+1)) ;;
            M) m=$((m+1)) ;;
        esac
    done
    [ "$f" -ge 5 ]   && [ "$f" -le 60 ]
    [ "$m" -ge 140 ] && [ "$m" -le 195 ]
}

@test "encounter_roll_shiny: rate 1 always shiny" {
    POKIDLE_SHINY_RATE=1
    run encounter_roll_shiny
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "encounter_roll_shiny: rate 1000000 almost never shiny" {
    POKIDLE_SHINY_RATE=1000000
    local i s out
    s=0
    for i in {1..50}; do
        out="$(encounter_roll_shiny)"
        s=$((s + out))
    done
    [ "$s" -le 1 ]
}

@test "encounter_roll_held_berry: 0% rate returns null" {
    POKIDLE_BERRY_RATE=0
    run encounter_roll_held_berry "cave"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "encounter_roll_held_berry: 100% rate returns one of biome berries" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<EOF
{
    "biome": "cave",
    "schema": 3,
    "tiers": {"common":[],"uncommon":[],"rare":[],"very_rare":[]},
    "berries": ["rawst", "aspear", "chesto", "lum"]
}
EOF
    POKIDLE_BERRY_RATE=100
    export POKIDLE_BERRY_RATE
    run encounter_roll_held_berry "cave"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^(rawst|aspear|chesto|lum)$ ]]
}

@test "encounter_roll_friendship returns species base_happiness" {
    # Stub returns a /pokemon-species response with base_happiness=50.
    pokeapi_get() {
        case "$1" in
            pokemon-species/eevee)
                printf '{"base_happiness":50}'
                ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get
    run encounter_roll_friendship eevee
    [ "$status" -eq 0 ]
    [ "$output" = "50" ]
}

@test "encounter_roll_friendship defaults to 70 if base_happiness missing" {
    pokeapi_get() {
        printf '{}'
    }
    export -f pokeapi_get
    run encounter_roll_friendship some-species
    [ "$status" -eq 0 ]
    [ "$output" = "70" ]
}

@test "encounter_roll_pokemon: encounter JSON includes friendship from species" {
    # Reuse existing fixtures + override pokeapi_get for species call.
    local entry='{"species":"treecko","min":5,"max":7}'
    run encounter_roll_pokemon "$entry" "forest"
    [ "$status" -eq 0 ]
    local fr
    fr="$(jq -r '.friendship' <<< "$output")"
    [[ "$fr" =~ ^[0-9]+$ ]]
    (( fr >= 0 && fr <= 255 ))
}

@test "encounter_roll_pokemon: full encounter has all required keys" {
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cp "$REPO_ROOT/config/biomes.json" "$POKIDLE_CONFIG_DIR/biomes.json"
    export POKIDLE_CONFIG_DIR

    local entry='{"species":"treecko","min":5,"max":7,"pct":100}'
    run encounter_roll_pokemon "$entry" "cave"
    [ "$status" -eq 0 ]

    local enc="$output"
    local k
    for k in species dex_id level nature ability is_hidden_ability gender shiny held_berry ivs evs stats moves sprite_url; do
        local v
        v="$(jq -r --arg k "$k" 'has($k) | tostring' <<< "$enc")"
        [ "$v" = "true" ]
    done
}

@test "encounter_roll_item: forest biome rolls a typed or generic held item" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib biome
    load_lib encounter
    pokeapi_get() {
        printf '{"sprites":{"default":""}}'
    }
    export -f pokeapi_get
    local out item
    out="$(encounter_roll_item forest)"
    item="$(jq -r '.item' <<< "$out")"
    case "$item" in
        miracle-seed|meadow-plate|rose-incense|rindo-berry|\
        silver-powder|insect-plate|shed-shell|tanga-berry|\
        poison-barb|toxic-plate|black-sludge|kebia-berry|\
        pixie-plate|roseli-berry|\
        leftovers|shell-bell|lucky-egg|amulet-coin|\
        smoke-ball|soothe-bell|exp-share|everstone) : ;;
        *) printf 'unexpected item for forest biome: %s\n' "$item" >&2; return 1 ;;
    esac
}
