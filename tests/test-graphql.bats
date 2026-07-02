#!/usr/bin/env bats

load helpers

setup() {
    load_lib helpers
    load_lib http
    load_lib cache
    load_lib api
    POKEAPI_CACHE_DIR="$(mktemp -d "${BATS_TMPDIR}/gqlcache.XXXXXX")"
    export POKEAPI_CACHE_DIR
}

@test "http_graphql: POSTs the query and returns the JSON body on success" {
    curl() { printf '{"data":{"item":[{"name":"leftovers"}]}}'; }
    export -f curl
    POKEAPI_GRAPHQL_URL="http://stub.local"
    run http_graphql 'query { item { name } }'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.data.item[0].name == "leftovers"'
}

@test "http_graphql: returns 1 when the response carries GraphQL errors" {
    curl() { printf '{"errors":[{"message":"field not found"}]}'; }
    export -f curl
    POKEAPI_GRAPHQL_URL="http://stub.local"
    run http_graphql 'query { nope }'
    [ "$status" -ne 0 ]
}

@test "pokeapi_graphql: fetches once then serves cache without refetching" {
    http_graphql() { touch "${BATS_TEST_TMPDIR}/gql_called"; printf '{"data":{"x":1}}'; }
    export -f http_graphql
    run pokeapi_graphql demo-key 'query { x }'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.data.x == 1'
    [ -f "${BATS_TEST_TMPDIR}/gql_called" ]
    rm -f "${BATS_TEST_TMPDIR}/gql_called"
    # Second call must hit cache, not the network stub.
    run pokeapi_graphql demo-key 'query { x }'
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/gql_called" ]
}

@test "pokeapi_graphql: returns 1 when fetch fails and nothing is cached" {
    http_graphql() { return 1; }
    export -f http_graphql
    run pokeapi_graphql missing-key 'query { x }'
    [ "$status" -ne 0 ]
}
