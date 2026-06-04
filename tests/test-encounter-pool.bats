#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    stub_pokeapi
}

@test "shipped pools: every entry carries varieties, none battle-only, no schema key" {
    local f
    for f in "$REPO_ROOT"/share/pools/*.json; do
        # No legacy schema key.
        [ "$(jq 'has("schema")' "$f")" = "false" ] || { echo "schema key in $f"; false; }
        # Every entry has a non-empty varieties[].
        local bad
        bad="$(jq '[.tiers[][] | select((.varieties // []) | length == 0)] | length' "$f")"
        [ "$bad" = "0" ] || { echo "varietyless entries in $f: $bad"; false; }
        # No non-wild forms leaked into varieties: mega (any -mega…, incl mega-z),
        # gmax/primal/eternamax, totems, battle-stance/transform forms, or
        # cosmetic event forms (Pikachu caps/cosplay, Let's-Go starters).
        local leaked
        leaked="$(jq -r '[.tiers[][].varieties[] | select(test("-mega|-primal|-gmax|-eternamax|-totem|-zen$|-hangry$|-gulping$|-gorging$|-busted$|-blade$|-noice$|-school$|-hero$|-ash$|-battle-bond$|-bloodmoon$|-cap$|-cosplay$|-starter$|-rock-star$|-belle$|-pop-star$|-phd$|-libre$"))] | length' "$f")"
        [ "$leaked" = "0" ] || { echo "non-wild forms in $f: $leaked"; false; }
    done
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
    load_lib biome
    load_lib encounter
    stub_pokeapi
    # forest is the grass+bug biome in the hardcoded catalog.
    run encounter_build_pool forest
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
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool forest
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

@test "build_pool: each entry carries the forms that qualified for the biome" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool forest
    [ "$status" -eq 0 ]
    entry_of() {
        jq -c --arg sp "$1" '.tiers | to_entries[] | .value[] | select(.species==$sp)' <<< "$output"
    }
    # A bare-form species lists itself as its only variety.
    [ "$(entry_of caterpie | jq -c '.varieties')" = '["caterpie"]' ]
    # wormadam reaches the bug pool only via its variety-suffixed forms; the one
    # with a resolvable /pokemon entry (plant) is recorded as the qualifying form.
    [ "$(entry_of wormadam | jq -r '.varieties[0]')" = "wormadam-plant" ]
}

@test "build_pool: min/max levels come from species' own evolution_details" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    run encounter_build_pool forest
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

@test "build_pool: berry-list fetch failure fails the build (no silent berryless pool)" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    # Wrap the fixture stub so only the berry index fetch fails, mimicking a
    # transient network error. build_pool must surface that, not ship a pool
    # with zero berries.
    eval "$(declare -f pokeapi_get | sed '1s/^pokeapi_get/_fixture_pokeapi_get/')"
    pokeapi_get() {
        if [[ "$1" == "berry?limit=100" ]]; then return 1; fi
        _fixture_pokeapi_get "$@"
    }
    run encounter_build_pool forest
    [ "$status" -ne 0 ]
}

@test "encounter_pool_save writes the biome/tiers wrapper without a schema key" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    local pool='{"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]},"berries":[]}'
    encounter_pool_save cave "$pool"
    local saved
    saved="$(cat "$POKIDLE_CACHE_DIR/pools/cave.json")"
    [ "$(jq 'has("schema")' <<< "$saved")" = "false" ]
    [ "$(jq -r '.biome' <<< "$saved")" = "cave" ]
    [ "$(jq -r '.tiers.common[0].species' <<< "$saved")" = "zubat" ]
    [ "$(jq '.tiers.uncommon | type' <<< "$saved")" = "\"array\"" ]
}

@test "encounter_pool_load returns the full file on read" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    local pool='{"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]},"berries":[]}'
    encounter_pool_save cave "$pool"
    run encounter_pool_load cave
    [ "$status" -eq 0 ]
    [ "$(jq -r '.biome' <<< "$output")" = "cave" ]
    [ "$(jq -r '.tiers.common[0].species' <<< "$output")" = "zubat" ]
}

@test "encounter_roll_pool_entry returns species from a populated tier" {
    local pool='{"tiers":{"common":[{"species":"zubat","min":5,"max":8}],"uncommon":[],"rare":[],"very_rare":[]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "zubat" ]
    [ "$(jq -r '.min'     <<< "$output")" = "5" ]
    [ "$(jq -r '.max'     <<< "$output")" = "8" ]
}

@test "encounter_roll_pool_entry falls back forward when only very_rare populated" {
    local pool='{"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[{"species":"mew","min":40,"max":40}]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.species' <<< "$output")" = "mew" ]
}

@test "encounter_roll_pool_entry errors when all tiers empty" {
    local pool='{"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]}}'
    run encounter_roll_pool_entry "$pool"
    [ "$status" -ne 0 ]
}

@test "evolution_tier_lookup returns tier name for species in pool" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<'EOF'
{"biome":"cave","tiers":{
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
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    # tide-pool is water+bug; chesto (water natural_gift) qualifies, cheri
    # (fire) does not.
    run encounter_build_pool tide-pool
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

@test "encounter_item_is_evolution: stones true, held items false" {
    run encounter_item_is_evolution ice-stone
    [ "$status" -eq 0 ]
    run encounter_item_is_evolution sun-stone
    [ "$status" -eq 0 ]
    run encounter_item_is_evolution leftovers
    [ "$status" -ne 0 ]
    run encounter_item_is_evolution kings-rock
    [ "$status" -ne 0 ]
}

@test "encounter_item_is_showdown_legal: held items/berries true, junk/evo false" {
    run encounter_item_is_showdown_legal leftovers
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal occa-berry
    [ "$status" -eq 0 ]
    # Junk the export must never assign.
    run encounter_item_is_showdown_legal exp-share
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal soothe-bell
    [ "$status" -ne 0 ]
    # Evolution + trade-evo items are excluded.
    run encounter_item_is_showdown_legal ice-stone
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal magmarizer
    [ "$status" -ne 0 ]
    # Non-battle berry is excluded.
    run encounter_item_is_showdown_legal razz-berry
    [ "$status" -ne 0 ]
}

@test "encounter_item_is_showdown_legal: National Dex AG additions are legal" {
    # Mega Stones, Z-crystals, Memories, Drives, incenses, Pokémon-specific
    # signature items — all legal in National Dex AG.
    run encounter_item_is_showdown_legal charizardite-x
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal mewtwonite-y
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal firium-z
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal pikanium-z
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal fire-memory
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal burn-drive
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal sea-incense
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal berry-juice
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal light-ball
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal thick-club
    [ "$status" -eq 0 ]
}

@test "encounter_item_is_showdown_legal: useless EV-reducer berries excluded" {
    # Showdown groups these under "Useless items" (grepa + kelpsy live in the
    # main "Items" group and stay legal).
    run encounter_item_is_showdown_legal hondew-berry
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal pomeg-berry
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal qualot-berry
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal tamato-berry
    [ "$status" -ne 0 ]
    run encounter_item_is_showdown_legal grepa-berry
    [ "$status" -eq 0 ]
    run encounter_item_is_showdown_legal kelpsy-berry
    [ "$status" -eq 0 ]
}

@test "_encounter_item_pool: glacier pool includes its showdown and evo items" {
    run _encounter_item_pool glacier
    [ "$status" -eq 0 ]
    # glacier's bucket: ice-resist berry + ice held items + ice-stone evo
    grep -qx ice-stone        <<< "$output"
    grep -qx never-melt-ice   <<< "$output"
    grep -qx yache-berry      <<< "$output"
    # Items now live in exactly one biome, so cross-biome items must be absent.
    ! grep -qx fire-stone     <<< "$output"
    ! grep -qx moon-stone     <<< "$output"  # moon-stone moved to cathedral
}

@test "_encounter_item_pool: volcano pool includes its showdown and evo items" {
    run _encounter_item_pool volcano
    [ "$status" -eq 0 ]
    grep -qx fire-stone       <<< "$output"
    grep -qx charcoal         <<< "$output"
    grep -qx occa-berry       <<< "$output"
    grep -qx charizardite-x   <<< "$output"
    ! grep -qx ice-stone      <<< "$output"
    ! grep -qx mystic-water   <<< "$output"  # ocean's slot
}

@test "_encounter_item_pool: every showdown item drops in exactly one biome" {
    # Coverage guarantee for the biome-keyed pool: every Showdown-legal item
    # appears in the union of all biome buckets, no duplicates, no items
    # outside ENCOUNTER_SHOWDOWN_ITEMS sneak into a bucket.
    declare -A assigned=()
    local b it dup_count=0 rogue_count=0
    for b in "${!ENCOUNTER_ITEMS_BY_BIOME[@]}"; do
        for it in ${ENCOUNTER_ITEMS_BY_BIOME[$b]}; do
            if [[ -n "${assigned[$it]:-}" ]]; then dup_count=$((dup_count+1)); fi
            assigned[$it]=$b
            if [[ -z "${ENCOUNTER_SHOWDOWN_ITEMS[$it]:-}" ]]; then
                rogue_count=$((rogue_count+1))
            fi
        done
    done
    [ "$dup_count"   -eq 0 ]
    [ "$rogue_count" -eq 0 ]
    [ "${#assigned[@]}" -eq "${#ENCOUNTER_SHOWDOWN_ITEMS[@]}" ]
}
