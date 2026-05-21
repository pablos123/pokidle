#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    stub_pokeapi
}

@test "walk_chain: treecko line yields 3 stages with correct levels" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-142.json")"
    run encounter_walk_chain "$chain"
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "3" ]
    local treecko_stage grovyle_stage sceptile_stage
    treecko_stage="$(jq -r '.[] | select(.species=="treecko") | .stage_idx' <<< "$output")"
    grovyle_stage="$(jq -r '.[] | select(.species=="grovyle") | .stage_idx' <<< "$output")"
    sceptile_stage="$(jq -r '.[] | select(.species=="sceptile") | .stage_idx' <<< "$output")"
    [ "$treecko_stage" = "0" ]
    [ "$grovyle_stage" = "1" ]
    [ "$sceptile_stage" = "2" ]
    local grovyle_min sceptile_min
    grovyle_min="$(jq -r '.[] | select(.species=="grovyle") | .min_level_evo' <<< "$output")"
    sceptile_min="$(jq -r '.[] | select(.species=="sceptile") | .min_level_evo' <<< "$output")"
    [ "$grovyle_min" = "16" ]
    [ "$sceptile_min" = "36" ]
}

@test "walk_chain: eevee line yields 3 stages with null min_level for non-level evos" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-67.json")"
    run encounter_walk_chain "$chain"
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "3" ]
    local vaporeon_min
    vaporeon_min="$(jq -r '.[] | select(.species=="vaporeon") | .min_level_evo // "null"' <<< "$output")"
    [ "$vaporeon_min" = "null" ]
}

@test "encounter_pool_path returns biome-specific cache path" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    run encounter_pool_path cave
    [ "$output" = "$POKIDLE_CACHE_DIR/pools/cave.json" ]
}

@test "encounter_species_for_name: bare species passes through unchanged" {
    [ "$(encounter_species_for_name treecko)" = "treecko" ]
    [ "$(encounter_species_for_name caterpie)" = "caterpie" ]
}

@test "encounter_species_for_name: variety-suffixed name resolves to bare species" {
    # /pokemon-species/shaymin-land 404s, fallback hits /pokemon/shaymin-land
    # whose .species.name is "shaymin".
    [ "$(encounter_species_for_name shaymin-land)" = "shaymin" ]
}

@test "encounter_pick_variety: returns a name from .varieties[]" {
    # shaymin fixture has two varieties — output must be one of them.
    local v
    v="$(encounter_pick_variety shaymin)"
    [[ "$v" == "shaymin-land" || "$v" == "shaymin-sky" ]]
}

@test "encounter_pick_variety: falls back to species name when /pokemon-species fails" {
    # No fixture for "made-up-species" → pokeapi_get returns 1 → fallback.
    [ "$(encounter_pick_variety made-up-species)" = "made-up-species" ]
}

@test "build_pool: tiers each species by own capture_rate" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    export POKIDLE_CONFIG_DIR
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cat > "$POKIDLE_CONFIG_DIR/biomes.json" <<EOF
{ "biomes": [
    { "id": "testbiome", "label": "Test", "types": ["grass", "bug"] }
] }
EOF
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool testbiome
    [ "$status" -eq 0 ]
    local has_tiers
    has_tiers="$(jq 'has("tiers") and (.tiers | has("common") and has("uncommon") and has("rare") and has("very_rare"))' <<< "$output")"
    [ "$has_tiers" = "true" ]

    # capture_rate 255 → common; capture_rate 45 → rare. No tier-shift by stage.
    tier_of() {
        jq -r --arg sp "$1" '.tiers | to_entries[] | select(.value | map(.species) | index($sp)) | .key' <<< "$output"
    }
    [ "$(tier_of caterpie)"   = "common"  ]
    [ "$(tier_of metapod)"    = "common"  ]
    [ "$(tier_of butterfree)" = "rare"    ]
    [ "$(tier_of treecko)"    = "rare"    ]
    [ "$(tier_of grovyle)"    = "rare"    ]
    [ "$(tier_of sceptile)"   = "rare"    ]
}

@test "build_pool: variety-suffixed names from /type collapse to bare species" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_CONFIG_DIR
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cat > "$POKIDLE_CONFIG_DIR/biomes.json" <<EOF
{ "biomes": [
    { "id": "testbiome", "label": "Test", "types": ["grass", "bug"] }
] }
EOF
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool testbiome
    [ "$status" -eq 0 ]
    # /type/bug returns wormadam-{plant,sandy,trash}; all collapse to bare "wormadam".
    local has_bare has_variety
    has_bare="$(jq '[.tiers[][] | .species] | index("wormadam") != null' <<< "$output")"
    has_variety="$(jq '[.tiers[][] | .species] | any(. == "wormadam-plant" or . == "wormadam-sandy" or . == "wormadam-trash")' <<< "$output")"
    [ "$has_bare"    = "true"  ]
    [ "$has_variety" = "false" ]
    # capture_rate 45 → rare bucket.
    local tier
    tier="$(jq -r '.tiers | to_entries[] | select(.value | map(.species) | index("wormadam")) | .key' <<< "$output")"
    [ "$tier" = "rare" ]
}

@test "build_pool: min/max levels come from species' own evolution_details" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_CONFIG_DIR
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cat > "$POKIDLE_CONFIG_DIR/biomes.json" <<EOF
{ "biomes": [
    { "id": "testbiome", "label": "Test", "types": ["grass", "bug"] }
] }
EOF
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool testbiome
    [ "$status" -eq 0 ]

    entry_of() {
        jq -c --arg sp "$1" '.tiers | to_entries[] | .value[] | select(.species==$sp)' <<< "$output"
    }
    # Roots: 5-15.
    [ "$(entry_of caterpie | jq -r '.min')" = "5"  ]
    [ "$(entry_of caterpie | jq -r '.max')" = "15" ]
    [ "$(entry_of treecko  | jq -r '.min')" = "5"  ]
    [ "$(entry_of treecko  | jq -r '.max')" = "15" ]
    # Evolved (level-up): min = own evolution_details.min_level, max = min+10.
    [ "$(entry_of metapod    | jq -r '.min')" = "7"  ]
    [ "$(entry_of metapod    | jq -r '.max')" = "17" ]
    [ "$(entry_of butterfree | jq -r '.min')" = "10" ]
    [ "$(entry_of butterfree | jq -r '.max')" = "20" ]
    [ "$(entry_of grovyle    | jq -r '.min')" = "16" ]
    [ "$(entry_of grovyle    | jq -r '.max')" = "26" ]
    [ "$(entry_of sceptile   | jq -r '.min')" = "36" ]
    [ "$(entry_of sceptile   | jq -r '.max')" = "46" ]
}

@test "encounter_pool_save writes schema:3 and tiers wrapper" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    local pool='{"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]},"berries":[]}'
    encounter_pool_save cave "$pool"
    local saved
    saved="$(cat "$POKIDLE_CACHE_DIR/pools/cave.json")"
    [ "$(jq -r '.schema' <<< "$saved")" = "3" ]
    [ "$(jq -r '.biome' <<< "$saved")" = "cave" ]
    [ "$(jq -r '.tiers.common[0].species' <<< "$saved")" = "zubat" ]
    [ "$(jq '.tiers.uncommon | type' <<< "$saved")" = "\"array\"" ]
}

@test "encounter_pool_load returns full v3 file on read" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    local pool='{"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]},"berries":[]}'
    encounter_pool_save cave "$pool"
    run encounter_pool_load cave
    [ "$status" -eq 0 ]
    [ "$(jq -r '.schema' <<< "$output")" = "3" ]
    [ "$(jq -r '.tiers.common[0].species' <<< "$output")" = "zubat" ]
}

@test "encounter_roll_pool_entry returns species from a populated tier" {
    local pool='{"schema":3,"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "zubat" ]
    [ "$(jq -r '.min'     <<< "$output")" = "5" ]
    [ "$(jq -r '.max'     <<< "$output")" = "8" ]
}

@test "encounter_roll_pool_entry falls back forward when only very_rare populated" {
    local pool='{"schema":3,"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[{"species":"mew","min":40,"max":40}]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "mew" ]
}

@test "encounter_roll_pool_entry errors when all tiers empty" {
    local pool='{"schema":3,"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -ne 0 ]
}

@test "evolution_tier_lookup returns tier name for species in pool" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<'EOF'
{"biome":"cave","schema":3,"tiers":{
  "common":[{"species":"zubat","min":5,"max":8}],
  "uncommon":[{"species":"golbat","min":22,"max":25}],
  "rare":[],"very_rare":[]
}}
EOF
    source "$REPO_ROOT/lib/evolution.bash"
    [ "$(evolution_tier_lookup cave zubat)" = "common" ]
    [ "$(evolution_tier_lookup cave golbat)" = "uncommon" ]
    [ "$(evolution_tier_lookup cave mew)" = "common" ]   # absent → default
}

@test "evolution_next_stages returns species + evolution_details one stage past root" {
    source "$REPO_ROOT/lib/evolution.bash"
    local chain='{"chain":{
      "species":{"name":"eevee"},"evolution_details":[],
      "evolves_to":[
        {"species":{"name":"vaporeon"},"evolution_details":[
          {"item":{"name":"water-stone"},"trigger":{"name":"use-item"}}],
         "evolves_to":[]},
        {"species":{"name":"jolteon"},"evolution_details":[
          {"item":{"name":"thunder-stone"},"trigger":{"name":"use-item"}}],
         "evolves_to":[]}]}}'
    run evolution_next_stages "$chain" eevee
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "2" ]
    [ "$(jq -r '.[0].species' <<< "$output")" = "vaporeon" ]
    [ "$(jq -r '.[0].evolution_details[0].item.name' <<< "$output")" = "water-stone" ]
}


@test "encounter_tier_for_capture_rate: boundary values map to expected tiers" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    [ "$(encounter_tier_for_capture_rate 255)" = "common" ]
    [ "$(encounter_tier_for_capture_rate 150)" = "common" ]
    [ "$(encounter_tier_for_capture_rate 149)" = "uncommon" ]
    [ "$(encounter_tier_for_capture_rate 75)"  = "uncommon" ]
    [ "$(encounter_tier_for_capture_rate 74)"  = "rare" ]
    [ "$(encounter_tier_for_capture_rate 25)"  = "rare" ]
    [ "$(encounter_tier_for_capture_rate 24)"  = "very_rare" ]
    [ "$(encounter_tier_for_capture_rate 3)"   = "very_rare" ]
}

@test "build_pool: attaches berries derived from natural_gift_type" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_CONFIG_DIR
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cat > "$POKIDLE_CONFIG_DIR/biomes.json" <<EOF
{ "biomes": [
    { "id": "watery", "label": "Watery", "types": ["water"] }
] }
EOF
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool watery
    [ "$status" -eq 0 ]
    local has_b
    has_b="$(jq 'has("berries") and (.berries | type == "array")' <<< "$output")"
    [ "$has_b" = "true" ]
    local has_chesto
    has_chesto="$(jq -r '.berries | index("chesto") != null' <<< "$output")"
    [ "$has_chesto" = "true" ]
    local has_cheri
    has_cheri="$(jq -r '.berries | index("cheri") != null' <<< "$output")"
    [ "$has_cheri" = "false" ]
}

@test "pool save: schema version is 3" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib encounter
    encounter_pool_save fakebiome '{"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[]}'
    local sch
    sch="$(jq -r '.schema' "$POKIDLE_CACHE_DIR/pools/fakebiome.json")"
    [ "$sch" = "3" ]
}
