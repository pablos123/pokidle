#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    load_lib showdown
    stub_pokeapi
    seed_showdown
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

@test "encounter_roll_ivs: exactly three perfect 31s, rest in range" {
    run encounter_roll_ivs
    [ "$status" -eq 0 ]
    read -ra ivs <<<"$output"
    [ "${#ivs[@]}" -eq 6 ]
    local perfect=0 v
    for v in "${ivs[@]}"; do
        [ "$v" -ge 0 ] && [ "$v" -le 31 ]
        if [ "$v" -eq 31 ]; then perfect=$((perfect + 1)); fi
    done
    [ "$perfect" -ge 3 ]
}

@test "encounter_roll_evs: 252/252/4 across three distinct stats" {
    run encounter_roll_evs
    [ "$status" -eq 0 ]
    read -ra evs <<<"$output"
    [ "${#evs[@]}" -eq 6 ]
    local sum=0 c252=0 c4=0 c0=0 v
    for v in "${evs[@]}"; do
        sum=$((sum + v))
        if [ "$v" -eq 252 ]; then c252=$((c252 + 1)); fi
        if [ "$v" -eq 4 ]; then c4=$((c4 + 1)); fi
        if [ "$v" -eq 0 ]; then c0=$((c0 + 1)); fi
    done
    [ "$sum" -eq 508 ]
    [ "$c252" -eq 2 ]
    [ "$c4" -eq 1 ]
    [ "$c0" -eq 3 ]
}

@test "encounter_roll_level: uniform within [min,max] inclusive" {
    local i out
    for i in {1..30}; do
        out="$(encounter_roll_level 5 8)"
        [ "$out" -ge 5 ] && [ "$out" -le 8 ]
    done
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
    local entry='{"species":"treecko","varieties":["treecko"],"min":5,"max":7}'
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
    export POKIDLE_CONFIG_DIR

    local entry='{"species":"treecko","varieties":["treecko"],"min":5,"max":7,"pct":100}'
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

@test "encounter_roll_pokemon: emits the encountered variety" {
    local entry='{"species":"treecko","varieties":["treecko"],"min":5,"max":7}'
    run encounter_roll_pokemon "$entry" "forest"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variety' <<< "$output")" = "treecko" ]
}

@test "encounter_roll_pokemon: honors the entry's qualifying form, not a random pick" {
    # A pool entry carrying varieties[] pins the form to a type-coherent one
    # (a steel biome's meowth must be meowth-galar). The random whole-species
    # picker must NOT run — stub it to a bogus name that would fail the fetch.
    encounter_pick_variety() { printf 'BOGUS-FORM'; }
    export -f encounter_pick_variety
    local entry='{"species":"treecko","varieties":["treecko"],"min":5,"max":7}'
    run encounter_roll_pokemon "$entry" "forest"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.variety' <<< "$output")" = "treecko" ]
}

@test "encounter_roll_item: rolls a member of the pool's items+berries" {
    POKIDLE_CACHE_DIR="$(mktemp -d "${BATS_TMPDIR}/cache.XXXXXX")"
    export POKIDLE_CACHE_DIR
    mkdir -p "${POKIDLE_CACHE_DIR}/pools"
    # Pool berries are stored bare (shared with the held_berry roll); as an item
    # drop they must carry the "-berry" item slug so the sprite/export lookups hit.
    printf '%s' '{"biome":"volcano","tiers":{},"berries":["rawst"],"items":["charcoal"]}' \
        > "${POKIDLE_CACHE_DIR}/pools/volcano.json"
    out="$(encounter_roll_item volcano)"
    name="$(jq -r '.item' <<<"$out")"
    [ "$name" = "charcoal" ] || [ "$name" = "rawst-berry" ]
}

@test "encounter_roll_item: berry-only pool always yields the -berry item slug" {
    POKIDLE_CACHE_DIR="$(mktemp -d "${BATS_TMPDIR}/cache.XXXXXX")"
    export POKIDLE_CACHE_DIR
    mkdir -p "${POKIDLE_CACHE_DIR}/pools"
    printf '%s' '{"biome":"volcano","tiers":{},"berries":["pomeg"],"items":[]}' \
        > "${POKIDLE_CACHE_DIR}/pools/volcano.json"
    out="$(encounter_roll_item volcano)"
    name="$(jq -r '.item' <<<"$out")"
    [ "$name" = "pomeg-berry" ]
}

@test "_encounter_variety_is_non_wild: flags battle/totem/event/cosmetic forms, allows base/regional" {
    _encounter_variety_is_non_wild charizard-mega-x
    _encounter_variety_is_non_wild charizard-mega-y
    _encounter_variety_is_non_wild gengar-mega
    _encounter_variety_is_non_wild venusaur-gmax
    _encounter_variety_is_non_wild kyogre-primal
    _encounter_variety_is_non_wild eternatus-eternamax
    _encounter_variety_is_non_wild gumshoos-totem
    _encounter_variety_is_non_wild raticate-totem-alola
    _encounter_variety_is_non_wild greninja-battle-bond
    _encounter_variety_is_non_wild ursaluna-bloodmoon
    _encounter_variety_is_non_wild pikachu-original-cap
    _encounter_variety_is_non_wild pikachu-cosplay
    _encounter_variety_is_non_wild pikachu-rock-star
    _encounter_variety_is_non_wild eevee-starter
    ! _encounter_variety_is_non_wild gengar
    ! _encounter_variety_is_non_wild meowth-galar
    ! _encounter_variety_is_non_wild raichu-alola
    ! _encounter_variety_is_non_wild lycanroc-midnight
}

@test "_encounter_form_is_battle_only: reads is_battle_only from /pokemon-form" {
    _encounter_form_is_battle_only aegislash-blade
    ! _encounter_form_is_battle_only meowth-galar
    # Unknown form (no fixture / 404) is treated as wild (not battle-only).
    ! _encounter_form_is_battle_only made-up-form
}

@test "encounter_pick_variety: never selects a battle-only form" {
    pokeapi_get() {
        case "$1" in
            pokemon-species/gengar)
                printf '%s' '{"varieties":[{"pokemon":{"name":"gengar"}},{"pokemon":{"name":"gengar-mega"}},{"pokemon":{"name":"gengar-gmax"}}]}'
                ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get
    local i v
    for i in $(seq 1 80); do
        v="$(encounter_pick_variety gengar)"
        case "$v" in
            *-mega | *-mega-x | *-mega-y | *-gmax | *-primal | *-eternamax)
                printf 'battle-only form leaked: %s\n' "$v" >&2
                return 1
                ;;
        esac
    done
    # gengar is the only non-battle-only survivor, so it must always be chosen.
    [ "$v" = "gengar" ]
}

@test "encounter_pick_variety: keeps regional formes selectable" {
    pokeapi_get() {
        case "$1" in
            pokemon-species/meowth)
                printf '%s' '{"varieties":[{"pokemon":{"name":"meowth"}},{"pokemon":{"name":"meowth-galar"}},{"pokemon":{"name":"meowth-gmax"}}]}'
                ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get
    local i v seen_base=0 seen_galar=0
    for i in $(seq 1 120); do
        v="$(encounter_pick_variety meowth)"
        [ "$v" = "meowth" ] && seen_base=1
        [ "$v" = "meowth-galar" ] && seen_galar=1
        [ "$v" = "meowth-gmax" ] && { printf 'gmax leaked\n' >&2; return 1; }
    done
    (( seen_base && seen_galar ))
}

@test "encounter_roll_ability_legal: hidden-rate 0 never picks the hidden ability" {
    POKIDLE_HIDDEN_ABILITY_RATE=0 run encounter_roll_ability_legal "corviknight"
    [ "$status" -eq 0 ]
    local name; name="$(echo "$output" | jq -r '.name')"
    [ "$name" = "pressure" ] || [ "$name" = "unnerve" ]
    echo "$output" | jq -e '.is_hidden == false'
}

@test "encounter_roll_ability_legal: hidden-rate 100 picks the hidden ability" {
    POKIDLE_HIDDEN_ABILITY_RATE=100 run encounter_roll_ability_legal "corviknight"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.name == "mirror-armor" and .is_hidden == true'
}

@test "encounter_roll_moves_legal: returns up to 4 legal move slugs" {
    run encounter_roll_moves_legal "corviknight" 50
    [ "$status" -eq 0 ]
    local n; n="$(echo "$output" | jq 'length')"
    [ "$n" -ge 1 ] && [ "$n" -le 4 ]
    echo "$output" | jq -e 'all(.[]; . | test("^[a-z0-9-]+$"))'
    # every chosen move is within the legal pool
    echo "$output" | jq -e 'all(.[]; IN("brave-bird","double-edge","fury-attack","peck"))'
}

@test "encounter_roll_ability_legal: showdown unavailable -> fails, never touches pokeapi" {
    showdown_legal_abilities() { return 1; }
    pokeapi_get() { touch "${BATS_TEST_TMPDIR}/papi_called"; return 1; }
    export -f showdown_legal_abilities pokeapi_get
    run encounter_roll_ability_legal "corviknight"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/papi_called" ]
}

@test "encounter_roll_ability_legal: empty legal set -> fails, never touches pokeapi" {
    showdown_legal_abilities() { printf '\n'; return 0; }
    pokeapi_get() { touch "${BATS_TEST_TMPDIR}/papi_called"; return 1; }
    export -f showdown_legal_abilities pokeapi_get
    run encounter_roll_ability_legal "corviknight"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/papi_called" ]
}

@test "encounter_roll_moves_legal: showdown unavailable -> fails, never touches pokeapi" {
    showdown_legal_moves() { return 1; }
    pokeapi_get() { touch "${BATS_TEST_TMPDIR}/papi_called"; return 1; }
    export -f showdown_legal_moves pokeapi_get
    run encounter_roll_moves_legal "corviknight" 50 "corviknight"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/papi_called" ]
}

@test "encounter_roll_moves_legal: empty legal pool -> fails, never touches pokeapi" {
    showdown_legal_moves() { printf '\n'; return 0; }
    pokeapi_get() { touch "${BATS_TEST_TMPDIR}/papi_called"; return 1; }
    export -f showdown_legal_moves pokeapi_get
    run encounter_roll_moves_legal "corviknight" 50 "corviknight"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/papi_called" ]
}

@test "encounter_roll_importable: retries until a roll succeeds" {
    encounter_roll_pool_entry() { printf '{"species":"x","varieties":["x"],"min":5,"max":7}'; }
    encounter_roll_pokemon() {
        local c="${BATS_TEST_TMPDIR}/n"; local -i n=0
        [[ -f "$c" ]] && n="$(cat "$c")"; n=$((n+1)); printf '%s' "$n" > "$c"
        if ((n < 3)); then return 1; fi
        printf '{"species":"x","moves":["a","b","c","d"]}'
    }
    export -f encounter_roll_pool_entry encounter_roll_pokemon
    run encounter_roll_importable '{}' forest 3
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "x" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/n")" = "3" ]
}

@test "encounter_roll_importable: returns 1 after N failed tries" {
    encounter_roll_pool_entry() { printf '{"species":"x","varieties":["x"]}'; }
    encounter_roll_pokemon() {
        local c="${BATS_TEST_TMPDIR}/n"; local -i n=0
        [[ -f "$c" ]] && n="$(cat "$c")"; printf '%s' "$((n+1))" > "$c"
        return 1
    }
    export -f encounter_roll_pool_entry encounter_roll_pokemon
    run encounter_roll_importable '{}' forest 3
    [ "$status" -ne 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/n")" = "3" ]
}

@test "encounter_evolution_items: lists the PokeAPI evolution category" {
    run encounter_evolution_items
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "fire-stone"
}

@test "encounter_roll_pickup: returns item key, no sprite fetch" {
    local out item
    out="$(encounter_roll_pickup)"
    item="$(jq -r '.item' <<< "$out")"
    [ -n "$item" ]
    [ "$item" != "null" ]
    # Sprite is resolved by the tick, not the roll; no dead sprite_url field.
    run jq -e 'has("sprite_url")' <<<"$out"
    [ "$status" -ne 0 ]
}

@test "encounter_roll_pickup: rate 0 picks a typeless holdable item" {
    POKIDLE_EVOLUTION_ITEM_RATE=0 run encounter_roll_pickup
    [ "$status" -eq 0 ]
    name="$(jq -r '.item' <<<"$output")"
    echo "$name" | grep -qxE "leftovers|choice-band|life-orb"
}

@test "encounter_roll_pickup: rate 100 picks an evolution item" {
    POKIDLE_EVOLUTION_ITEM_RATE=100 run encounter_roll_pickup
    [ "$status" -eq 0 ]
    name="$(jq -r '.item' <<<"$output")"
    echo "$name" | grep -qxE "fire-stone|water-stone"
}

@test "encounter_roll_pickup: form-item rate 100 picks a form item" {
    printf 'charizardite-x\tcharizard\n' > "$POKIDLE_SHOWDOWN_CACHE_DIR/form-items.tsv"
    POKIDLE_FORM_ITEM_RATE=100 run encounter_roll_pickup
    [ "$status" -eq 0 ]
    [ "$(jq -r '.item' <<<"$output")" = "charizardite-x" ]
}

@test "encounter_roll_pickup: form-item rate 0 never picks a form item" {
    printf 'charizardite-x\tcharizard\n' > "$POKIDLE_SHOWDOWN_CACHE_DIR/form-items.tsv"
    POKIDLE_FORM_ITEM_RATE=0 POKIDLE_EVOLUTION_ITEM_RATE=0 run encounter_roll_pickup
    [ "$status" -eq 0 ]
    [ "$(jq -r '.item' <<<"$output")" != "charizardite-x" ]
}

@test "encounter_roll_pickup: fails gracefully when no data available" {
    # Override both sources to return nothing; should return non-zero.
    showdown_typeless_holdable_items() { return 1; }
    encounter_evolution_items() { return 1; }
    export -f showdown_typeless_holdable_items encounter_evolution_items
    run encounter_roll_pickup
    [ "$status" -ne 0 ]
}
