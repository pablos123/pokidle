#!/usr/bin/env bash
# HTTP layer wrapping curl.

: "${POKEAPI_BASE_URL:=https://pokeapi.co/api/v2}"
: "${POKEAPI_USER_AGENT:=pokeapi-bash/0.1}"

function http_get() {
    local endpoint="${1#/}"
    local url="${POKEAPI_BASE_URL}/${endpoint}"
    local body status
    body="$(curl -sS \
        -A "${POKEAPI_USER_AGENT}" \
        -H 'Accept: application/json' \
        -w $'\n%{http_code}' \
        --fail-with-body \
        -- "${url}")" || {
        status="${body##*$'\n'}"
        printf 'http_get: %s failed (status=%s)\n' "${url}" "${status:-?}" >&2
        return 1
    }
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

function http_download_url() {
    local url="$1" out="$2" dir tmp status
    dir="${out%/*}"
    mkdir -p -- "${dir}"
    tmp="$(mktemp -- "${dir}/.tmp.XXXXXX")"
    status="$(curl -sS -L \
        -A "${POKEAPI_USER_AGENT}" \
        -o "${tmp}" \
        -w '%{http_code}' \
        -- "${url}")" || {
        rm -f -- "${tmp}"
        printf 'http_download_url: %s failed\n' "${url}" >&2
        return 1
    }
    if [[ "${status}" != 2?? ]]; then
        rm -f -- "${tmp}"
        printf 'http_download_url: %s returned %s\n' "${url}" "${status}" >&2
        return 1
    fi
    mv -- "${tmp}" "${out}"
}
