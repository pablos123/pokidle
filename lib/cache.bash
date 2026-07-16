#!/usr/bin/env bash
# Filesystem cache for pokeapi responses.

# Lives under the pokidle cache dir (sibling of the showdown cache) so all
# pokidle caches share one root and clean/relocation stays consistent.
: "${POKIDLE_POKEAPI_CACHE_DIR:=${POKIDLE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/pokidle}/pokeapi}"

# cache_path <endpoint>
# Print the JSON cache file path for an endpoint.
function cache_path {
    local endpoint
    endpoint="$(strip_slashes "$1")"
    printf '%s/%s.json' "${POKIDLE_POKEAPI_CACHE_DIR}" "${endpoint}"
}

# cache_has <endpoint>
# True (exit 0) if endpoint is cached.
function cache_has {
    [[ -f "$(cache_path "$1")" ]]
}

# cache_get <endpoint>
# Print the cached JSON for endpoint; return 1 if not cached.
function cache_get {
    local path
    path="$(cache_path "$1")"
    if [[ ! -f "${path}" ]]; then
        return 1
    fi
    cat -- "${path}"
}

# cache_put <endpoint>
# Store stdin as the cached JSON body for endpoint (atomic write).
function cache_put {
    local endpoint="$1"
    local path
    path="$(cache_path "${endpoint}")"
    atomic_write "${path}"
}

# cache_blob_path <key> [ext=bin]
# Print the blob cache path for key with the given extension.
function cache_blob_path {
    local key
    key="$(strip_slashes "$1")"
    local ext="${2:-bin}"
    printf '%s/%s.%s' "${POKIDLE_POKEAPI_CACHE_DIR}" "${key}" "${ext}"
}
