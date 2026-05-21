#!/usr/bin/env bash
# lib/biome.bash — biome config loader, lookup, rotation.

biome_config_path() {
    local p
    if [[ -n "${POKIDLE_CONFIG_DIR:-}" && -f "${POKIDLE_CONFIG_DIR}/biomes.json" ]]; then
        p="${POKIDLE_CONFIG_DIR}/biomes.json"
    elif [[ -n "${POKIDLE_REPO_ROOT:-}" && -f "${POKIDLE_REPO_ROOT}/config/biomes.json" ]]; then
        p="${POKIDLE_REPO_ROOT}/config/biomes.json"
    else
        printf 'biome_config_path: cannot find biomes.json\n' >&2
        return 1
    fi
    printf '%s' "$p"
}

biome_load() {
    local p
    p="$(biome_config_path)" || return 1
    cat "$p"
}

biome_get() {
    local id="$1"
    local out
    out="$(biome_load | jq --arg id "$id" '.biomes[] | select(.id==$id)')"
    [[ -n "$out" ]] || { printf 'biome_get: unknown biome %s\n' "$id" >&2; return 1; }
    printf '%s' "$out"
}

biome_ids() {
    biome_load | jq -r '.biomes[].id'
}

biome_types_for() {
    local id="$1"
    biome_get "$id" | jq -r '.types[]'
}

# Hardcoded PokeAPI primary types. The validator asserts every entry here
# appears in ≥1 biome's types[].
BIOME_PRIMARY_TYPES=(
    normal fighting flying poison ground rock bug ghost steel
    fire water grass electric psychic ice dragon dark fairy
)

# Validation rules:
#   1. Top-level .biomes array present.
#   2. Each biome has id, label, types[≥1].
#   3. No duplicate ids.
#   4. Every BIOME_PRIMARY_TYPES entry is covered by ≥1 biome's types.
#      This subsumes coverage of ENCOUNTER_HELD_ITEMS_BY_TYPE keys (same
#      18 type names) and is a necessary condition for full berry
#      coverage (every berry's natural_gift_type is one of these 18).
biome_validate() {
    local cfg
    cfg="$(biome_load)" || return 1

    if ! jq -e 'has("biomes")' <<< "$cfg" > /dev/null; then
        printf 'biome_validate: missing biomes array\n' >&2
        return 1
    fi

    local missing
    missing="$(jq -r '[.biomes[] | select(
        (has("id")|not) or (has("label")|not) or
        (has("types")|not) or ((.types | type) != "array") or (.types | length == 0)
    ) | (.id // "<no-id>")] | .[]' <<< "$cfg")"
    if [[ -n "$missing" ]]; then
        printf 'biome_validate: biomes missing keys or empty types: %s\n' "$missing" >&2
        return 1
    fi

    local dupes
    dupes="$(jq -r '.biomes | group_by(.id) | map(select(length>1) | .[0].id) | .[]' <<< "$cfg")"
    if [[ -n "$dupes" ]]; then
        printf 'biome_validate: duplicate biome ids: %s\n' "$dupes" >&2
        return 1
    fi

    # Type coverage: every BIOME_PRIMARY_TYPES entry must appear in some biome.
    local union t
    union="$(jq -r '[.biomes[].types[]] | unique | .[]' <<< "$cfg")"
    for t in "${BIOME_PRIMARY_TYPES[@]}"; do
        if ! grep -Fxq "$t" <<< "$union"; then
            printf 'biome_validate: type %s not covered by any biome\n' "$t" >&2
            return 1
        fi
    done

    return 0
}

: "${BIOME_MIN_POOL_SIZE:=10}"

# Total entries across all tiers in the cached pool for <biome>. 0 if the
# pool file is missing.
_biome_pool_size() {
    local id="$1"
    local p="${POKIDLE_CACHE_DIR:-$HOME/.cache/pokidle}/pools/$id.json"
    [[ -f "$p" ]] || { printf '0'; return; }
    jq '[.tiers[] | length] | add // 0' "$p"
}

# Echoes ids whose pool has more than $BIOME_MIN_POOL_SIZE entries.
_biome_eligible_ids() {
    local id n
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        n="$(_biome_pool_size "$id")"
        (( n > BIOME_MIN_POOL_SIZE )) && printf '%s\n' "$id"
    done < <(biome_ids)
}

biome_pick_random() {
    local ids n idx
    mapfile -t ids < <(_biome_eligible_ids)
    n="${#ids[@]}"
    (( n > 0 )) || { printf 'biome_pick_random: no biome with pool>%d entries\n' "$BIOME_MIN_POOL_SIZE" >&2; return 1; }
    idx=$((RANDOM % n))
    printf '%s' "${ids[$idx]}"
}

biome_pick_random_excluding() {
    local exclude="$1"
    local ids filtered idx n
    mapfile -t ids < <(_biome_eligible_ids)
    filtered=()
    local id
    for id in "${ids[@]}"; do
        [[ "$id" != "$exclude" ]] && filtered+=("$id")
    done
    n="${#filtered[@]}"
    (( n > 0 )) || { printf 'biome_pick_random_excluding: no eligible biome\n' >&2; return 1; }
    idx=$((RANDOM % n))
    printf '%s' "${filtered[$idx]}"
}
