#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cp "$REPO_ROOT/config/biomes.json" "$POKIDLE_CONFIG_DIR/biomes.json"
    export POKIDLE_REPO_ROOT POKIDLE_CONFIG_DIR
    load_lib legendary
}

@test "LEGENDARY_TYPES: contains canonical gen-1 legendaries with correct types" {
    [ "${LEGENDARY_TYPES[articuno]}" = "ice flying" ]
    [ "${LEGENDARY_TYPES[zapdos]}" = "electric flying" ]
    [ "${LEGENDARY_TYPES[moltres]}" = "fire flying" ]
    [ "${LEGENDARY_TYPES[mewtwo]}" = "psychic" ]
    [ "${LEGENDARY_TYPES[mew]}" = "psychic" ]
}

@test "LEGENDARY_TYPES: contains gen-7+ entries" {
    [ -n "${LEGENDARY_TYPES[tapu-koko]:-}" ]
    [ -n "${LEGENDARY_TYPES[zacian]:-}" ]
}

@test "LEGENDARY_TYPES: every PokeAPI primary type has at least one legendary" {
    local types=(
        normal fighting flying poison ground rock bug ghost steel
        fire water grass electric psychic ice dragon dark fairy
    )
    local t sp found
    for t in "${types[@]}"; do
        found=0
        for sp in "${!LEGENDARY_TYPES[@]}"; do
            if [[ " ${LEGENDARY_TYPES[$sp]} " == *" $t "* ]]; then
                found=1
                break
            fi
        done
        if (( ! found )); then
            printf 'no legendary for type %s\n' "$t" >&2
            return 1
        fi
    done
}

@test "legendary_roll_species_for_biome: returns a legendary whose types match biome" {
    load_lib biome
    local sp types t btypes match
    sp="$(legendary_roll_species_for_biome forest)"
    [ -n "${LEGENDARY_TYPES[$sp]:-}" ]
    types="${LEGENDARY_TYPES[$sp]}"
    btypes="$(biome_types_for forest)"
    match=0
    for t in $types; do
        while IFS= read -r b; do
            [[ "$t" == "$b" ]] && match=1 && break
        done <<< "$btypes"
        (( match )) && break
    done
    [ "$match" = "1" ]
}

@test "legendary_roll_species_for_biome: ice biome rolls only ice/flying-typed legendaries (sample)" {
    load_lib biome
    # ocean = water + ice
    local i sp types ok=1
    for i in {1..20}; do
        sp="$(legendary_roll_species_for_biome ocean)"
        types="${LEGENDARY_TYPES[$sp]:-}"
        # at least one type must be water or ice
        if [[ "$types" != *water* && "$types" != *ice* ]]; then
            ok=0
            printf 'roll %s has types "%s" but biome ocean is water+ice\n' "$sp" "$types" >&2
            break
        fi
    done
    [ "$ok" = "1" ]
}

@test "legendary_build_encounter: returns encounter JSON with all required fields" {
    POKIDLE_LEGENDARY_LEVEL_MIN=50
    POKIDLE_LEGENDARY_LEVEL_MAX=70
    export POKIDLE_LEGENDARY_LEVEL_MIN POKIDLE_LEGENDARY_LEVEL_MAX
    load_lib encounter
    stub_pokeapi
    local enc
    enc="$(legendary_build_encounter articuno forest)"
    [ -n "$enc" ]
    local sp lvl shiny is_leg
    sp="$(jq -r '.species' <<< "$enc")"
    lvl="$(jq -r '.level' <<< "$enc")"
    shiny="$(jq -r '.shiny' <<< "$enc")"
    is_leg="$(jq -r '.is_legendary' <<< "$enc")"
    [ "$sp" = "articuno" ]
    [ "$lvl" -ge 50 ] && [ "$lvl" -le 70 ]
    [[ "$shiny" =~ ^[01]$ ]]
    [ "$is_leg" = "true" ]
    local berry
    berry="$(jq -r '.held_berry' <<< "$enc")"
    [ "$berry" = "null" ]
}

@test "legendary_build_encounter: picks a variety for forme-bearing species (shaymin)" {
    POKIDLE_LEGENDARY_LEVEL_MIN=50
    POKIDLE_LEGENDARY_LEVEL_MAX=70
    export POKIDLE_LEGENDARY_LEVEL_MIN POKIDLE_LEGENDARY_LEVEL_MAX
    load_lib encounter
    stub_pokeapi
    # /pokemon/shaymin 404s on real PokeAPI; only /pokemon/shaymin-{land,sky} exist.
    # No pokemon-shaymin.json fixture is provided on purpose — fix must read
    # /pokemon-species/shaymin → varieties[] and pick one (land OR sky).
    local enc
    enc="$(legendary_build_encounter shaymin forest)"
    [ -n "$enc" ]
    [ "$(jq -r '.species' <<< "$enc")" = "shaymin" ]
    [ "$(jq -r '.is_legendary' <<< "$enc")" = "true" ]
    local dex lvl
    dex="$(jq -r '.dex_id' <<< "$enc")"
    [[ "$dex" == "492" || "$dex" == "10006" ]]
    lvl="$(jq -r '.level' <<< "$enc")"
    [ "$lvl" -ge 50 ] && [ "$lvl" -le 70 ]
}

@test "tick legendary --dry-run: rolls but does not insert" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_LEGENDARY_CHANCE=100
    POKIDLE_NO_NOTIFY=1
    export POKIDLE_DB_PATH POKIDLE_LEGENDARY_CHANCE POKIDLE_NO_NOTIFY
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('forest', 1700000000);"
    run "$REPO_ROOT/pokidle" tick legendary --dry-run
    [ "$status" -eq 0 ]
    local count
    count="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$count" = "0" ]
}

@test "tick legendary --no-dry-run: inserts encounter when chance is 100" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_LEGENDARY_CHANCE=100
    POKIDLE_NO_NOTIFY=1
    export POKIDLE_DB_PATH POKIDLE_LEGENDARY_CHANCE POKIDLE_NO_NOTIFY
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('forest', 1700000000);"
    run "$REPO_ROOT/pokidle" tick legendary --no-dry-run --json
    [ "$status" -eq 0 ]
    local count sp
    count="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$count" = "1" ]
    sp="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT species FROM encounters LIMIT 1;")"
    [ -n "${LEGENDARY_TYPES[$sp]:-}" ]
}

@test "tick legendary: no spawn when chance is 0" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_LEGENDARY_CHANCE=0
    POKIDLE_NO_NOTIFY=1
    export POKIDLE_DB_PATH POKIDLE_LEGENDARY_CHANCE POKIDLE_NO_NOTIFY
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('forest', 1700000000);"
    run "$REPO_ROOT/pokidle" tick legendary --no-dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no spawn"* ]]
    local count
    count="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$count" = "0" ]
}
