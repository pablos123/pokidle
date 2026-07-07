#!/usr/bin/env bash
# Biome registry, lookup, rotation. The 36 biomes below are the fixed catalog —
# there is no config file. To change the catalog, edit this file.

# Ordered list of biome ids.
declare -ga BIOME_IDS=(
    forest jungle meadow orchard
    mountain cave crystal-cavern cliffside
    desert badlands savanna
    volcano forge wildfire
    ocean reef marsh tide-pool
    tundra glacier frozen-crypt
    sky storm-coast
    dragons-nest
    power-plant cyber-lab live-wire
    ruins mind-temple
    graveyard haunted-manor
    wasteland dojo
    farm urban cathedral
)

# Display label per biome id.
declare -gA BIOME_LABELS=(
    [forest]="Forest"
    [jungle]="Jungle"
    [meadow]="Meadow"
    [orchard]="Orchard"
    [mountain]="Mountain"
    [cave]="Cave"
    ["crystal-cavern"]="Crystal Cavern"
    [cliffside]="Cliffside"
    [desert]="Desert"
    [badlands]="Badlands"
    [savanna]="Savanna"
    [volcano]="Volcano"
    [forge]="Forge"
    [wildfire]="Wildfire"
    [ocean]="Ocean"
    [reef]="Reef"
    [marsh]="Marsh"
    ["tide-pool"]="Tide Pool"
    [tundra]="Tundra"
    [glacier]="Glacier"
    ["frozen-crypt"]="Frozen Crypt"
    [sky]="Sky"
    ["storm-coast"]="Storm Coast"
    ["dragons-nest"]="Dragon's Nest"
    ["power-plant"]="Power Plant"
    ["cyber-lab"]="Cyber Lab"
    ["live-wire"]="Live Wire"
    [ruins]="Ruins"
    ["mind-temple"]="Mind Temple"
    [graveyard]="Graveyard"
    ["haunted-manor"]="Haunted Manor"
    [wasteland]="Wasteland"
    [dojo]="Dojo"
    [farm]="Farm"
    [urban]="Urban"
    [cathedral]="Cathedral"
)

# Space-separated PokeAPI types per biome id. Used by the pool builder
# (encounter_build_pool) and the berry-natural-gift-type intersection.
declare -gA BIOME_TYPES=(
    [forest]="grass bug"
    [jungle]="grass poison"
    [meadow]="grass fairy"
    [orchard]="grass normal"
    [mountain]="rock ground"
    [cave]="rock dark"
    ["crystal-cavern"]="rock steel"
    [cliffside]="rock flying"
    [desert]="ground fire"
    [badlands]="ground dark"
    [savanna]="ground normal"
    [volcano]="fire dragon"
    [forge]="fire steel"
    [wildfire]="fire fighting"
    [ocean]="water ice"
    [reef]="water dragon"
    [marsh]="water poison"
    ["tide-pool"]="water bug"
    [tundra]="ice flying"
    [glacier]="ice fairy"
    ["frozen-crypt"]="ice ghost"
    [sky]="flying dragon"
    ["storm-coast"]="flying electric"
    ["dragons-nest"]="dragon psychic"
    ["power-plant"]="electric steel"
    ["cyber-lab"]="electric psychic"
    ["live-wire"]="electric fairy"
    [ruins]="psychic ghost"
    ["mind-temple"]="psychic fighting"
    [graveyard]="ghost dark"
    ["haunted-manor"]="ghost poison"
    [wasteland]="dark fighting"
    [dojo]="fighting bug"
    [farm]="normal bug"
    [urban]="normal poison"
    [cathedral]="steel fairy"
)

# Hardcoded PokeAPI primary types. The validator asserts every entry here
# appears in ≥1 biome's types[].
declare -ga BIOME_PRIMARY_TYPES=(
    normal fighting flying poison ground rock bug ghost steel
    fire water grass electric psychic ice dragon dark fairy
)

# biome_exists <id>
# True (exit 0) if <id> is a known biome.
function biome_exists {
    local id="$1"
    [[ -n "${BIOME_LABELS[${id}]:-}" ]]
}

# biome_label <id>
# Print the display label for biome <id>; return 1 if unknown.
function biome_label {
    local id="$1"
    local label="${BIOME_LABELS[${id}]:-}"
    if [[ -z "${label}" ]]; then
        printf 'biome_label: unknown biome %s\n' "${id}" >&2
        return 1
    fi
    printf '%s' "${label}"
}

# biome_ids
# Print every biome id, one per line, in catalog order.
function biome_ids {
    local id
    for id in "${BIOME_IDS[@]}"; do
        printf '%s\n' "${id}"
    done
}

# biome_types_for <id>
# Print the types of biome <id>, one per line. Return 1 if unknown.
function biome_types_for {
    local id="$1"
    local raw="${BIOME_TYPES[${id}]:-}"
    if [[ -z "${raw}" ]]; then
        printf 'biome_types_for: unknown biome %s\n' "${id}" >&2
        return 1
    fi
    local -a types
    read -ra types <<<"${raw}"
    local t
    for t in "${types[@]}"; do
        printf '%s\n' "${t}"
    done
}

# biome_validate
# Assert every BIOME_PRIMARY_TYPES entry is covered by ≥1 biome's types. This
# is a necessary condition for full berry coverage (every berry's
# natural_gift_type is one of these 18). Return 1 with a diagnostic on the
# first missing type. The id/label/types data is hardcoded above so structural
# checks are not needed.
function biome_validate {
    local -A seen=()
    local id
    for id in "${BIOME_IDS[@]}"; do
        local raw="${BIOME_TYPES[${id}]:-}"
        local -a types
        read -ra types <<<"${raw}"
        local t
        for t in "${types[@]}"; do
            seen[${t}]=1
        done
    done
    local primary
    for primary in "${BIOME_PRIMARY_TYPES[@]}"; do
        if [[ -z "${seen[${primary}]:-}" ]]; then
            printf 'biome_validate: type %s not covered by any biome\n' "${primary}" >&2
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
