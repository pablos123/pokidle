#!/usr/bin/env bash
# Pokémon Showdown data source: disk-cached JSON used to make encounters
# born legal (legal abilities/moves) at encounter time.

: "${POKIDLE_SHOWDOWN_BASE_URL:=https://play.pokemonshowdown.com/data}"
: "${POKIDLE_SHOWDOWN_CACHE_DIR:=${POKIDLE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/pokidle}/showdown}"
: "${POKIDLE_SHOWDOWN_TTL:=604800}" # 7 days; Showdown data updates ~weekly.

# psdata_id <name>
# Showdown id for a PokeAPI slug OR a Showdown display name: lowercase, then
# drop every non-alphanumeric char. thundurus-therian->thundurustherian,
# ho-oh->hooh, "Mr. Mime"->mrmime.
function psdata_id {
    local s="${1,,}"
    printf '%s' "${s//[^a-z0-9]/}"
}

# _psdata_fetch <file>
# Print the raw JSON for a Showdown data file from the network. Returns 1 on
# failure. Split out so tests can stub it.
function _psdata_fetch {
    local file="$1"
    curl --silent --show-error --location --fail \
        --user-agent "${POKEAPI_USER_AGENT:-pokidle-bash/0.1}" \
        -- "${POKIDLE_SHOWDOWN_BASE_URL}/${file}.json"
}

# psdata_get <file>
# Print cached JSON for <file> (pokedex|learnsets|moves). Serve a fresh cache
# directly; otherwise refetch and cache; on fetch failure fall back to a stale
# cache if present. Returns 1 only when there is no data at all.
function psdata_get {
    local file="$1"
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/${file}.json"
    if [[ -f "${path}" ]]; then
        local now mtime
        now="$(date +%s)"
        mtime="$(stat -c %Y -- "${path}" 2>/dev/null || date -r "${path}" +%s)"
        if (( now - mtime < POKIDLE_SHOWDOWN_TTL )); then
            cat -- "${path}"
            return 0
        fi
    fi
    local body
    if body="$(_psdata_fetch "${file}")"; then
        printf '%s' "${body}" | atomic_write "${path}"
        printf '%s' "${body}"
        return 0
    fi
    if [[ -f "${path}" ]]; then
        cat -- "${path}"
        return 0
    fi
    return 1
}

# psdata_legal_abilities <variety-slug>
# Print "<ability-slug>\t<hidden>" per legal ability of the forme. hidden=1 for
# the "H" key. Abilities are forme-specific. Returns 1 if the id is unknown.
function psdata_legal_abilities {
    local id
    id="$(psdata_id "$1")"
    local pokedex
    if ! pokedex="$(psdata_get pokedex)"; then
        return 1
    fi
    local out
    out="$(jq -r --arg id "${id}" '
        (.[$id].abilities // empty) | to_entries[]
        | "\(.value | ascii_downcase | gsub("[^a-z0-9]+";"-"))\t\(if .key=="H" then "1" else "0" end)"
    ' <<<"${pokedex}")"
    if [[ -z "${out}" ]]; then
        return 1
    fi
    printf '%s\n' "${out}"
}

# psdata_legal_moves <variety-slug>
# Print one hyphenated move slug per legal move. Moves live under the base
# species (formes carry no learnset); union the base learnset up the prevo
# chain. Returns 1 if nothing resolves.
function psdata_legal_moves {
    local id
    id="$(psdata_id "$1")"
    local pokedex learn moves
    if ! pokedex="$(psdata_get pokedex)"; then return 1; fi
    if ! learn="$(psdata_get learnsets)"; then return 1; fi
    if ! moves="$(psdata_get moves)"; then return 1; fi

    local base
    base="$(jq -r --arg id "${id}" '.[$id].baseSpecies // empty' <<<"${pokedex}")"
    if [[ -n "${base}" ]]; then
        base="$(psdata_id "${base}")"
    else
        base="${id}"
    fi

    local cur="${base}"
    local -a ids=()
    local -A seen=()
    local -i guard=0
    while [[ -n "${cur}" ]] && ((guard++ < 20)); do
        local keys
        keys="$(jq -r --arg c "${cur}" '(.[$c].learnset // {}) | keys[]' <<<"${learn}")"
        local k
        while IFS= read -r k; do
            if [[ -n "${k}" && -z "${seen[$k]:-}" ]]; then
                seen[$k]=1
                ids+=("${k}")
            fi
        done <<<"${keys}"
        local prevo
        prevo="$(jq -r --arg c "${cur}" '.[$c].prevo // empty' <<<"${pokedex}")"
        if [[ -z "${prevo}" ]]; then
            break
        fi
        cur="$(psdata_id "${prevo}")"
    done

    if ((${#ids[@]} == 0)); then
        return 1
    fi
    local idsj
    idsj="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)"
    jq -r --argjson ids "${idsj}" '
        . as $m | $ids[] | ($m[.].name // empty)
        | select(. != "") | ascii_downcase | gsub("[^a-z0-9]+";"-")
    ' <<<"${moves}"
}
