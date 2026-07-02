#!/usr/bin/env bats

load helpers

# Source pokidle as a library so its internal functions are callable.
source_pokidle_lib() {
    POKIDLE_TEST_SOURCE_ONLY=1 source "$REPO_ROOT/pokidle"
}

@test "_pokidle_sprite_name: returns the variety form when present" {
    source_pokidle_lib
    run _pokidle_sprite_name '{"species":"meowth","variety":"meowth-galar"}'
    [ "$status" -eq 0 ]
    [ "$output" = "meowth-galar" ]
}

@test "_pokidle_sprite_name: falls back to the bare species when variety is absent" {
    source_pokidle_lib
    run _pokidle_sprite_name '{"species":"zubat"}'
    [ "$status" -eq 0 ]
    [ "$output" = "zubat" ]
}

@test "_pokidle_sprite_name: falls back to species when variety is null" {
    source_pokidle_lib
    run _pokidle_sprite_name '{"species":"pidgey","variety":null}'
    [ "$status" -eq 0 ]
    [ "$output" = "pidgey" ]
}

@test "_pokidle_item_sprite: fetches under the resolved PokeAPI slug" {
    source_pokidle_lib
    POKIDLE_FETCH_SPRITES=1
    # A renamed item: pool/db keep the Showdown slug, but the sprite must be
    # fetched under the PokeAPI slug.
    showdown_item_pokeapi_slug() {
        if [ "$1" = "pretty-feather" ]; then printf 'pretty-wing\n'; else printf '%s\n' "$1"; fi
    }
    item_sprite() { printf 'FETCHED:%s' "$1"; }
    export -f showdown_item_pokeapi_slug item_sprite
    run _pokidle_item_sprite pretty-feather
    [ "$status" -eq 0 ]
    [ "$output" = "FETCHED:pretty-wing" ]
}

@test "_pokidle_item_sprite: plain item fetches under its own slug" {
    source_pokidle_lib
    POKIDLE_FETCH_SPRITES=1
    showdown_item_pokeapi_slug() { printf '%s\n' "$1"; }
    item_sprite() { printf 'FETCHED:%s' "$1"; }
    export -f showdown_item_pokeapi_slug item_sprite
    run _pokidle_item_sprite leftovers
    [ "$status" -eq 0 ]
    [ "$output" = "FETCHED:leftovers" ]
}
