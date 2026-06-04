#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    export POKIDLE_CACHE_DIR
    load_lib biome
}

teardown() {
    rm -rf "$POKIDLE_CACHE_DIR"
}

# Write a v2 pool file with N entries spread across common.
_write_pool() {
    local biome="$1" n="$2"
    mkdir -p -- "$POKIDLE_CACHE_DIR/pools"
    jq -n --arg b "$biome" --argjson n "$n" '
        {biome: $b, tiers: {
            common: [range(0; $n) | {species: ("s\(.))"), varieties: [("s\(.))")], min: 5, max: 8}],
            uncommon: [], rare: [], very_rare: []
        }}
    ' > "$POKIDLE_CACHE_DIR/pools/$biome.json"
}

@test "biome_pick_random returns a valid biome id" {
    local id
    while IFS= read -r id; do
        _write_pool "$id" 50
    done < <(biome_ids)
    run biome_pick_random
    [ "$status" -eq 0 ]
    biome_exists "$output"
}

@test "biome_pick_random_excluding never returns the excluded id" {
    local id
    while IFS= read -r id; do
        _write_pool "$id" 50
    done < <(biome_ids)
    local i out
    for i in {1..30}; do
        out="$(biome_pick_random_excluding cave)"
        [ "$out" != "cave" ]
    done
}

@test "biome_pick_random_excluding fails if only eligible biome is the excluded one" {
    # Only one biome has an eligible pool; excluding it leaves nothing.
    _write_pool forest 50
    run biome_pick_random_excluding forest
    [ "$status" -ne 0 ]
}

@test "biome_pick_random skips biomes with pool size <= 10" {
    _write_pool forest 50
    _write_pool cave   5
    local i out
    for i in {1..30}; do
        out="$(biome_pick_random)"
        [ "$out" = forest ]
    done
}

@test "biome_pick_random fails when every pool has <= 10 entries" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    local id
    while IFS= read -r id; do
        _write_pool "$id" 3
    done < <(biome_ids)

    run biome_pick_random
    [ "$status" -ne 0 ]
    [[ "$output" == *"pool>"* ]]
}

@test "biome_pick_random treats missing pool as size 0 and skips" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    # No pool files written; every biome ineligible.
    run biome_pick_random
    [ "$status" -ne 0 ]
}

@test "biome rotation announce: pool_size is sum of all tiers" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    POKIDLE_NO_NOTIFY=1
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_NO_NOTIFY
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/forest.json" <<EOF
{
    "biome": "forest",
    "tiers": {
        "common": [{"species":"a"},{"species":"b"}],
        "uncommon": [{"species":"c"}],
        "rare": [],
        "very_rare": []
    },
    "berries": ["pecha","chesto"]
}
EOF
    POKIDLE_TEST_SOURCE_ONLY=1
    export POKIDLE_TEST_SOURCE_ONLY
    load_lib notify
    source "$REPO_ROOT/pokidle"
    run _pokidle_announce_biome forest
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 species"* ]]
}
