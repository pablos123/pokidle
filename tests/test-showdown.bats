#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib helpers
    load_lib showdown
    seed_showdown
    export -f _showdown_items_meta_transform _showdown_form_items_transform
}

@test "showdown_id strips punctuation and lowercases" {
    run showdown_id "thundurus-therian"
    [ "$output" = "thundurustherian" ]
    run showdown_id "Ho-Oh"
    [ "$output" = "hooh" ]
}

@test "showdown_get serves a fresh cached file without fetching" {
    _showdown_fetch() { touch "${BATS_TEST_TMPDIR}/fetch_called"; return 1; }
    export -f _showdown_fetch
    run showdown_get pokedex
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/fetch_called" ]
    echo "$output" | jq -e '.thundurustherian.baseSpecies == "Thundurus"'
}

@test "showdown_get returns 1 when no cache and fetch fails" {
    rm -f "${POKIDLE_SHOWDOWN_CACHE_DIR}/pokedex.json"
    run showdown_get pokedex
    [ "$status" -ne 0 ]
}

@test "showdown_get falls back to stale cache when fetch fails" {
    # Make the cache look stale; fetch is stubbed to fail.
    touch -d "30 days ago" "${POKIDLE_SHOWDOWN_CACHE_DIR}/pokedex.json"
    run showdown_get pokedex
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.corviknight.prevo == "Corvisquire"'
}

@test "showdown_legal_abilities: forme-specific abilities with hidden flag" {
    run showdown_legal_abilities "thundurus-therian"
    [ "$status" -eq 0 ]
    [ "$output" = $'volt-absorb\t0' ]
}

@test "showdown_legal_abilities: marks the hidden ability" {
    run showdown_legal_abilities "corviknight"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx $'mirror-armor\t1'
    echo "$output" | grep -qx $'pressure\t0'
}

@test "showdown_legal_abilities: returns 1 for unknown id" {
    run showdown_legal_abilities "missingno"
    [ "$status" -ne 0 ]
}

@test "showdown_legal_abilities: default-forme variety folds to base key" {
    # PokeAPI calls the default forme shaymin-land; Showdown keys it bare as
    # shaymin. The lookup must resolve to the base entry.
    run showdown_legal_abilities "shaymin-land"
    [ "$status" -eq 0 ]
    [ "$output" = $'natural-cure\t0' ]
}

@test "showdown_legal_moves: default-forme variety folds to base learnset" {
    run showdown_legal_moves "shaymin-land"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "seed-flare"
}

@test "showdown_legal_moves: forme resolves to base species learnset" {
    run showdown_legal_moves "thundurus-therian"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "thunderbolt"
    echo "$output" | grep -qx "nasty-plot"
}

@test "showdown_legal_moves: unions the prevo chain and slugifies names" {
    run showdown_legal_moves "corviknight"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "double-edge"   # corviknight, slugified
    echo "$output" | grep -qx "peck"          # rookidee (grandparent)
}

@test "showdown_legal_moves: regional forme uses its own learnset, not the Kanto base" {
    # Graveler-Alola has its own Showdown learnset; it must NOT inherit the
    # Kanto Graveler/Geodude learnset (which teaches Mimic). Its own Alolan
    # prevo chain (Geodude-Alola) supplies the electric moves instead.
    run showdown_legal_moves "graveler-alola"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "discharge"         # graveler-alola's own learnset
    echo "$output" | grep -qx "thunder-shock"     # geodude-alola prevo (Alolan chain)
    echo "$output" | grep -qx "rock-throw"         # shared, present in the Alolan set
    ! echo "$output" | grep -qx "mimic"           # Kanto-only, must not leak in
}

@test "showdown_legal_moves: Kanto base keeps its own Mimic learnset" {
    run showdown_legal_moves "graveler"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "mimic"
    echo "$output" | grep -qx "rock-throw"
}

@test "_showdown_items_meta_transform: TSV with type and isberry, holdable only" {
    # plates via onPlate, gems via isGem+name, enhancers via desc pattern,
    # berries via type field; air-balloon is a false-positive guard (must stay typeless).
    local js='exports.BattleItems = {leftovers:{name:"Leftovers",num:234,gen:2},flameplate:{name:"Flame Plate",onPlate:"Fire",num:298,gen:4},firegem:{name:"Fire Gem",isGem:true,num:548,gen:5},charcoal:{name:"Charcoal",num:249,gen:2,desc:"Fire-type attacks have 1.2x power."},sitrusberry:{name:"Sitrus Berry",isBerry:true,type:"Psychic",num:158,gen:3},airballoon:{name:"Air Balloon",num:541,gen:5,desc:"Holder is immune to Ground-type attacks."},abomasite:{name:"Abomasite",itemUser:["Abomasnow"],num:674,gen:6},pokeball:{name:"Poke Ball",isPokeball:true,num:4,gen:1},capberry:{name:"Cap Berry",isNonstandard:"CAP",num:-1,gen:9}};'
    run bash -c "printf '%s' '$js' | _showdown_items_meta_transform | sort"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'air-balloon\t\t0\ncharcoal\tfire\t0\nfire-gem\tfire\t0\nflame-plate\tfire\t0\nleftovers\t\t0\nsitrus-berry\tpsychic\t1')" ]
}

@test "_showdown_items_meta_transform: drops every isNonstandard item (Past/Future/CAP/Unobtainable)" {
    local js='exports.BattleItems = {leftovers:{name:"Leftovers",num:234},quickclaw:{name:"Quick Claw",isNonstandard:"Past",num:217},absolite:{name:"Absolite",isNonstandard:"Past",num:677},absolitez:{name:"Absolite Z",isNonstandard:"Future",num:1},strangeball:{name:"Strange Ball",isNonstandard:"Unobtainable",num:1},crucibellite:{name:"Crucibellite",isNonstandard:"CAP",num:1}};'
    run bash -c "printf '%s' '$js' | _showdown_items_meta_transform | sort"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'leftovers\t\t0')" ]
}

@test "showdown_items_raw: fetches and caches the raw items.js" {
    rm -f "${POKIDLE_SHOWDOWN_CACHE_DIR}/items.js"
    _showdown_fetch_items() { printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers"}};'; }
    export -f _showdown_fetch_items
    run showdown_items_raw
    [ "$status" -eq 0 ]
    [[ "$output" == *"Leftovers"* ]]
    [ -f "${POKIDLE_SHOWDOWN_CACHE_DIR}/items.js" ]
}

@test "showdown_items_raw: serves fresh cache without fetching" {
    printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers"}};' \
        > "${POKIDLE_SHOWDOWN_CACHE_DIR}/items.js"
    _showdown_fetch_items() { touch "${BATS_TEST_TMPDIR}/items_fetched"; return 1; }
    export -f _showdown_fetch_items
    run showdown_items_raw
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/items_fetched" ]
}

@test "_showdown_build_holdable_meta: builds from cached items.js without refetch" {
    printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers"}};' \
        > "${POKIDLE_SHOWDOWN_CACHE_DIR}/items.js"
    _showdown_fetch_items() { touch "${BATS_TEST_TMPDIR}/items_fetched"; return 1; }
    pokeapi_get() { printf '{"items":[]}'; }
    showdown_item_name_index() { return 1; }
    export -f _showdown_fetch_items pokeapi_get showdown_item_name_index
    run _showdown_build_holdable_meta
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/items_fetched" ]
    echo "$output" | grep -qx $'leftovers\t\t0'
}

@test "_showdown_build_holdable_meta: drops evolution + machine items via PokeAPI categories" {
    # fire-stone (evolution) and a hypothetical standard machine item both survive
    # the isNonstandard transform but must be excluded via PokeAPI categories.
    _showdown_fetch_items() {
        printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers",num:234,gen:2},firestone:{name:"Fire Stone",num:82,gen:1},tm99:{name:"TM99",num:9999,gen:9}};'
    }
    pokeapi_get() {
        case "$1" in
            item-category/evolution) printf '{"items":[{"name":"fire-stone"}]}' ;;
            item-category/all-machines) printf '{"items":[{"name":"tm99"}]}' ;;
            item-category/*) printf '{"items":[]}' ;;
            *) return 1 ;;
        esac
    }
    showdown_item_name_index() { return 1; }
    export -f _showdown_fetch_items pokeapi_get showdown_item_name_index
    run _showdown_build_holdable_meta
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx $'leftovers\t\t0'
    run bash -c "printf '%s\n' \"$output\" | grep -qxE $'(fire-stone|tm99)\t\t0'"
    [ "$status" -ne 0 ]
}

@test "showdown_item_name_index: prints slug + normalized English-name key" {
    # PokeAPI carries the Showdown display name as its English item name, even
    # when the slug differs. The name key is that English name normalized the
    # same way Showdown slugs are (lowercase, non-alnum -> '-', trimmed), so a
    # Showdown slug can join to the PokeAPI slug. Note pretty-wing's English name
    # is "Pretty Feather" and kings-rock uses a curly apostrophe.
    showdown_item_name_index_query() { printf 'QUERY'; }
    pokeapi_graphql() {
        printf '%s' '{"data":{"item":[
            {"name":"leftovers","itemnames":[{"name":"Leftovers"}]},
            {"name":"kings-rock","itemnames":[{"name":"King’s Rock"}]},
            {"name":"pretty-wing","itemnames":[{"name":"Pretty Feather"}]},
            {"name":"nameless","itemnames":[]}
        ]}}'
    }
    export -f showdown_item_name_index_query pokeapi_graphql
    run showdown_item_name_index
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx $'leftovers\tleftovers'
    echo "$output" | grep -qx $'kings-rock\tking-s-rock'
    echo "$output" | grep -qx $'pretty-wing\tpretty-feather'
    # Items with no English name contribute nothing (no bogus key).
    run bash -c "printf '%s\n' \"$output\" | grep -q nameless"
    [ "$status" -ne 0 ]
}

@test "_showdown_resolve_pokeapi_slug: valid PokeAPI slug resolves to itself" {
    showdown_item_name_index() {
        printf 'leftovers\tleftovers\nkings-rock\tking-s-rock\n'
    }
    export -f showdown_item_name_index
    run _showdown_resolve_pokeapi_slug leftovers
    [ "$status" -eq 0 ]
    [ "$output" = "leftovers" ]
}

@test "_showdown_resolve_pokeapi_slug: renamed item resolves via unique name key" {
    # PokeAPI slug "kings-rock", but its normalized English name is "king-s-rock"
    # (Showdown's "King's Rock"). The Showdown-derived slug king-s-rock is not a
    # PokeAPI slug, so it must map through the name key to kings-rock.
    showdown_item_name_index() {
        printf 'leftovers\tleftovers\nkings-rock\tking-s-rock\npretty-wing\tpretty-feather\n'
    }
    export -f showdown_item_name_index
    run _showdown_resolve_pokeapi_slug king-s-rock
    [ "$status" -eq 0 ]
    [ "$output" = "kings-rock" ]
    run _showdown_resolve_pokeapi_slug pretty-feather
    [ "$output" = "pretty-wing" ]
}

@test "_showdown_resolve_pokeapi_slug: ambiguous name key falls back to identity" {
    # Two PokeAPI slugs share a normalized name (e.g. --held/--bag variants).
    # An unknown slug hitting that key must not pick a wrong sprite: keep identity.
    showdown_item_name_index() {
        printf 'buginium-z--bag\tbuginium-z\nbuginium-z--held\tbuginium-z\n'
    }
    export -f showdown_item_name_index
    run _showdown_resolve_pokeapi_slug buginium-z
    [ "$status" -eq 0 ]
    [ "$output" = "buginium-z" ]
}

@test "_showdown_resolve_pokeapi_slug: unknown slug (neither slug nor name) keeps identity" {
    showdown_item_name_index() { printf 'leftovers\tleftovers\n'; }
    export -f showdown_item_name_index
    run _showdown_resolve_pokeapi_slug totally-made-up
    [ "$status" -eq 0 ]
    [ "$output" = "totally-made-up" ]
}

@test "_showdown_build_holdable_meta: appends a 4th pokeapi_slug column only for renamed items" {
    _showdown_fetch_items() {
        printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers",num:234,gen:2},prettyfeather:{name:"Pretty Feather",num:571,gen:5}};'
    }
    pokeapi_get() { printf '{"items":[]}'; }
    # Pretty Feather's Showdown slug (pretty-feather) is not a PokeAPI slug; its
    # English name maps to PokeAPI slug pretty-wing.
    showdown_item_name_index() {
        printf 'leftovers\tleftovers\npretty-wing\tpretty-feather\n'
    }
    export -f _showdown_fetch_items pokeapi_get showdown_item_name_index
    run _showdown_build_holdable_meta
    [ "$status" -eq 0 ]
    # Identity item stays 3 columns (no trailing pokeapi_slug).
    echo "$output" | grep -qx $'leftovers\t\t0'
    # Renamed item carries the resolved PokeAPI slug in column 4.
    echo "$output" | grep -qx $'pretty-feather\t\t0\tpretty-wing'
}

@test "showdown_item_pokeapi_slug: returns column 4 for renamed items, identity otherwise" {
    printf 'leftovers\t\t0\nking-s-rock\t\t0\tkings-rock\naspear-berry\tice\t1\n' \
        > "${POKIDLE_SHOWDOWN_CACHE_DIR}/items-holdable.tsv"
    run showdown_item_pokeapi_slug king-s-rock
    [ "$status" -eq 0 ]
    [ "$output" = "kings-rock" ]
    run showdown_item_pokeapi_slug leftovers
    [ "$output" = "leftovers" ]
    run showdown_item_pokeapi_slug aspear-berry
    [ "$output" = "aspear-berry" ]
    # Unknown slug (not a holdable, e.g. an evolution-item drop) passes through.
    run showdown_item_pokeapi_slug fire-stone
    [ "$output" = "fire-stone" ]
}

@test "_showdown_form_items_transform: species-specific mega/primal/signature-Z only" {
    local js='exports.BattleItems = {charizarditex:{name:"Charizardite X",megaStone:{Charizard:"Charizard-Mega-X"},itemUser:["Charizard"],isNonstandard:"Past"},charizarditey:{name:"Charizardite Y",megaStone:{Charizard:"Charizard-Mega-Y"},itemUser:["Charizard"],isNonstandard:"Past"},redorb:{name:"Red Orb",isPrimalOrb:true,itemUser:["Groudon"],isNonstandard:"Past"},aloraichiumz:{name:"Aloraichium Z",zMove:"Stoked Sparksurfer",itemUser:["Raichu-Alola"],isNonstandard:"Past"},buginiumz:{name:"Buginium Z",zMove:true,isNonstandard:"Past"},absolitez:{name:"Absolite Z",megaStone:{Absol:"Absol-Mega"},itemUser:["Absol"],isNonstandard:"Future"},crucibellite:{name:"Crucibellite",megaStone:{Crucibelle:"Crucibelle-Mega"},itemUser:["Crucibelle"],isNonstandard:"CAP"},leftovers:{name:"Leftovers"}};'
    run bash -c "printf '%s' '$js' | _showdown_form_items_transform | sort"
    [ "$status" -eq 0 ]
    # Rows are item-slug<TAB>eligible-slug<TAB>class. Future (Absolite Z) and CAP
    # (Crucibellite) form-items are excluded: not real.
    [ "$output" = "$(printf 'aloraichium-z\traichu-alola\tz\ncharizardite-x\tcharizard\tmega\ncharizardite-y\tcharizard\tmega\nred-orb\tgroudon\tprimal')" ]
}

@test "showdown_form_item_slugs: distinct item slugs from the registry" {
    printf 'charizardite-x\tcharizard\ncharizardite-y\tcharizard\naloraichium-z\traichu-alola\n' \
        > "${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
    run showdown_form_item_slugs
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sort)" = "$(printf 'aloraichium-z\ncharizardite-x\ncharizardite-y')" ]
}

@test "showdown_form_items_for_species: matches via species and via variety" {
    printf 'charizardite-x\tcharizard\ncharizardite-y\tcharizard\naloraichium-z\traichu-alola\n' \
        > "${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
    run showdown_form_items_for_species charizard charizard
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | sort)" = "$(printf 'charizardite-x\ncharizardite-y')" ]
    run showdown_form_items_for_species raichu raichu-alola
    [ "$status" -eq 0 ]
    [ "$output" = "aloraichium-z" ]
    run showdown_form_items_for_species pidgey pidgey
    [ "$status" -ne 0 ]
}

@test "showdown_typed_holdable_items: only typed non-berry rows as slug<TAB>type" {
    run showdown_typed_holdable_items
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'charcoal\tfire')" ]
    # berries must be excluded even if they carry a type
    run bash -c "printf '%s\n' \"$output\" | grep -qx sitrus-berry"
    [ "$status" -ne 0 ]
}

@test "showdown_typeless_holdable_items: typeless non-berry slugs only" {
    run showdown_typeless_holdable_items
    [ "$status" -eq 0 ]
    local out="$output"
    run bash -c "printf '%s\n' \"$out\" | grep -qx leftovers";    [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"$out\" | grep -qx choice-band";  [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"$out\" | grep -qx sitrus-berry"; [ "$status" -ne 0 ]
    run bash -c "printf '%s\n' \"$out\" | grep -qx charcoal";     [ "$status" -ne 0 ]
}

@test "showdown_holdable_items: field-1 slugs incl typed and berries" {
    run showdown_holdable_items
    [ "$status" -eq 0 ]
    local out="$output"
    run bash -c "printf '%s\n' \"$out\" | grep -qx leftovers";    [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"$out\" | grep -qx charcoal";     [ "$status" -eq 0 ]
    run bash -c "printf '%s\n' \"$out\" | grep -qx sitrus-berry"; [ "$status" -eq 0 ]
}

@test "showdown_item_is_holdable: listed slug holdable, unlisted not" {
    run showdown_item_is_holdable leftovers
    [ "$status" -eq 0 ]
    run showdown_item_is_holdable abomasite
    [ "$status" -ne 0 ]
}
