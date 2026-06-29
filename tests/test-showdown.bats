#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib helpers
    load_lib showdown
    seed_showdown
    export -f _showdown_items_meta_transform
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

@test "_showdown_items_meta_transform: TSV with type and isberry, holdable only" {
    # plates via onPlate, gems via isGem+name, enhancers via desc pattern,
    # berries via type field; air-balloon is a false-positive guard (must stay typeless).
    local js='exports.BattleItems = {leftovers:{name:"Leftovers",num:234,gen:2},flameplate:{name:"Flame Plate",onPlate:"Fire",num:298,gen:4},firegem:{name:"Fire Gem",isGem:true,num:548,gen:5},charcoal:{name:"Charcoal",num:249,gen:2,desc:"Fire-type attacks have 1.2x power."},sitrusberry:{name:"Sitrus Berry",isBerry:true,type:"Psychic",num:158,gen:3},airballoon:{name:"Air Balloon",num:541,gen:5,desc:"Holder is immune to Ground-type attacks."},abomasite:{name:"Abomasite",itemUser:["Abomasnow"],num:674,gen:6},pokeball:{name:"Poke Ball",isPokeball:true,num:4,gen:1},capberry:{name:"Cap Berry",isNonstandard:"CAP",num:-1,gen:9},quickclaw:{isNonstandard:"Past",name:"Quick Claw",desc:"After moving holder moves first.",num:217,gen:3}};'
    run bash -c "printf '%s' '$js' | _showdown_items_meta_transform | sort"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'air-balloon\t\t0\ncharcoal\tfire\t0\nfire-gem\tfire\t0\nflame-plate\tfire\t0\nleftovers\t\t0\nquick-claw\t\t0\nsitrus-berry\tpsychic\t1')" ]
}

@test "_showdown_build_holdable_meta: drops machines/TR rows via all-machines category" {
    # items.js carries leftovers (legal) and tr00 (a TR / all-machines item).
    _showdown_fetch_items() {
        printf '%s' 'exports.BattleItems = {leftovers:{name:"Leftovers",num:234,gen:2},tr00:{name:"TR00",num:1130,gen:8}};'
    }
    # all-machines lists tr00; the other excluded categories contribute nothing.
    pokeapi_get() {
        case "$1" in
            item-category/all-machines) printf '{"items":[{"name":"tr00"}]}' ;;
            item-category/*) printf '{"items":[]}' ;;
            *) return 1 ;;
        esac
    }
    export -f _showdown_fetch_items pokeapi_get
    run _showdown_build_holdable_meta
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx $'leftovers\t\t0'
    run bash -c "printf '%s\n' \"$output\" | grep -qx $'tr00\t\t0'"
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
