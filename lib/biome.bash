#!/usr/bin/env bash
# Biome config loader, lookup, rotation.

# biome_config_path
# Print the path to biomes.json (config dir preferred, repo root fallback).
# Returns 1 if neither location has the file.
function biome_config_path {
    local path
    if [[ -n "${POKIDLE_CONFIG_DIR:-}" && -f "${POKIDLE_CONFIG_DIR}/biomes.json" ]]; then
        path="${POKIDLE_CONFIG_DIR}/biomes.json"
    elif [[ -n "${POKIDLE_REPO_ROOT:-}" && -f "${POKIDLE_REPO_ROOT}/config/biomes.json" ]]; then
        path="${POKIDLE_REPO_ROOT}/config/biomes.json"
    else
        printf 'biome_config_path: cannot find biomes.json\n' >&2
        return 1
    fi
    printf '%s' "${path}"
}

# biome_load
# Print the raw biomes.json contents. Returns 1 if the file is not found.
function biome_load {
    local path
    if ! path="$(biome_config_path)"; then
        return 1
    fi
    cat "${path}"
}

# biome_get <id>
# Print the JSON object for biome <id>; return 1 if no such biome.
function biome_get {
    local id="$1"
    local out
    out="$(biome_load | jq --arg id "${id}" '.biomes[] | select(.id==$id)')"
    if [[ -z "${out}" ]]; then
        printf 'biome_get: unknown biome %s\n' "${id}" >&2
        return 1
    fi
    printf '%s' "${out}"
}

# biome_ids
# Print every biome id, one per line.
function biome_ids {
    biome_load | jq -r '.biomes[].id'
}

# biome_types_for <id>
# Print the types of biome <id>, one per line.
function biome_types_for {
    local id="$1"
    biome_get "${id}" | jq -r '.types[]'
}

# Hardcoded PokeAPI primary types. The validator asserts every entry here
# appears in ≥1 biome's types[]. The guard keeps the readonly global safe to
# re-source (the lib is sourced once per process normally, repeatedly in tests).
if [[ -z "${BIOME_PRIMARY_TYPES:-}" ]]; then
    declare -gra BIOME_PRIMARY_TYPES=(
        normal fighting flying poison ground rock bug ghost steel
        fire water grass electric psychic ice dragon dark fairy
    )
fi

# biome_validate
# Validate the biome config; return 1 with a diagnostic on the first failure.
# Rules:
#   1. Top-level .biomes array present.
#   2. Each biome has id, label, types[≥1].
#   3. No duplicate ids.
#   4. Every BIOME_PRIMARY_TYPES entry is covered by ≥1 biome's types.
#      Necessary condition for full berry coverage (every berry's
#      natural_gift_type is one of these 18).
function biome_validate {
    local cfg
    if ! cfg="$(biome_load)"; then
        return 1
    fi

    if ! jq -e 'has("biomes")' <<<"${cfg}" >/dev/null; then
        printf 'biome_validate: missing biomes array\n' >&2
        return 1
    fi

    local missing
    missing="$(jq -r '[.biomes[] | select(
        (has("id")|not) or (has("label")|not) or
        (has("types")|not) or ((.types | type) != "array") or (.types | length == 0)
    ) | (.id // "<no-id>")] | .[]' <<<"${cfg}")"
    if [[ -n "${missing}" ]]; then
        printf 'biome_validate: biomes missing keys or empty types: %s\n' "${missing}" >&2
        return 1
    fi

    local dupes
    dupes="$(jq -r '.biomes | group_by(.id) | map(select(length>1) | .[0].id) | .[]' <<<"${cfg}")"
    if [[ -n "${dupes}" ]]; then
        printf 'biome_validate: duplicate biome ids: %s\n' "${dupes}" >&2
        return 1
    fi

    # Type coverage: every BIOME_PRIMARY_TYPES entry must appear in some biome.
    local union
    union="$(jq -r '[.biomes[].types[]] | unique | .[]' <<<"${cfg}")"
    local t
    for t in "${BIOME_PRIMARY_TYPES[@]}"; do
        if ! grep --fixed-strings --line-regexp --quiet -- "${t}" <<<"${union}"; then
            printf 'biome_validate: type %s not covered by any biome\n' "${t}" >&2
            return 1
        fi
    done

    return 0
}

: "${BIOME_MIN_POOL_SIZE:=10}"

# _biome_pool_size <id>
# Print the total entries across all tiers in the cached pool for <id>;
# 0 if the pool file is missing.
function _biome_pool_size {
    local id="$1"
    local path="${POKIDLE_CACHE_DIR:-${HOME}/.cache/pokidle}/pools/${id}.json"
    if [[ ! -f "${path}" ]]; then
        printf '0'
        return
    fi
    jq '[.tiers[] | length] | add // 0' "${path}"
}

# _biome_eligible_ids
# Print ids whose pool has more than BIOME_MIN_POOL_SIZE entries, one per line.
function _biome_eligible_ids {
    local id
    local -i n
    while IFS= read -r id; do
        if [[ -z "${id}" ]]; then
            continue
        fi
        n="$(_biome_pool_size "${id}")"
        if ((n > BIOME_MIN_POOL_SIZE)); then
            printf '%s\n' "${id}"
        fi
    done < <(biome_ids)
}

# biome_pick_random
# Print a random eligible biome id; return 1 if none qualify.
function biome_pick_random {
    local -a ids
    mapfile -t ids < <(_biome_eligible_ids)
    local -i n="${#ids[@]}"
    if ((n == 0)); then
        printf 'biome_pick_random: no biome with pool>%d entries\n' "${BIOME_MIN_POOL_SIZE}" >&2
        return 1
    fi
    local -i idx=$((RANDOM % n))
    printf '%s' "${ids[idx]}"
}

# biome_pick_random_excluding <exclude>
# Print a random eligible biome id other than <exclude>; return 1 if none.
function biome_pick_random_excluding {
    local exclude="$1"
    local -a ids
    mapfile -t ids < <(_biome_eligible_ids)
    local -a filtered=()
    local id
    for id in "${ids[@]}"; do
        if [[ "${id}" != "${exclude}" ]]; then
            filtered+=("${id}")
        fi
    done
    local -i n="${#filtered[@]}"
    if ((n == 0)); then
        printf 'biome_pick_random_excluding: no eligible biome\n' >&2
        return 1
    fi
    local -i idx=$((RANDOM % n))
    printf '%s' "${filtered[idx]}"
}
