#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    export POKIDLE_DB_PATH
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib db
    db_init
}

teardown() {
    rm -f "$POKIDLE_DB_PATH"
}

# Source pokidle as a library by extracting its functions.
# We do this by sourcing the script with a guard so it doesn't dispatch.
source_pokidle_lib() {
    POKIDLE_TEST_SOURCE_ONLY=1 source "$REPO_ROOT/pokidle"
}

@test "schedule_next_tick: target is in [next_hour, next_hour+interval)" {
    POKIDLE_POKEMON_INTERVAL=3600
    source_pokidle_lib
    local now=1700000000   # epoch
    local next
    next="$(_pokidle_next_tick_target "$now" "$POKIDLE_POKEMON_INTERVAL")"
    local hour_floor=$((now / 3600 * 3600))
    local next_hour=$((hour_floor + 3600))
    [ "$next" -ge "$next_hour" ]
    [ "$next" -lt "$((next_hour + 3600))" ]
}

@test "_pokidle_tick_missed: on-time wake is not missed (fires)" {
    source_pokidle_lib
    # Loop wakes right at target: now - target is tiny.
    run _pokidle_tick_missed 1700003600 1700003600 3600
    [ "$status" -ne 0 ]
}

@test "_pokidle_tick_missed: small lateness (tick duration) is not missed" {
    source_pokidle_lib
    # 30s late (e.g. previous tick's network time): still a real fire.
    run _pokidle_tick_missed 1700003630 1700003600 3600
    [ "$status" -ne 0 ]
}

@test "_pokidle_tick_missed: a full interval elapsed past target is missed (skip)" {
    source_pokidle_lib
    run _pokidle_tick_missed $((1700003600 + 3600)) 1700003600 3600
    [ "$status" -eq 0 ]
}

@test "_pokidle_tick_missed: multi-hour downtime is missed (skip)" {
    source_pokidle_lib
    # Laptop suspended overnight: wall-clock jumped 5h past target.
    run _pokidle_tick_missed $((1700003600 + 5 * 3600)) 1700003600 3600
    [ "$status" -eq 0 ]
}

@test "_pokidle_sleep_chunk: gap longer than cap is capped" {
    source_pokidle_lib
    # next_event 1h out, default cap 60s -> sleep only 60.
    run _pokidle_sleep_chunk 1700003600 1700000000
    [ "$output" -eq 60 ]
}

@test "_pokidle_sleep_chunk: gap shorter than cap sleeps the gap" {
    source_pokidle_lib
    run _pokidle_sleep_chunk 1700000010 1700000000
    [ "$output" -eq 10 ]
}

@test "_pokidle_sleep_chunk: non-positive gap floors at 1" {
    source_pokidle_lib
    run _pokidle_sleep_chunk 1700000000 1700000005
    [ "$output" -eq 1 ]
}

@test "_pokidle_sleep_chunk: cap honors POKIDLE_SLEEP_CHUNK" {
    POKIDLE_SLEEP_CHUNK=30 source_pokidle_lib
    run env POKIDLE_SLEEP_CHUNK=30 bash -c '
        POKIDLE_TEST_SOURCE_ONLY=1 source "'"$REPO_ROOT"'/pokidle"
        _pokidle_sleep_chunk 1700003600 1700000000'
    [ "$output" -eq 30 ]
}

@test "_pokidle_should_rotate_biome: 3h elapsed yes" {
    POKIDLE_BIOME_HOURS=3
    source_pokidle_lib
    local now=1700010800   # 3h+ after 1700000000
    run _pokidle_should_rotate_biome 1700000000 "$now"
    [ "$status" -eq 0 ]
}

@test "_pokidle_should_rotate_biome: 1h elapsed no" {
    POKIDLE_BIOME_HOURS=3
    source_pokidle_lib
    local now=1700003600
    run _pokidle_should_rotate_biome 1700000000 "$now"
    [ "$status" -ne 0 ]
}

@test "_pokidle_biome_time_left: live session prints positive seconds" {
    POKIDLE_BIOME_HOURS=3
    source_pokidle_lib
    run _pokidle_biome_time_left 1700000000 $((1700000000 + 600))
    [ "$status" -eq 0 ]
    [ "$output" = "10200s" ]
}

@test "_pokidle_biome_time_left: overdue session (long shutdown) clamps, not negative" {
    POKIDLE_BIOME_HOURS=3
    source_pokidle_lib
    # session left open across a ~15-day shutdown, before the daemon rotates it
    run _pokidle_biome_time_left 1700000000 $((1700000000 + 15 * 86400))
    [ "$status" -eq 0 ]
    [ "$output" = "0s (rotation pending)" ]
}

@test "schedule_next_tick: POKIDLE_TICK_FAST=1 uses cadence in [now, now+interval)" {
    POKIDLE_TICK_FAST=1 source_pokidle_lib
    local now=1700000000
    local interval=60
    local next
    next="$(POKIDLE_TICK_FAST=1 _pokidle_next_tick_target "$now" "$interval")"
    [ "$next" -ge "$now" ]
    [ "$next" -lt "$((now + interval))" ]
}

@test "pokidle_tick item: a failed roll fails the tick, no empty drop/output (daemon if-! context)" {
    source_pokidle_lib
    # Open biome session so the tick resolves a biome.
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    # Simulate a PokeAPI fetch failure during the item lookup.
    pokeapi_get() { return 1; }
    export -f pokeapi_get
    # The daemon invokes this under `if ! pokidle_tick item`, which suppresses
    # set -e — a failed roll must return nonzero, not fall through to an empty
    # drop and a bogus "Found " notification.
    local out="$BATS_TMPDIR/item.$$"
    if pokidle_tick item --no-dry-run --no-notify --json >"$out" 2>/dev/null; then
        fired=1
    else
        fired=0
    fi
    [ "$fired" = "0" ]      # tick reported failure
    [ ! -s "$out" ]         # emitted no bogus item line
    local n
    n="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops;")"
    [ "$n" = "0" ]          # wrote no empty-name row
}

@test "pokidle_tick pokemon: a failed roll fails the tick, no empty encounter/output (daemon if-! context)" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    printf '%s' '{"biome":"cave","tiers":{"common":[{"species":"zubat","varieties":["zubat"],"min":5,"max":7}],"uncommon":[],"rare":[],"very_rare":[]}}' \
        > "$POKIDLE_CACHE_DIR/pools/cave.json"
    source_pokidle_lib
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    # Simulate a PokeAPI fetch failure during the pokemon lookup.
    pokeapi_get() { return 1; }
    export -f pokeapi_get
    local out="$BATS_TMPDIR/pkmn.$$"
    if pokidle_tick pokemon --no-dry-run --no-notify --json >"$out" 2>/dev/null; then
        fired=1
    else
        fired=0
    fi
    rm -rf "$POKIDLE_CACHE_DIR"
    [ "$fired" = "0" ]      # tick reported failure instead of falling through
    [ ! -s "$out" ]         # emitted no bogus encounter line
    local n
    n="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$n" = "0" ]
}

@test "pokidle_daemon run dispatches to the blocking loop (_pokidle_daemon_run)" {
    source_pokidle_lib
    # Replace the loop body with a sentinel so we test dispatch, not the loop.
    _pokidle_daemon_run() { printf 'RAN_LOOP:%s' "$*"; }
    run pokidle_daemon run --whatever
    [ "$status" -eq 0 ]
    [[ "$output" == "RAN_LOOP:--whatever" ]]
}

@test "pokidle_daemon with no verb exits 2 without entering the loop" {
    source_pokidle_lib
    _pokidle_daemon_run() { printf 'RAN_LOOP'; }
    run pokidle_daemon
    [ "$status" -eq 2 ]
    [[ "$output" != *"RAN_LOOP"* ]]
}

@test "daemon: persists last_legendary_tick_target on first start" {
    POKIDLE_TICK_FAST=1
    POKIDLE_NO_NOTIFY=1
    POKIDLE_LEGENDARY_CHANCE=0
    POKIDLE_LEGENDARY_INTERVAL=86400
    POKIDLE_CONFIG_DIR="$REPO_ROOT/config"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    # Seed a pool for at least one biome so biome rotation can pick.
    load_lib biome
    local id
    id="$(biome_ids | head -n 1)"
    jq -n --arg b "$id" '
        {biome: $b, tiers: {
            common: [range(0; 50) | {species: ("s\(.))"), varieties: [("s\(.))")], min: 5, max: 8}],
            uncommon: [], rare: [], very_rare: []
        }}
    ' > "$POKIDLE_CACHE_DIR/pools/$id.json"
    export POKIDLE_TICK_FAST POKIDLE_NO_NOTIFY POKIDLE_LEGENDARY_CHANCE \
           POKIDLE_LEGENDARY_INTERVAL POKIDLE_CONFIG_DIR POKIDLE_CACHE_DIR
    timeout 5 "$REPO_ROOT/pokidle" daemon run >/dev/null 2>&1 || true
    rm -rf "$POKIDLE_CACHE_DIR"
    local val
    val="$(sqlite3 "$POKIDLE_DB_PATH" \
        "SELECT value FROM daemon_state WHERE key='last_legendary_tick_target';")"
    [ -n "$val" ]
    [[ "$val" =~ ^[0-9]+$ ]]
}
