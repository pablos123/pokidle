#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib helpers
    load_lib psdata
    seed_psdata
}

@test "psdata_id strips punctuation and lowercases" {
    run psdata_id "thundurus-therian"
    [ "$output" = "thundurustherian" ]
    run psdata_id "Ho-Oh"
    [ "$output" = "hooh" ]
}

@test "psdata_get serves a fresh cached file without fetching" {
    _psdata_fetch() { touch "${BATS_TEST_TMPDIR}/fetch_called"; return 1; }
    export -f _psdata_fetch
    run psdata_get pokedex
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/fetch_called" ]
    echo "$output" | jq -e '.thundurustherian.baseSpecies == "Thundurus"'
}

@test "psdata_get returns 1 when no cache and fetch fails" {
    rm -f "${POKIDLE_SHOWDOWN_CACHE_DIR}/pokedex.json"
    run psdata_get pokedex
    [ "$status" -ne 0 ]
}

@test "psdata_get falls back to stale cache when fetch fails" {
    # Make the cache look stale; fetch is stubbed to fail.
    touch -d "30 days ago" "${POKIDLE_SHOWDOWN_CACHE_DIR}/pokedex.json"
    run psdata_get pokedex
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.corviknight.prevo == "Corvisquire"'
}

@test "psdata_legal_abilities: forme-specific abilities with hidden flag" {
    run psdata_legal_abilities "thundurus-therian"
    [ "$status" -eq 0 ]
    [ "$output" = $'volt-absorb\t0' ]
}

@test "psdata_legal_abilities: marks the hidden ability" {
    run psdata_legal_abilities "corviknight"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx $'mirror-armor\t1'
    echo "$output" | grep -qx $'pressure\t0'
}

@test "psdata_legal_abilities: returns 1 for unknown id" {
    run psdata_legal_abilities "missingno"
    [ "$status" -ne 0 ]
}

@test "psdata_legal_moves: forme resolves to base species learnset" {
    run psdata_legal_moves "thundurus-therian"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "thunderbolt"
    echo "$output" | grep -qx "nasty-plot"
}

@test "psdata_legal_moves: unions the prevo chain and slugifies names" {
    run psdata_legal_moves "corviknight"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "double-edge"   # corviknight, slugified
    echo "$output" | grep -qx "peck"          # rookidee (grandparent)
}
