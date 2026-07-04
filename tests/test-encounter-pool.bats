#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    stub_pokeapi
    # build_pool pulls berries from a cached GraphQL query; stub the seam so
    # tests need no network. Individual tests override this for their own cases.
    stub_gql_berries
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

@test "encounter_pool_path returns biome-specific cache path" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    run encounter_pool_path cave
    [ "$output" = "$POKIDLE_CACHE_DIR/pools/cave.json" ]
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
    stub_gql_berries
    stub_gql_pool
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
    stub_gql_berries
    stub_gql_pool
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
    stub_gql_berries
    stub_gql_pool
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
    stub_gql_berries
    stub_gql_pool
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
    stub_gql_berries
    stub_gql_pool
    # Make only the GraphQL berry index fetch fail, mimicking a transient network
    # error. With method=graphql (no REST fallback) the build must surface that,
    # not ship a pool with zero berries.
    encounter_gql_berries() { return 1; }
    export -f encounter_gql_berries
    run encounter_build_pool forest graphql
    [ "$status" -ne 0 ]
}

@test "build_pool: auto method falls back to REST when GraphQL fails" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    # GraphQL unavailable: every gql fetcher fails. The default (auto) method must
    # fall back to the REST path (fixture-backed here) and still produce a pool.
    encounter_gql_type_species() { return 1; }
    encounter_gql_chain_stages() { return 1; }
    encounter_gql_berries() { return 1; }
    export -f encounter_gql_type_species encounter_gql_chain_stages encounter_gql_berries
    # Capture stdout only (the fallback notice goes to stderr).
    local pool
    pool="$(encounter_build_pool forest 2>/dev/null)"
    [ "$(jq 'has("tiers")' <<<"$pool")" = "true" ]
    [ "$(jq '[.tiers[][].species] | index("caterpie")' <<<"$pool")" != "null" ]
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
    stub_gql_berries
    stub_gql_pool
    # tide-pool is water+bug; chesto (water natural_gift) qualifies, cheri
    # (fire) does not. Berry index stubbed in setup (chesto=water, cheri=fire).
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

@test "encounter_gql_berries: shapes the GraphQL response to name<TAB>gift-type rows" {
    load_lib encounter
    pokeapi_graphql() {
        printf '%s' '{"data":{"berry":[{"name":"cheri","type":{"name":"fire"}},{"name":"chesto","type":{"name":"water"}}]}}'
    }
    export -f pokeapi_graphql
    run encounter_gql_berries
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'cheri\tfire' ]
    [ "${lines[1]}" = $'chesto\twater' ]
}

@test "encounter_gql_type_species: shapes rows and defaults a null capture_rate to 45" {
    load_lib encounter
    # meowth has a capture_rate; a hypothetical null-cr mon must default to 45
    # (matching the old REST path's `.capture_rate // 45`), so it tiers as rare
    # rather than falling through to very_rare (jq: null >= 25 is false).
    pokeapi_graphql() {
        printf '%s' '{"data":{"pokemontype":[
          {"pokemon":{"name":"meowth","pokemonforms":[{"is_default":true,"is_battle_only":false}],
            "pokemonspecy":{"name":"meowth","capture_rate":255,"is_legendary":false,"is_mythical":false}}},
          {"pokemon":{"name":"nullmon","pokemonforms":[{"is_default":true,"is_battle_only":false}],
            "pokemonspecy":{"name":"nullmon","capture_rate":null,"is_legendary":false,"is_mythical":false}}}
        ]}}'
    }
    export -f pokeapi_graphql
    run encounter_gql_type_species normal
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -c 'select(.species=="nullmon") | .cr')" = "45" ]
    [ "$(printf '%s\n' "$output" | jq -c 'select(.species=="meowth") | .cr')" = "255" ]
}

@test "encounter_gql_chain_stages: maps species to stage depth + evolve min_level" {
    load_lib encounter
    # treecko(252) -> grovyle(253, L16) -> sceptile(254, L36)
    pokeapi_graphql() {
        printf '%s' '{"data":{"evolutionchain":[{"pokemonspecies":[
          {"name":"treecko","id":252,"evolves_from_species_id":null,"pokemonevolutions":[]},
          {"name":"grovyle","id":253,"evolves_from_species_id":252,"pokemonevolutions":[{"min_level":16}]},
          {"name":"sceptile","id":254,"evolves_from_species_id":253,"pokemonevolutions":[{"min_level":36}]}
        ]}]}}'
    }
    export -f pokeapi_graphql
    run encounter_gql_chain_stages
    [ "$status" -eq 0 ]
    [ "$(jq -c '.treecko' <<<"$output")"  = '{"stage":0,"ml":null}' ]
    [ "$(jq -c '.grovyle' <<<"$output")"  = '{"stage":1,"ml":16}' ]
    [ "$(jq -c '.sceptile' <<<"$output")" = '{"stage":2,"ml":36}' ]
}

@test "encounter_gql_berries: returns 1 when the query fails" {
    load_lib encounter
    pokeapi_graphql() { return 1; }
    export -f pokeapi_graphql
    run encounter_gql_berries
    [ "$status" -ne 0 ]
}

@test "build_pool: legendaries collected into .legendaries, not .tiers" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib biome
    load_lib encounter
    stub_pokeapi
    stub_gql_berries
    stub_gql_pool
    run encounter_build_pool forest
    [ "$status" -eq 0 ]
    # shaymin is grass + is_legendary: must land in .legendaries with its formes.
    local leg
    leg="$(jq -c '.legendaries[] | select(.species=="shaymin")' <<< "$output")"
    [ -n "$leg" ]
    [ "$(jq -c '.varieties | sort' <<< "$leg")" = '["shaymin-land","shaymin-sky"]' ]
    # ...and never leaks into the encounterable tiers.
    [ "$(jq '[.tiers[][].species] | index("shaymin")' <<< "$output")" = "null" ]
}

@test "encounter_pool_save persists the legendaries array" {
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    export POKIDLE_CACHE_DIR
    load_lib encounter
    local pool='{"tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},"berries":[],"items":[],"legendaries":[{"species":"articuno","varieties":["articuno"]}]}'
    encounter_pool_save cave "$pool"
    local saved
    saved="$(cat "$BATS_TMPDIR/cache.$$/pools/cave.json")"
    [ "$(jq -c '.legendaries' <<< "$saved")" = '[{"species":"articuno","varieties":["articuno"]}]' ]
}

@test "_encounter_typed_items_for_biome: volcano yields charcoal (fire) and not leftovers (typeless)" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib biome
    load_lib showdown
    load_lib encounter
    seed_showdown
    run _encounter_typed_items_for_biome volcano
    [ "$status" -eq 0 ]
    grep -qx charcoal <<< "$output"
    ! grep -qx leftovers <<< "$output"
}

