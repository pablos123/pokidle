#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib render
    load_lib showdown
    seed_showdown
}

@test "species_display_name: resolves the Showdown display name when available" {
    run species_display_name "meowth-galar"
    [ "$status" -eq 0 ]
    [ "$output" = "Meowth-Galar" ]
}

# _pokidle_render_encounter_row <ts> <biome> <lvl> <form> <shiny> <nat> <abil> <gender> <stats> <ivs> <evs> <moves> <held>

@test "render_encounter_row: form resolves to Showdown display name" {
    run _pokidle_render_encounter_row "2026-07-04 12:00" forest 12 meowth-galar 0 \
        adamant pickup M 100/80/70/60/50/90 31/31/31/31/31/31 0/0/0/0/0/0 \
        scratch, water-gun ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Meowth-Galar"* ]]
}

@test "render_encounter_row: unknown form falls back to titlecased slug" {
    run _pokidle_render_encounter_row "2026-07-04 12:00" forest 12 foo-bar 0 \
        adamant overgrow M 100/80/70/60/50/90 31/31/31/31/31/31 0/0/0/0/0/0 \
        tackle ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Foo Bar"* ]]
}

@test "render_encounter_row: ability and nature are titlecased" {
    run _pokidle_render_encounter_row "2026-07-04 12:00" forest 12 sceptile 0 \
        adamant solar-power M 100/80/70/60/50/90 31/31/31/31/31/31 0/0/0/0/0/0 \
        tackle ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Adamant"* ]]
    [[ "$output" == *"Solar Power"* ]]
}

@test "render_encounter_row: moves are titlecased" {
    run _pokidle_render_encounter_row "2026-07-04 12:00" forest 12 sceptile 0 \
        adamant overgrow M 100/80/70/60/50/90 31/31/31/31/31/31 0/0/0/0/0/0 \
        "leaf-blade, water-gun" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Leaf Blade, Water Gun"* ]]
}

@test "render_encounter_row: held berry titlecased and shiny sparkle preserved" {
    run _pokidle_render_encounter_row "2026-07-04 12:00" forest 12 sceptile 1 \
        adamant overgrow M 100/80/70/60/50/90 31/31/31/31/31/31 0/0/0/0/0/0 \
        tackle sitrus
    [ "$status" -eq 0 ]
    [[ "$output" == *"@ Sitrus Berry"* ]]
    [[ "$output" == *"✨"* ]]
}
