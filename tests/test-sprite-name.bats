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
