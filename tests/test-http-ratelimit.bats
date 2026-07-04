#!/usr/bin/env bats

load helpers

@test "http_get sleeps POKIDLE_POKEAPI_RATE_LIMIT_SLEEP seconds after a fetch" {
    # Stub curl to return immediately
    curl() { printf 'OK\n200'; }
    export -f curl

    POKIDLE_POKEAPI_RATE_LIMIT_SLEEP=1
    POKIDLE_POKEAPI_BASE_URL="http://stub.local"
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
    unset POKIDLE_POKEAPI_RATE_LIMIT_SLEEP
    POKIDLE_POKEAPI_BASE_URL="http://stub.local"
    source "$LIB_DIR/http.bash"

    # Just assert no crash and value path resolves
    run http_get "pokemon/1"
    [ "$status" -eq 0 ]
}

@test "http_get passes connect + max-time timeouts to curl" {
    local args="$BATS_TMPDIR/curlargs.$$"
    curl() { printf '%s\n' "$*" >"$args"; printf 'OK\n200'; }
    export -f curl
    POKIDLE_POKEAPI_RATE_LIMIT_SLEEP=0
    POKIDLE_POKEAPI_BASE_URL="http://stub.local"
    source "$LIB_DIR/http.bash"

    run http_get "pokemon/1"
    [ "$status" -eq 0 ]
    grep -q -- '--connect-timeout' "$args"
    grep -q -- '--max-time' "$args"
}

@test "http_download_url passes connect + max-time timeouts to curl" {
    local args="$BATS_TMPDIR/curlargs.$$"
    # Create the --output target so the trailing mv succeeds.
    curl() {
        printf '%s\n' "$*" >"$args"
        local a
        local next=""
        for a in "$@"; do
            if [[ "$next" == "1" ]]; then printf '' >"$a"; next=""; fi
            [[ "$a" == "--output" ]] && next=1
        done
        printf '200'
    }
    export -f curl
    POKIDLE_POKEAPI_BASE_URL="http://stub.local"
    source "$LIB_DIR/http.bash"

    run http_download_url "http://stub.local/x.png" "$BATS_TMPDIR/out.$$.png"
    [ "$status" -eq 0 ]
    grep -q -- '--connect-timeout' "$args"
    grep -q -- '--max-time' "$args"
}

@test "http_graphql passes connect + max-time timeouts to curl" {
    local args="$BATS_TMPDIR/curlargs.$$"
    curl() { printf '%s\n' "$*" >"$args"; printf '{"data":{}}'; }
    export -f curl
    POKIDLE_POKEAPI_RATE_LIMIT_SLEEP=0
    POKIDLE_POKEAPI_GRAPHQL_URL="http://stub.local/graphql"
    source "$LIB_DIR/http.bash"

    run http_graphql 'query { x }'
    [ "$status" -eq 0 ]
    grep -q -- '--connect-timeout' "$args"
    grep -q -- '--max-time' "$args"
}
