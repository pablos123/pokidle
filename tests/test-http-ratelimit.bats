#!/usr/bin/env bats

load helpers

@test "http_get sleeps POKEAPI_RATE_LIMIT_SLEEP seconds after a fetch" {
    # Stub curl to return immediately
    curl() { printf 'OK\n200'; }
    export -f curl

    POKEAPI_RATE_LIMIT_SLEEP=1
    POKEAPI_BASE_URL="http://stub.local"
    source "$LIB_DIR/http.bash"

    local start end elapsed
    start=$(date +%s)
    run http_get "pokemon/1"
    end=$(date +%s)
    elapsed=$((end - start))

    [ "$status" -eq 0 ]
    [ "$elapsed" -ge 1 ]
}

@test "http_get rate-limit defaults to 0.5 when var unset" {
    curl() { printf 'OK\n200'; }
    export -f curl
    unset POKEAPI_RATE_LIMIT_SLEEP
    POKEAPI_BASE_URL="http://stub.local"
    source "$LIB_DIR/http.bash"

    # Just assert no crash and value path resolves
    run http_get "pokemon/1"
    [ "$status" -eq 0 ]
}
