#!/usr/bin/env bash
# HTTP layer wrapping curl.

: "${POKEAPI_BASE_URL:=https://pokeapi.co/api/v2}"
: "${POKEAPI_USER_AGENT:=pokeapi-bash/0.1}"

# http_get <endpoint>
# Fetch endpoint from the live API and print the JSON body. Returns 1 on
# transport failure or non-2xx status. Sleeps after each fetch to rate-limit.
function http_get {
    local endpoint="${1#/}"
    local url="${POKEAPI_BASE_URL}/${endpoint}"
    local body
    local status
    if ! body="$(curl --silent --show-error \
        --user-agent "${POKEAPI_USER_AGENT}" \
        --header 'Accept: application/json' \
        --write-out $'\n%{http_code}' \
        --fail-with-body \
        -- "${url}")"; then
        status="${body##*$'\n'}"
        printf 'http_get: %s failed (status=%s)\n' "${url}" "${status:-?}" >&2
        return 1
    fi
    status="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "${status}" != 2?? ]]; then
        printf 'http_get: %s returned %s\n' "${url}" "${status}" >&2
        return 1
    fi
    printf '%s' "${body}"
    # Be polite: pause after every live fetch (cache misses only — pokeapi_get
    # short-circuits on cache hits).
    sleep "${POKEAPI_RATE_LIMIT_SLEEP:-0.5}"
}

# http_download_url <url> <out>
# Download url to out (atomic). Returns 1 on transport failure or non-2xx status.
function http_download_url {
    local url="$1"
    local out="$2"
    local dir="${out%/*}"
    mkdir -p -- "${dir}"
    local tmp
    tmp="$(mktemp -- "${dir}/.tmp.XXXXXX")"
    local status
    if ! status="$(curl --silent --show-error --location \
        --user-agent "${POKEAPI_USER_AGENT}" \
        --output "${tmp}" \
        --write-out '%{http_code}' \
        -- "${url}")"; then
        rm -f -- "${tmp}"
        printf 'http_download_url: %s failed\n' "${url}" >&2
        return 1
    fi
    if [[ "${status}" != 2?? ]]; then
        rm -f -- "${tmp}"
        printf 'http_download_url: %s returned %s\n' "${url}" "${status}" >&2
        return 1
    fi
    mv -- "${tmp}" "${out}"
}
