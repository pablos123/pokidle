#!/usr/bin/env bash
# Public API: cache-aware fetchers and resource helpers.

function pokeapi_get() {
    local endpoint="$1"
    if cache_has "${endpoint}"; then
        cache_get "${endpoint}"
        return 0
    fi
    local body
    body="$(http_get "${endpoint}")" || return 1
    printf '%s' "${body}" | cache_put "${endpoint}"
    cache_get "${endpoint}"
}

function pokemon()  { pokeapi_get "pokemon/$1"; }
function move()     { pokeapi_get "move/$1"; }
function ability()  { pokeapi_get "ability/$1"; }
function type_()    { pokeapi_get "type/$1"; }
function species()  { pokeapi_get "pokemon-species/$1"; }
function item()     { pokeapi_get "item/$1"; }
function nature()   { pokeapi_get "nature/$1"; }

function natures() { pokeapi_get "nature?limit=100" | jq -r '.results[].name'; }

function pokemon_types() { pokemon "$1" | jq -r '.types[].type.name'; }
function pokemon_stats() { pokemon "$1" | jq -r '.stats[] | "\(.stat.name): \(.base_stat)"'; }
function pokemon_moves() { pokemon "$1" | jq -r '.moves[].move.name'; }
function pokemon_id()    { pokemon "$1" | jq -r '.id'; }
function pokemon_name()  { pokemon "$1" | jq -r '.name'; }

function pokemon_forms() {
    local key="$1" sp_json sp
    if sp_json="$(species "${key}" 2>/dev/null)"; then
        printf '%s' "${sp_json}" | jq -r '.varieties[].pokemon.name'
        return
    fi
    sp="$(pokemon "${key}" | jq -r '.species.name')" || return 1
    species "${sp}" | jq -r '.varieties[].pokemon.name'
}

function pokemon_sprite_url() {
    local name="$1" variant="${2:-front_default}" url
    url="$(pokemon "${name}" | jq -r --arg v "${variant}" '.sprites[$v] // empty')"
    if [[ -z "${url}" ]]; then
        printf 'pokemon_sprite_url: no sprite "%s" for %s\n' "${variant}" "${name}" >&2
        return 1
    fi
    printf '%s' "${url}"
}

function pokemon_sprite() {
    local name="$1" variant="${2:-front_default}" url ext path
    url="$(pokemon_sprite_url "${name}" "${variant}")" || return 1
    ext="${url##*.}"
    [[ "${ext}" =~ ^[a-zA-Z0-9]{1,5}$ ]] || ext=png
    path="$(cache_blob_path "sprites/${name}-${variant}" "${ext}")"
    if [[ ! -f "${path}" ]]; then
        http_download_url "${url}" "${path}" || return 1
    fi
    printf '%s\n' "${path}"
}

function item_sprite_url() {
    local name="$1" url
    url="$(item "${name}" | jq -r '.sprites.default // empty')"
    if [[ -z "${url}" ]]; then
        printf 'item_sprite_url: no sprite for %s\n' "${name}" >&2
        return 1
    fi
    printf '%s' "${url}"
}

function item_sprite() {
    local name="$1" url ext path
    url="$(item_sprite_url "${name}")" || return 1
    ext="${url##*.}"
    [[ "${ext}" =~ ^[a-zA-Z0-9]{1,5}$ ]] || ext=png
    path="$(cache_blob_path "sprites/items/${name}" "${ext}")"
    if [[ ! -f "${path}" ]]; then
        http_download_url "${url}" "${path}" || return 1
    fi
    printf '%s\n' "${path}"
}
