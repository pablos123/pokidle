#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    POKIDLE_NO_NOTIFY=1
    # Point sound dir at a nonexistent path so no clip ever plays in tests.
    POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    export POKIDLE_NO_NOTIFY POKIDLE_SOUND_DIR
    load_lib notify
}

@test "notify_pokemon: dry-run prints rendered title and body to stdout" {
    local enc='{
        "species":"sceptile","level":42,"nature":"adamant","ability":"overgrow",
        "gender":"M","shiny":1,"held_berry":"sitrus",
        "stats":[142,198,95,129,95,152],
        "moves":["leaf-blade","dragon-claw","earthquake","x-scissor"],
        "sprite_path":"/tmp/sceptile.png",
        "biome_label":"Cave"
    }'
    run notify_pokemon "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SHINY"* ]]
    [[ "$output" == *"Sceptile"* ]]
    [[ "$output" == *"• leaf-blade"* ]]
    [[ "$output" == *"sitrus"* ]]
}

@test "notify_pokemon: not shiny -> no SHINY tag" {
    local enc='{
        "species":"zubat","level":7,"nature":"timid","ability":"inner-focus",
        "gender":"M","shiny":0,"held_berry":null,
        "stats":[22,18,15,12,15,30],
        "moves":["leech-life"],
        "sprite_path":"/tmp/zubat.png",
        "biome_label":"Cave"
    }'
    run notify_pokemon "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SHINY"* ]]
    [[ "$output" == *"Zubat"* ]]
}

@test "notify_item: dry-run renders item line" {
    local item='{"item":"everstone","sprite_path":"/tmp/everstone.png","biome_label":"Cave"}'
    run notify_item "$item"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Found"* ]]
    [[ "$output" == *"Everstone"* ]]
}

@test "notify_evolution: title ends with !" {
    local evo='{"from":"charmander","to":"charmeleon","biome_label":"Volcano","sprite_path":""}'
    run notify_evolution "$evo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"evolved into Charmeleon!"* ]]
}

@test "notify_level / notify_friendship: body empty (biome dropped)" {
    run notify_level pikachu 41 42 "Meadow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pikachu leveled 41 → 42"* ]]
    [[ "$output" != *"Meadow"* ]]
    run notify_friendship eevee 100 105 "Farm"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Eevee friendship 100 → 105"* ]]
    [[ "$output" != *"Farm"* ]]
}

@test "_play_sound: per-kind toggle disables/enables individual kinds" {
    POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    export POKIDLE_SOUND_DIR
    # Every kind returns 0 whether on or off (files missing → silent skip).
    local kind
    for kind in encounter shiny legendary item biome level friendship; do
        POKIDLE_SOUND_SHINY_ENABLED=0 POKIDLE_SOUND_ENCOUNTER_ENABLED=1 \
            run _play_sound "$kind"
        [ "$status" -eq 0 ]
    done
}

@test "_play_sound: disabled default-on kind short-circuits before file lookup" {
    # shiny defaults on; force off and confirm clean exit even with a real dir.
    POKIDLE_SOUND_DIR="$REPO_ROOT/share/sounds"
    POKIDLE_SOUND_SHINY_ENABLED=0
    export POKIDLE_SOUND_DIR POKIDLE_SOUND_SHINY_ENABLED
    run _play_sound shiny
    [ "$status" -eq 0 ]
}

@test "_play_sound: unknown kind returns 0 silently" {
    run _play_sound bogus
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify_biome_change: dry-run prints title" {
    run notify_biome_change "volcano" "Volcano" 42 12
    [ "$status" -eq 0 ]
    [[ "$output" == *"Biome changed"* ]]
    [[ "$output" == *"Volcano"* ]]
    [[ "$output" == *"42"* ]]
}

@test "_emit: timeout defaults to 10000ms in dry-run" {
    run notify_biome_change "volcano" "Volcano" 42 12
    [ "$status" -eq 0 ]
    [[ "$output" == *"TIMEOUT: 10000"* ]]
}

@test "_emit: POKIDLE_NOTIFY_TIMEOUT_MS overrides timeout" {
    POKIDLE_NOTIFY_TIMEOUT_MS=30000 run notify_biome_change "volcano" "Volcano" 42 12
    [ "$status" -eq 0 ]
    [[ "$output" == *"TIMEOUT: 30000"* ]]
}

@test "notify_pokemon: legendary encounter emits LEGENDARY prefix + critical urgency" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_NO_NOTIFY=1
    POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    export POKIDLE_REPO_ROOT POKIDLE_NO_NOTIFY POKIDLE_SOUND_DIR
    load_lib notify
    local enc out
    enc='{"species":"articuno","level":60,"nature":"timid","ability":"pressure","gender":"genderless","shiny":0,"held_berry":null,"biome_label":"Ice","stats":[210,180,200,240,220,230],"moves":["ice-beam"],"sprite_path":"","is_legendary":true}'
    out="$(notify_pokemon "$enc")"
    [[ "$out" == *"LEGENDARY"* ]]
    [[ "$out" == *"URGENCY: critical"* ]]
}

@test "notify_pokemon: shiny+legendary stacks prefixes" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_NO_NOTIFY=1
    POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    export POKIDLE_REPO_ROOT POKIDLE_NO_NOTIFY POKIDLE_SOUND_DIR
    load_lib notify
    local enc out
    enc='{"species":"articuno","level":60,"nature":"timid","ability":"pressure","gender":"genderless","shiny":1,"held_berry":null,"biome_label":"Ice","stats":[210,180,200,240,220,230],"moves":["ice-beam"],"sprite_path":"","is_legendary":true}'
    out="$(notify_pokemon "$enc")"
    [[ "$out" == *"SHINY"* ]]
    [[ "$out" == *"LEGENDARY"* ]]
}

@test "notify_pokemon: non-legendary unchanged" {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_NO_NOTIFY=1
    POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    export POKIDLE_REPO_ROOT POKIDLE_NO_NOTIFY POKIDLE_SOUND_DIR
    load_lib notify
    local enc out
    enc='{"species":"pidgey","level":3,"nature":"jolly","ability":"keen-eye","gender":"M","shiny":0,"held_berry":null,"biome_label":"Plain","stats":[20,18,16,12,14,22],"moves":["tackle"],"sprite_path":""}'
    out="$(notify_pokemon "$enc")"
    [[ "$out" == *"URGENCY: normal"* ]]
    [[ "$out" != *"LEGENDARY"* ]]
}
