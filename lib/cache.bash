#!/usr/bin/env bash
# Filesystem cache for pokeapi responses.

: "${POKEAPI_CACHE_DIR:=${XDG_CACHE_HOME:-${HOME}/.cache}/pokeapi}"

function cache_path() {
    local endpoint="${1#/}"
    endpoint="${endpoint%/}"
    printf '%s/%s.json' "${POKEAPI_CACHE_DIR}" "${endpoint}"
}

function cache_has() {
    [[ -f "$(cache_path "$1")" ]]
}

function cache_get() {
    local path
    path="$(cache_path "$1")"
    [[ -f "${path}" ]] || return 1
    cat -- "${path}"
}

function cache_put() {
    local endpoint="$1" path tmp dir
    path="$(cache_path "${endpoint}")"
    dir="${path%/*}"
    mkdir -p -- "${dir}"
    tmp="$(mktemp -- "${dir}/.tmp.XXXXXX")"
    cat > "${tmp}"
    mv -- "${tmp}" "${path}"
}

function cache_blob_path() {
    local key="${1#/}"
    key="${key%/}"
    local ext="${2:-bin}"
    printf '%s/%s.%s' "${POKEAPI_CACHE_DIR}" "${key}" "${ext}"
}

function cache_clear() {
    if [[ -n "${1-}" ]]; then
        rm -f -- "$(cache_path "$1")"
    else
        rm -rf -- "${POKEAPI_CACHE_DIR}"
    fi
}
