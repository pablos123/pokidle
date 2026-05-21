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

@test "schedule_next_tick: POKIDLE_TICK_FAST=1 uses cadence in [now, now+interval)" {
    POKIDLE_TICK_FAST=1 source_pokidle_lib
    local now=1700000000
    local interval=60
    local next
    next="$(POKIDLE_TICK_FAST=1 _pokidle_next_tick_target "$now" "$interval")"
    [ "$next" -ge "$now" ]
    [ "$next" -lt "$((now + interval))" ]
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
        {biome: $b, schema: 3, tiers: {
            common: [range(0; 50) | {species: ("s\(.))"), min: 5, max: 8}],
            uncommon: [], rare: [], very_rare: []
        }}
    ' > "$POKIDLE_CACHE_DIR/pools/$id.json"
    export POKIDLE_TICK_FAST POKIDLE_NO_NOTIFY POKIDLE_LEGENDARY_CHANCE \
           POKIDLE_LEGENDARY_INTERVAL POKIDLE_CONFIG_DIR POKIDLE_CACHE_DIR
    timeout 5 "$REPO_ROOT/pokidle" daemon >/dev/null 2>&1 || true
    rm -rf "$POKIDLE_CACHE_DIR"
    local val
    val="$(sqlite3 "$POKIDLE_DB_PATH" \
        "SELECT value FROM daemon_state WHERE key='last_legendary_tick_target';")"
    [ -n "$val" ]
    [[ "$val" =~ ^[0-9]+$ ]]
}
