#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    export POKIDLE_DB_PATH
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cp "$REPO_ROOT/config/biomes.json" "$POKIDLE_CONFIG_DIR/biomes.json"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    export POKIDLE_CONFIG_DIR POKIDLE_CACHE_DIR

    load_lib db
    load_lib biome
}

teardown() {
    rm -f "$POKIDLE_DB_PATH"
    rm -rf "$POKIDLE_CONFIG_DIR" "$POKIDLE_CACHE_DIR"
}

@test "foundation: pick biome -> open session -> insert encounter -> list" {
    db_init
    biome_validate

    # Seed pool fixtures so biome_pick_random has eligible biomes.
    local id
    while IFS= read -r id; do
        jq -n --arg b "$id" '
            {biome: $b, schema: 3, tiers: {
                common: [range(0; 50) | {species: ("s\(.))"), min: 5, max: 8}],
                uncommon: [], rare: [], very_rare: []
            }}
        ' > "$POKIDLE_CACHE_DIR/pools/$id.json"
    done < <(biome_ids)

    local biome
    biome="$(biome_pick_random)"
    local sid
    sid="$(db_open_biome_session "$biome" "$(date +%s)")"

    local enc
    enc=$(jq -n --argjson sid "$sid" '{
        session_id: $sid, encountered_at: 1700001000,
        species: "zubat", dex_id: 41, level: 7,
        nature: "adamant", ability: "inner-focus", is_hidden_ability: 0,
        gender: "M", shiny: 0, held_berry: null,
        friendship: 70,
        ivs: [10,20,30,15,5,25], evs: [0,0,0,0,0,0],
        stats: [22,18,15,12,15,30],
        moves: ["leech-life","supersonic","astonish","bite"],
        sprite_path: null
    }')
    db_insert_encounter "$enc"

    run db_list_encounters --limit 5
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "1" ]
}
