#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib encounter
    stub_pokeapi
}

@test "encounter_compute_stat HP: known Garchomp at lvl 100" {
    # Garchomp HP base 108, IV 31, EV 0, lvl 100 -> 357
    run encounter_compute_stat hp 108 31 0 100 1.0
    [ "$status" -eq 0 ]
    [ "$output" = "357" ]
}

@test "encounter_compute_stat Atk: Adamant Garchomp lvl 100 31IV 252EV" {
    # base 130, IV 31, EV 252, lvl 100, Adamant +atk = 1.1 -> 394
    run encounter_compute_stat attack 130 31 252 100 1.1
    [ "$status" -eq 0 ]
    [ "$output" = "394" ]
}

@test "encounter_compute_stat with neutral nature equals base case" {
    run encounter_compute_stat speed 102 31 252 100 1.0
    [ "$status" -eq 0 ]
    [ "$output" = "303" ]
}

@test "encounter_compute_all_stats: missing base for stat returns non-zero" {
    local base_json='[{"base_stat":108,"stat":{"name":"hp"}}]'
    run encounter_compute_all_stats "$base_json" "31 31 31 31 31 31" "0 0 0 0 0 0" 100 "1.0 1.0 1.0 1.0 1.0 1.0"
    [ "$status" -ne 0 ]
}
