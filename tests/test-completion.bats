#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    export POKIDLE_CONFIG_DIR
    # shellcheck disable=SC1090
    source "$REPO_ROOT/share/completions/pokidle.bash"
}

teardown() { rm -rf "$POKIDLE_CONFIG_DIR"; }

# Drive a completion function the way bash would: COMP_WORDS is the full line
# split into words, COMP_CWORD indexes the word under the cursor. Prints each
# reply on its own line.
_complete() {
    local fn="$1"; shift
    COMP_WORDS=("$@")
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    COMPREPLY=()
    "$fn"
    printf '%s\n' "${COMPREPLY[@]}"
}

@test "pokidle: bare arg lists subcommands" {
    run _complete _pokidle pokidle ''
    [ "$status" -eq 0 ]
    [[ "$output" == *daemon* ]]
    [[ "$output" == *tick* ]]
    [[ "$output" == *switch-biome* ]]
    [[ "$output" == *uninstall* ]]
}

@test "pokidle: prefix filters subcommands" {
    run _complete _pokidle pokidle s
    [[ "$output" == *stats* ]]
    [[ "$output" == *setup* ]]
    [[ "$output" == *switch-biome* ]]
    [[ "$output" != *daemon* ]]
    [[ "$output" != *status* ]]   # status moved under `daemon`
}

@test "pokidle: daemon completes lifecycle verbs" {
    run _complete _pokidle pokidle daemon ''
    [[ "$output" == *run* ]]
    [[ "$output" == *restart* ]]
    [[ "$output" == *status* ]]
    [[ "$output" == *logs* ]]
    [[ "$output" == *enable* ]]
}

@test "pokidle: tick completes kinds" {
    run _complete _pokidle pokidle tick ''
    [[ "$output" == *encounter* ]]
    [[ "$output" == *legendary* ]]
    [[ "$output" == *evolve* ]]
}

@test "pokidle: clean completes targets" {
    run _complete _pokidle pokidle clean ''
    [[ "$output" == *pools* ]]
    [[ "$output" == *db* ]]
    [[ "$output" == *all* ]]
}

@test "pokidle: switch-biome completes biome ids from config" {
    run _complete _pokidle pokidle switch-biome ''
    [[ "$output" == *forest* ]]
    [[ "$output" == *cave* ]]
}

@test "pokidle: rebuild-pool completes biome ids" {
    run _complete _pokidle pokidle rebuild-pool ''
    [[ "$output" == *forest* ]]
}

@test "pokidle: encounters dash completes its flags" {
    run _complete _pokidle pokidle encounters --
    [[ "$output" == *--shiny* ]]
    [[ "$output" == *--json* ]]
    [[ "$output" == *--min-iv-total* ]]
}

@test "pokidle: items dash completes its flags" {
    run _complete _pokidle pokidle items --
    [[ "$output" == *--all* ]]
    [[ "$output" == *--biome* ]]
}

@test "pokidle: encounters bare arg returns no flag suggestions" {
    run _complete _pokidle pokidle encounters ''
    [[ "$output" != *--* ]]
}

@test "pokidle: export bare arg returns no flag suggestions" {
    run _complete _pokidle pokidle export ''
    [[ "$output" != *--* ]]
}

@test "pokidle: items bare arg returns no flag suggestions" {
    run _complete _pokidle pokidle items ''
    [[ "$output" != *--* ]]
}

@test "pokidle: clean bare arg returns targets but not --yes" {
    run _complete _pokidle pokidle clean ''
    [[ "$output" == *pools* ]]
    [[ "$output" != *--yes* ]]
}

@test "pokidle: clean dash completes --yes" {
    run _complete _pokidle pokidle clean --
    [[ "$output" == *--yes* ]]
}

@test "pokidle: current dash completes --items, --encounters and --no-images" {
    run _complete _pokidle pokidle current --
    [[ "$output" == *--items* ]]
    [[ "$output" == *--encounters* ]]
    [[ "$output" == *--no-images* ]]
}

@test "pokidle: current --i filters to --items" {
    run _complete _pokidle pokidle current --i
    [[ "$output" == *--items* ]]
    [[ "$output" != *--encounters* ]]
}

@test "pokidle: current bare arg returns no flag suggestions" {
    run _complete _pokidle pokidle current ''
    [[ "$output" != *--* ]]
}

@test "pokeapi: bare arg lists subcommands" {
    run _complete _pokeapi pokeapi ''
    [[ "$output" == *pokemon* ]]
    [[ "$output" == *natures* ]]
    [[ "$output" == *sprite-url* ]]
    [[ "$output" == *cache-clear* ]]
}

@test "pokeapi: prefix filters subcommands" {
    run _complete _pokeapi pokeapi spr
    [[ "$output" == *sprite-url* ]]
    [[ "$output" == *sprite* ]]
    [[ "$output" != *pokemon* ]]
}
