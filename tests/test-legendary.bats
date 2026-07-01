#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    export POKIDLE_REPO_ROOT POKIDLE_CONFIG_DIR
    load_lib legendary
}

@test "legendary_roll_species_for_biome: returns an entry from the biome pool's .legendaries" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib encounter
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<'EOF'
{"biome":"forest","tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],
 "legendaries":[{"species":"celebi","varieties":["celebi"]},{"species":"virizion","varieties":["virizion"]}]}
EOF
    run legendary_roll_species_for_biome forest
    [ "$status" -eq 0 ]
    local sp
    sp="$(jq -r '.species' <<< "$output")"
    [[ "$sp" == "celebi" || "$sp" == "virizion" ]]
    echo "$output" | jq -e '.varieties | length > 0'
}

@test "legendary_roll_importable: retries until a build succeeds" {
    legendary_roll_species_for_biome() { printf '{"species":"x","varieties":["x"]}'; }
    legendary_build_encounter() {
        local c="${BATS_TEST_TMPDIR}/n"; local -i n=0
        [[ -f "$c" ]] && n="$(cat "$c")"; n=$((n+1)); printf '%s' "$n" > "$c"
        if ((n < 2)); then return 1; fi
        printf '{"species":"x","is_legendary":true}'
    }
    export -f legendary_roll_species_for_biome legendary_build_encounter
    run legendary_roll_importable forest 3
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "x" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/n")" = "2" ]
}

@test "legendary_roll_importable: returns 1 after N failed tries" {
    legendary_roll_species_for_biome() { printf '{"species":"x","varieties":["x"]}'; }
    legendary_build_encounter() {
        local c="${BATS_TEST_TMPDIR}/n"; local -i n=0
        [[ -f "$c" ]] && n="$(cat "$c")"; printf '%s' "$((n+1))" > "$c"
        return 1
    }
    export -f legendary_roll_species_for_biome legendary_build_encounter
    run legendary_roll_importable forest 3
    [ "$status" -ne 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/n")" = "3" ]
}

@test "legendary_roll_species_for_biome: empty .legendaries returns 1" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib encounter
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<'EOF'
{"biome":"forest","tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],"legendaries":[]}
EOF
    run legendary_roll_species_for_biome forest
    [ "$status" -ne 0 ]
}

@test "legendary_roll_species_for_biome: missing pool file returns 1" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib encounter
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    # No pool file written for this biome.
    run legendary_roll_species_for_biome forest
    [ "$status" -ne 0 ]
}

@test "legendary_build_encounter: returns encounter JSON with all required fields" {
    POKIDLE_LEGENDARY_LEVEL_MIN=50
    POKIDLE_LEGENDARY_LEVEL_MAX=70
    export POKIDLE_LEGENDARY_LEVEL_MIN POKIDLE_LEGENDARY_LEVEL_MAX
    load_lib encounter
    load_lib showdown
    stub_pokeapi
    seed_showdown
    local enc
    enc="$(legendary_build_encounter '{"species":"articuno","varieties":["articuno"]}' forest)"
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
    load_lib showdown
    stub_pokeapi
    seed_showdown
    # /pokemon/shaymin 404s on real PokeAPI; only /pokemon/shaymin-{land,sky} exist.
    # No pokemon-shaymin.json fixture is provided on purpose — fix must read
    # /pokemon-species/shaymin → varieties[] and pick one (land OR sky).
    local enc
    enc="$(legendary_build_encounter '{"species":"shaymin","varieties":["shaymin-land","shaymin-sky"]}' forest)"
    [ -n "$enc" ]
    [ "$(jq -r '.species' <<< "$enc")" = "shaymin" ]
    [ "$(jq -r '.is_legendary' <<< "$enc")" = "true" ]
    local dex lvl
    dex="$(jq -r '.dex_id' <<< "$enc")"
    [[ "$dex" == "492" || "$dex" == "10006" ]]
    lvl="$(jq -r '.level' <<< "$enc")"
    [ "$lvl" -ge 50 ] && [ "$lvl" -le 70 ]
}

@test "legendary_build_encounter stores the variety field" {
    POKIDLE_LEGENDARY_LEVEL_MIN=50
    POKIDLE_LEGENDARY_LEVEL_MAX=70
    export POKIDLE_LEGENDARY_LEVEL_MIN POKIDLE_LEGENDARY_LEVEL_MAX
    load_lib encounter
    load_lib showdown
    stub_pokeapi
    seed_showdown
    run legendary_build_encounter '{"species":"articuno","varieties":["articuno"]}' forest
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("variety") and (.variety | length > 0)'
}

@test "legendary_build_encounter: 3 perfect IVs and 252/252/4 EVs" {
    POKIDLE_LEGENDARY_LEVEL_MIN=50
    POKIDLE_LEGENDARY_LEVEL_MAX=70
    export POKIDLE_LEGENDARY_LEVEL_MIN POKIDLE_LEGENDARY_LEVEL_MAX
    load_lib encounter
    load_lib showdown
    stub_pokeapi
    seed_showdown
    run legendary_build_encounter '{"species":"articuno","varieties":["articuno"]}' forest
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '([.ivs[] | select(. == 31)] | length) >= 3'
    echo "$output" | jq -e '(.evs | add) == 508 and ([.evs[]|select(.==252)]|length)==2'
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
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<'EOF'
{"biome":"forest","tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],
 "legendaries":[{"species":"articuno","varieties":["articuno"]}]}
EOF
    stub_pokeapi
    seed_showdown
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
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<'EOF'
{"biome":"forest","tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],
 "legendaries":[{"species":"articuno","varieties":["articuno"]}]}
EOF
    stub_pokeapi
    seed_showdown
    run "$REPO_ROOT/pokidle" tick legendary --no-dry-run --json
    [ "$status" -eq 0 ]
    local count sp
    count="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$count" = "1" ]
    sp="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT species FROM encounters LIMIT 1;")"
    [ "$sp" = "articuno" ]
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
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<'EOF'
{"biome":"forest","tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],
 "legendaries":[{"species":"articuno","varieties":["articuno"]}]}
EOF
    stub_pokeapi
    seed_showdown
    run "$REPO_ROOT/pokidle" tick legendary --no-dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no spawn"* ]]
    local count
    count="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$count" = "0" ]
}
