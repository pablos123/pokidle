#!/usr/bin/env bash
# Pool build, evo expansion, rolls, stat formulas.
# Depends on pokeapi_get from lib/api.bash.

# All 6 stats in canonical order. Guarded so the readonly global survives the
# repeated re-sourcing the test harness does.
if [[ -z "${ENCOUNTER_STATS:-}" ]]; then
    declare -gra ENCOUNTER_STATS=(hp attack defense special-attack special-defense speed)
fi

# Rarity tier definitions. Tiers listed common-first; ENCOUNTER_TIER_ROLL_WEIGHT[i]
# is the roll weight of ENCOUNTER_TIERS[i] in encounter_roll_pool_entry.
if [[ -z "${ENCOUNTER_TIERS:-}" ]]; then
    declare -gra ENCOUNTER_TIERS=(common uncommon rare very_rare)
    declare -gra ENCOUNTER_TIER_ROLL_WEIGHT=(60 25 12 3)
fi

# _json_int_array <space-separated-ints>
# Print a JSON array literal from space-separated integers.
function _json_int_array {
    local -a parts
    read -ra parts <<<"$1"
    local IFS=,
    printf '[%s]' "${parts[*]}"
}

# encounter_evolution_items
# Print one PokeAPI evolution-item slug per line (item-category/evolution).
# Cached by the pokeapi cache; empty on fetch failure (fail-open).
function encounter_evolution_items {
    local body
    if ! body="$(pokeapi_get "item-category/evolution")"; then
        return 0
    fi
    jq -r '.items[].name' <<<"${body}"
}

# encounter_tier_for_capture_rate <capture_rate>
# capture_rate: PokeAPI value 0..255. Higher = easier to catch = more common.
# Thresholds 150/75/25 bucket into common/uncommon/rare/very_rare.
function encounter_tier_for_capture_rate {
    local -i cr="$1"
    if ((cr >= 150)); then
        printf 'common'
    elif ((cr >= 75)); then
        printf 'uncommon'
    elif ((cr >= 25)); then
        printf 'rare'
    else
        printf 'very_rare'
    fi
}

# encounter_natures_list
# Print every nature name, one per line. Returns 1 on fetch failure.
function encounter_natures_list {
    local body
    if ! body="$(pokeapi_get "nature?limit=100")"; then
        return 1
    fi
    jq -r '.results[].name' <<<"${body}"
}

# encounter_nature_mods <nature>
# Print 6 space-separated floats: nature_mod for hp atk def spa spd spe.
function encounter_nature_mods {
    local nature="$1"
    local nat
    if ! nat="$(pokeapi_get "nature/${nature}")"; then
        return 1
    fi
    local inc
    inc="$(jq -r '.increased_stat.name // ""' <<<"${nat}")"
    local dec
    dec="$(jq -r '.decreased_stat.name // ""' <<<"${nat}")"

    local -a out=()
    local s
    for s in "${ENCOUNTER_STATS[@]}"; do
        if [[ "${s}" == "${inc}" ]]; then
            out+=("1.1")
        elif [[ "${s}" == "${dec}" ]]; then
            out+=("0.9")
        else
            out+=("1.0")
        fi
    done
    printf '%s' "${out[*]}"
}

# encounter_roll_ivs
# Print 6 space-separated IVs; exactly 3 random distinct positions are a
# perfect 31, the other 3 are random 0..31.
function encounter_roll_ivs {
    local -a out=()
    local -i i
    for i in {0..5}; do
        out+=("$((RANDOM % 32))")
    done
    # Force three random distinct positions to a perfect 31.
    local -a pos=(0 1 2 3 4 5)
    local -i j tmp r
    for ((j = 5; j > 0; j--)); do
        r=$((RANDOM % (j + 1)))
        tmp=${pos[j]}; pos[j]=${pos[r]}; pos[r]=$tmp
    done
    out[${pos[0]}]=31
    out[${pos[1]}]=31
    out[${pos[2]}]=31
    printf '%s' "${out[*]}"
}

# encounter_roll_evs
# Competitive spread: two random distinct stats at 252, one more at 4 (508
# total). Prints 6 space-separated EVs (hp atk def spa spd spe).
function encounter_roll_evs {
    local -a out=(0 0 0 0 0 0)
    local -a pos=(0 1 2 3 4 5)
    local -i j tmp r
    for ((j = 5; j > 0; j--)); do
        r=$((RANDOM % (j + 1)))
        tmp=${pos[j]}; pos[j]=${pos[r]}; pos[r]=$tmp
    done
    out[${pos[0]}]=252
    out[${pos[1]}]=252
    out[${pos[2]}]=4
    printf '%s' "${out[*]}"
}

# encounter_roll_level <lo> <hi>
# Print a random integer level in the inclusive range [lo, hi].
function encounter_roll_level {
    local -i lo="$1"
    local -i hi="$2"
    local -i span=$((hi - lo + 1))
    printf '%d' "$((lo + RANDOM % span))"
}

# encounter_compute_stat <stat-name> <base> <iv> <ev> <level> <nature_mod>
# stat-name in {hp, attack, defense, special-attack, special-defense, speed}.
# nature_mod is "0.9", "1.0", or "1.1". Prints the final stat value.
function encounter_compute_stat {
    local stat="$1"
    local -i base="$2"
    local -i iv="$3"
    local -i ev="$4"
    local -i level="$5"
    local nm="$6"
    # core = floor(((2*base + iv + floor(ev/4)) * level) / 100)
    local -i ev_q=$((ev / 4))
    local -i core=$(((2 * base + iv + ev_q) * level / 100))
    if [[ "${stat}" == "hp" ]]; then
        printf '%d' "$((core + level + 10))"
        return
    fi
    # other = floor((core + 5) * nm)
    case "${nm}" in
        "1.0") printf '%d' "$((core + 5))" ;;
        "1.1") printf '%d' "$(((core + 5) * 110 / 100))" ;;
        "0.9") printf '%d' "$(((core + 5) * 90 / 100))" ;;
        *)
            printf 'encounter_compute_stat: bad nature_mod %s\n' "${nm}" >&2
            return 1
            ;;
    esac
}

# encounter_compute_all_stats <base_json> <ivs_str> <evs_str> <level> <mods_str>
# base_json is .stats[] from /pokemon (array of {base_stat, stat:{name}}).
# Prints "hp atk def spa spd spe" final stats. Returns 1 if a base stat is missing.
function encounter_compute_all_stats {
    local base_json="$1"
    local ivs_str="$2"
    local evs_str="$3"
    local level="$4"
    local mods_str="$5"
    local -a ivs
    read -ra ivs <<<"${ivs_str}"
    local -a evs
    read -ra evs <<<"${evs_str}"
    local -a mods
    read -ra mods <<<"${mods_str}"
    # Pull all six base stats in one jq pass (a name->base map, emitted in
    # ENCOUNTER_STATS order) instead of re-scanning .stats once per stat.
    local -a bases
    mapfile -t bases < <(jq -r '
        (reduce .[] as $s ({}; .[$s.stat.name] = $s.base_stat)) as $m
        | $m["hp"], $m["attack"], $m["defense"],
          $m["special-attack"], $m["special-defense"], $m["speed"]' <<<"${base_json}")
    local -a out=()
    local -i i
    for i in {0..5}; do
        local stat="${ENCOUNTER_STATS[i]}"
        local base="${bases[i]}"
        if [[ -z "${base}" || "${base}" == "null" ]]; then
            printf 'encounter_compute_all_stats: missing base for %s\n' "${stat}" >&2
            return 1
        fi
        out+=("$(encounter_compute_stat "${stat}" "${base}" "${ivs[i]}" "${evs[i]}" "${level}" "${mods[i]}")")
    done
    printf '%s' "${out[*]}"
}

# encounter_roll_ability <species>
# Roll an ability. Prints JSON {name, is_hidden}. Returns 1 on fetch failure.
function encounter_roll_ability {
    local species="$1"
    local poke
    if ! poke="$(pokeapi_get "pokemon/${species}")"; then
        return 1
    fi
    local -i hidden_rate="${POKIDLE_HIDDEN_ABILITY_RATE:-5}"

    local hidden_arr
    hidden_arr="$(jq '[.abilities[] | select(.is_hidden==true) | {name: .ability.name, is_hidden: true}]' <<<"${poke}")"
    local normal_arr
    normal_arr="$(jq '[.abilities[] | select(.is_hidden==false) | {name: .ability.name, is_hidden: false}]' <<<"${poke}")"

    local -i roll=$((RANDOM % 100))
    local -i hidden_len
    hidden_len="$(jq 'length' <<<"${hidden_arr}")"
    local pool
    if ((roll < hidden_rate && hidden_len > 0)); then
        pool="${hidden_arr}"
    else
        pool="${normal_arr}"
    fi
    local -i pool_len
    pool_len="$(jq 'length' <<<"${pool}")"
    if ((pool_len == 0)); then
        pool="${hidden_arr}" # last-resort
    fi

    local -i n
    n="$(jq 'length' <<<"${pool}")"
    local -i idx=$((RANDOM % n))
    jq -c ".[${idx}]" <<<"${pool}"
}

# encounter_roll_moves <species> <level> [fallback_species]
# Roll up to 4 moves from the union of (level-up + machine + egg + tutor) where
# level_learned_at <= level. Prints a JSON array of move-name strings.
# If the moveset is empty and a distinct fallback_species is given, retry with
# it — guards against forms PokeAPI ships move-less (the encounter keeps its
# bare species name, so the base species is the right fallback).
function encounter_roll_moves {
    local species="$1"
    local level="$2"
    local fallback="${3:-}"
    local poke
    if ! poke="$(pokeapi_get "pokemon/${species}")"; then
        return 1
    fi

    local candidates
    candidates="$(jq -r --argjson lvl "${level}" '
        [
          .moves[] |
          .move.name as $name |
          .version_group_details[] |
          select(
            (.move_learn_method.name | IN("level-up","machine","egg","tutor")) and
            (.level_learned_at <= $lvl)
          ) | $name
        ] | unique | .[]
    ' <<<"${poke}")"

    local -a arr=()
    local m
    while IFS= read -r m; do
        if [[ -n "${m}" ]]; then
            arr+=("${m}")
        fi
    done <<<"${candidates}"

    local -i n="${#arr[@]}"
    if ((n == 0)); then
        if [[ -n "${fallback}" && "${fallback}" != "${species}" ]]; then
            encounter_roll_moves "${fallback}" "${level}"
            return
        fi
        printf '[]'
        return
    fi

    # shuffle and take 4
    local -a picked=()
    while ((${#picked[@]} < 4 && ${#arr[@]} > 0)); do
        local -i idx=$((RANDOM % ${#arr[@]}))
        picked+=("${arr[idx]}")
        # remove arr[idx]
        arr=("${arr[@]:0:idx}" "${arr[@]:idx+1}")
    done

    # emit JSON array
    printf '['
    local sep=""
    local i
    for i in "${picked[@]}"; do
        printf '%s"%s"' "${sep}" "${i}"
        sep=","
    done
    printf ']'
}

# encounter_roll_ability_legal <variety> [level]
# Roll an ability from the variety's Showdown-legal set, honoring
# POKIDLE_HIDDEN_ABILITY_RATE. Prints {"name","is_hidden"} with name as a slug.
# Falls back to the PokeAPI roller when Showdown data is unavailable.
function encounter_roll_ability_legal {
    local variety="$1"
    local lines
    if ! lines="$(showdown_legal_abilities "${variety}")"; then
        encounter_roll_ability "${variety}"
        return
    fi
    local -a normal=() hidden=()
    local slug hid
    while IFS=$'\t' read -r slug hid; do
        [[ -z "${slug}" ]] && continue
        if [[ "${hid}" == "1" ]]; then
            hidden+=("${slug}")
        else
            normal+=("${slug}")
        fi
    done <<<"${lines}"

    local -i rate="${POKIDLE_HIDDEN_ABILITY_RATE:-5}"
    local -i roll=$((RANDOM % 100))
    local name="" is_hidden="false"
    if ((roll < rate)) && ((${#hidden[@]} > 0)); then
        name="${hidden[$((RANDOM % ${#hidden[@]}))]}"
        is_hidden="true"
    elif ((${#normal[@]} > 0)); then
        name="${normal[$((RANDOM % ${#normal[@]}))]}"
    elif ((${#hidden[@]} > 0)); then
        name="${hidden[$((RANDOM % ${#hidden[@]}))]}"
        is_hidden="true"
    else
        encounter_roll_ability "${variety}"
        return
    fi
    jq -nc --arg n "${name}" --argjson h "${is_hidden}" '{name: $n, is_hidden: $h}'
}

# encounter_roll_moves_legal <variety> <level> [fallback]
# Roll up to 4 moves from the variety's Showdown-legal pool. Prints a JSON
# array of slugs. Falls back to the PokeAPI roller when Showdown data is
# unavailable. <level> is accepted for signature parity; the Showdown pool is
# not level-gated.
function encounter_roll_moves_legal {
    local variety="$1"
    local level="$2"
    local fallback="${3:-}"
    local pool
    if ! pool="$(showdown_legal_moves "${variety}")"; then
        encounter_roll_moves "${variety}" "${level}" "${fallback}"
        return
    fi
    local -a arr=()
    local m
    while IFS= read -r m; do
        [[ -n "${m}" ]] && arr+=("${m}")
    done <<<"${pool}"
    if ((${#arr[@]} == 0)); then
        encounter_roll_moves "${variety}" "${level}" "${fallback}"
        return
    fi
    local -a picked=()
    while ((${#picked[@]} < 4 && ${#arr[@]} > 0)); do
        local -i idx=$((RANDOM % ${#arr[@]}))
        picked+=("${arr[idx]}")
        arr=("${arr[@]:0:idx}" "${arr[@]:idx+1}")
    done
    printf '['
    local sep="" i
    for i in "${picked[@]}"; do
        printf '%s"%s"' "${sep}" "${i}"
        sep=","
    done
    printf ']'
}

# encounter_roll_gender <species>
# Print "F", "M", or "genderless" based on the species' gender_rate.
function encounter_roll_gender {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}")"; then
        return 1
    fi
    local gr
    gr="$(jq -r '.gender_rate' <<<"${spec}")"
    if [[ "${gr}" == "-1" ]]; then
        printf 'genderless'
        return
    fi
    # gr = female chance / 8. Roll 0..7.
    local -i roll=$((RANDOM % 8))
    if ((roll < gr)); then
        printf 'F'
    else
        printf 'M'
    fi
}

# encounter_roll_shiny
# Print "1" with probability 1/POKIDLE_SHINY_RATE (default 1024), else "0".
function encounter_roll_shiny {
    local -i rate="${POKIDLE_SHINY_RATE:-1024}"
    local -i roll=$((RANDOM * 32768 + RANDOM))
    if ((roll % rate == 0)); then
        printf '1'
    else
        printf '0'
    fi
}

# encounter_roll_held_berry <biome_id>
# Print a berry name with probability POKIDLE_BERRY_RATE% (default 15), else
# "null". Also "null" if the biome has no berries.
function encounter_roll_held_berry {
    local biome_id="$1"
    local -i rate="${POKIDLE_BERRY_RATE:-15}"
    local -i roll=$((RANDOM % 100))
    if ((roll >= rate)); then
        printf 'null'
        return
    fi
    local p
    p="$(encounter_pool_path "${biome_id}")"
    if [[ ! -f "${p}" ]]; then
        printf 'null'
        return
    fi
    local -a berries
    mapfile -t berries < <(jq -r '.berries[]?' "${p}")
    local -i n="${#berries[@]}"
    if ((n == 0)); then
        printf 'null'
        return
    fi
    local -i idx=$((RANDOM % n))
    printf '%s' "${berries[idx]}"
}

# encounter_species_for_name <name>
# Resolve a name (a bare species OR a variety-suffixed Pokemon name like
# shaymin-land/wormadam-plant/deoxys-attack) to its bare species name. Try
# /pokemon-species/<name>; on 404 fall back to /pokemon/<name>.species.name.
# Empty on total failure.
function encounter_species_for_name {
    local name="$1"
    if pokeapi_get "pokemon-species/${name}" >/dev/null 2>&1; then
        printf '%s' "${name}"
        return 0
    fi
    local poke
    if ! poke="$(pokeapi_get "pokemon/${name}" 2>/dev/null)"; then
        return 1
    fi
    jq -r '.species.name // empty' <<<"${poke}"
}

# encounter_pick_variety <species>
# Print a random variety name from /pokemon-species/<sp>.varieties[]. Falls
# back to <sp> if the species lookup fails or the varieties array is empty.
# _encounter_variety_is_non_wild <variety-name>
# True (exit 0) if the name is a form that is never found in the wild and so
# must not be rolled or pooled as an encounter variety:
#   - battle-only transformations: Mega, Primal, Gigantamax, Eternamax
#   - Totem bosses
#   - one-off event transforms PokeAPI leaves without an is_battle_only flag
#     (Ash-Greninja's battle-bond, Bloodmoon Ursaluna)
#   - cosmetic event-distribution forms (Pikachu's caps, cosplay outfits, and
#     the Let's-Go starter Pikachu/Eevee) — same stats as the base form, only
#     ever handed out at events
# Regional/cosmetic-but-wild formes (alola, galar, hisui, midnight, …) are
# legitimate and return false. The authoritative is_battle_only flag (see
# _encounter_form_is_battle_only) covers the battle/stance forms whose names
# don't betray them (mega-z, aegislash-blade, …).
function _encounter_variety_is_non_wild {
    case "$1" in
        *-mega | *-mega-x | *-mega-y | *-primal | *-gmax | *-eternamax) return 0 ;;
        *-totem | *-totem-*) return 0 ;;
        *-battle-bond | *-bloodmoon) return 0 ;;
        *-cap | *-cosplay | *-starter) return 0 ;;
        *-rock-star | *-belle | *-pop-star | *-phd | *-libre) return 0 ;;
        *) return 1 ;;
    esac
}

# _encounter_form_is_battle_only <variety-name>
# True (exit 0) if PokeAPI's /pokemon-form/<name> marks the form is_battle_only.
# This is the authoritative catch the name-suffix check above cannot give —
# e.g. mega-z forms (absol-mega-z) and stance/transform forms (aegislash-blade,
# morpeko-hangry, mimikyu-busted). A missing form (404) or absent flag means the
# form is wild-encounterable, so return 1.
function _encounter_form_is_battle_only {
    local form
    if ! form="$(pokeapi_get "pokemon-form/$1" 2>/dev/null)"; then
        return 1
    fi
    [[ "$(jq -r '.is_battle_only // false' <<<"${form}")" == "true" ]]
}

function encounter_pick_variety {
    local sp="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${sp}" 2>/dev/null)"; then
        printf '%s' "${sp}"
        return
    fi
    # Gather every variety, dropping non-wild forms (mega/gmax/totem/cosmetic/…).
    local -a varieties=()
    local v
    while IFS= read -r v; do
        if [[ -z "${v}" || "${v}" == "null" ]]; then
            continue
        fi
        if _encounter_variety_is_non_wild "${v}"; then
            continue
        fi
        varieties+=("${v}")
    done < <(jq -r '(.varieties // [])[].pokemon.name // empty' <<<"${spec}")
    local -i n="${#varieties[@]}"
    if ((n == 0)); then
        printf '%s' "${sp}"
        return
    fi
    printf '%s' "${varieties[$((RANDOM % n))]}"
}

# encounter_walk_chain <chain_json>
# Print a JSON array of {species, stage_idx, min_level_evo (nullable)}.
# stage_idx 0 for root; root has no min_level_evo.
function encounter_walk_chain {
    local chain_json="$1"
    jq -c '
        def walk($node; $stage):
            ($node.evolution_details[0].min_level // null) as $ml |
            { species: $node.species.name, stage_idx: $stage, min_level_evo: $ml },
            ($node.evolves_to[]? | walk(.; $stage + 1));
        [walk(.chain; 0)]
    ' <<<"${chain_json}"
}

# encounter_build_pool <biome_id>
# Print {tiers:{common:[],uncommon:[],rare:[],very_rare:[]}, berries:[...]}.
# Pool = direct union of /type/<t> for each biome.types[]; legendaries/mythicals
# dropped; each species tiered by its own capture_rate. min/max levels come from
# the species' own evolution_details.min_level (root → 5-15; non-level evos like
# stones → 5+15*stage_idx). Each entry also carries varieties[]: the specific
# forms that reached the pool via the biome's types (e.g. meowth-galar in a
# steel biome), so the roller encounters a type-coherent form. Returns 1 on
# fetch failure.
function encounter_build_pool {
    local biome_id="$1"
    if ! command -v biome_types_for >/dev/null; then
        # shellcheck disable=SC1091,SC2154  # POKIDLE_REPO_ROOT exported by the pokidle entrypoint
        source "${POKIDLE_REPO_ROOT}/lib/biome.bash"
    fi

    # Union pokemon-resource names across biome.types[].
    local raw_names='[]'
    local types_list
    if ! types_list="$(biome_types_for "${biome_id}")"; then
        return 1
    fi
    local t
    while IFS= read -r t; do
        if [[ -z "${t}" ]]; then
            continue
        fi
        local type_body
        if ! type_body="$(pokeapi_get "type/${t}")"; then
            return 1
        fi
        raw_names="$(jq -c --argjson e "$(jq -c '[.pokemon[].pokemon.name]' <<<"${type_body}")" \
            '. + $e | unique' <<<"${raw_names}")"
    done <<<"${types_list}"

    # /type/<t> returns variety-suffixed names (e.g. wormadam-plant,
    # shaymin-land, deoxys-attack) for forme-bearing species, alongside
    # bare names. Collapse each to its bare pokemon-species name (so the
    # /pokemon-species lookups below succeed), but remember which form(s)
    # reached the pool — that is the form actually present in this biome's
    # types (e.g. a steel biome holds meowth-galar, not bare meowth). The
    # bare name keys species-level data; the variety drives the encounter.
    # Battle-only/totem forms (mega, gmax, …) carry a biome type but are
    # never wild-encounterable, so they are dropped here; a species whose
    # only type-matching form is battle-only thus never enters the pool.
    local species_to_varieties='{}'
    local raw_name
    while IFS= read -r raw_name; do
        if [[ -z "${raw_name}" ]]; then
            continue
        fi
        if _encounter_variety_is_non_wild "${raw_name}"; then
            continue
        fi
        # Forms whose name doesn't betray them (mega-z, aegislash-blade, …) are
        # caught by the authoritative is_battle_only flag. Only hyphenated names
        # can be non-base forms, so bare species skip the extra fetch.
        if [[ "${raw_name}" == *-* ]] && _encounter_form_is_battle_only "${raw_name}"; then
            continue
        fi
        local bare
        if ! bare="$(encounter_species_for_name "${raw_name}" 2>/dev/null)"; then
            continue
        fi
        if [[ -z "${bare}" ]]; then
            continue
        fi
        species_to_varieties="$(jq -c --arg s "${bare}" --arg v "${raw_name}" \
            '.[$s] = ((.[$s] // []) + [$v] | unique)' <<<"${species_to_varieties}")"
    done < <(jq -r '.[]' <<<"${raw_names}")
    local species_union
    species_union="$(jq -c 'keys' <<<"${species_to_varieties}")"

    # Per species: filter legendary/mythical, tier by own capture_rate,
    # look up min/max via evolution chain (chain JSON cached by id).
    local -A chain_cache=()
    local flat='[]'
    local legendaries='[]'
    local sp
    while IFS= read -r sp; do
        if [[ -z "${sp}" ]]; then
            continue
        fi
        local spec
        if ! spec="$(pokeapi_get "pokemon-species/${sp}" 2>/dev/null)"; then
            continue
        fi
        # One read pulls the legendary/mythical flags, capture rate, and chain
        # URL from the species JSON instead of four separate jq scans.
        local US=$'\037'
        local is_leg is_myth cr chain_url
        IFS="${US}" read -r is_leg is_myth cr chain_url < <(jq -r --arg US "${US}" \
            '[(.is_legendary // false), (.is_mythical // false),
              (.capture_rate // 45), (.evolution_chain.url // "")
             ] | map(tostring) | join($US)' <<<"${spec}")
        if [[ "${is_leg}" == "true" || "${is_myth}" == "true" ]]; then
            local leg_varieties
            leg_varieties="$(jq -c --arg sp "${sp}" '.[$sp] // [$sp]' <<<"${species_to_varieties}")"
            legendaries="$(jq -c --arg sp "${sp}" --argjson vs "${leg_varieties}" \
                '. + [{species:$sp, varieties:$vs}]' <<<"${legendaries}")"
            continue
        fi

        local tier
        tier="$(encounter_tier_for_capture_rate "${cr}")"

        local emin="${POKIDLE_ENCOUNTER_LEVEL_MIN:-5}"
        local emax="${POKIDLE_ENCOUNTER_LEVEL_MAX:-15}"
        if [[ -n "${chain_url}" && "${chain_url}" != "null" ]]; then
            local chain_id="${chain_url%/}"
            chain_id="${chain_id##*/}"
            local chain="${chain_cache[${chain_id}]:-}"
            if [[ -z "${chain}" ]]; then
                if ! chain="$(pokeapi_get "evolution-chain/${chain_id}" 2>/dev/null)"; then
                    chain=""
                fi
                if [[ -n "${chain}" ]]; then
                    chain_cache[${chain_id}]="${chain}"
                fi
            fi
            if [[ -n "${chain}" ]]; then
                local stages
                stages="$(encounter_walk_chain "${chain}")"
                local entry
                entry="$(jq -c --arg sp "${sp}" '.[] | select(.species==$sp)' <<<"${stages}")"
                if [[ -n "${entry}" ]]; then
                    local stage
                    stage="$(jq -r '.stage_idx' <<<"${entry}")"
                    local ml
                    ml="$(jq -r '.min_level_evo // empty' <<<"${entry}")"
                    if [[ -n "${ml}" && "${ml}" != "null" ]]; then
                        emin="${ml}"
                        emax=$((ml + 10))
                    elif ((stage > 0)); then
                        emin=$((5 + 15 * stage))
                        emax=$((emin + 10))
                    fi
                fi
            fi
        fi

        local varieties
        varieties="$(jq -c --arg sp "${sp}" '.[$sp] // [$sp]' <<<"${species_to_varieties}")"
        flat="$(jq -c --arg sp "${sp}" --argjson vs "${varieties}" --argjson mn "${emin}" --argjson mx "${emax}" --arg tier "${tier}" \
            '. + [{species:$sp, varieties:$vs, min:$mn, max:$mx, tier:$tier}]' <<<"${flat}")"
    done < <(jq -r '.[]' <<<"${species_union}")

    # Bucket into tier arrays.
    local tiered
    tiered="$(jq -c --argjson tiers '["common","uncommon","rare","very_rare"]' '
        ($tiers | map({(.) : []}) | add) as $empty
        | reduce .[] as $e ($empty;
            .[$e.tier] += [{species: $e.species, varieties: $e.varieties, min: $e.min, max: $e.max}]
          )
    ' <<<"${flat}")"

    # Derive berries by natural_gift_type intersection with biome.types.
    local berries_json='[]'
    local berry_list
    if ! berry_list="$(pokeapi_get "berry?limit=100")"; then
        return 1
    fi
    berry_list="$(jq -r '.results[].name' <<<"${berry_list}")"
    local types_array
    types_array="$(biome_types_for "${biome_id}" | jq -R . | jq -s -c .)"
    local berry
    while IFS= read -r berry; do
        if [[ -z "${berry}" ]]; then
            continue
        fi
        local bj
        if ! bj="$(pokeapi_get "berry/${berry}" 2>/dev/null)"; then
            continue
        fi
        local ngt
        ngt="$(jq -r '.natural_gift_type.name // ""' <<<"${bj}")"
        if [[ -z "${ngt}" ]]; then
            continue
        fi
        if printf '"%s"' "${ngt}" | jq -e --argjson types "${types_array}" '. as $t | $types | index($t) != null' >/dev/null; then
            berries_json="$(jq -c --arg b "${berry}" '. + [$b]' <<<"${berries_json}")"
        fi
    done <<<"${berry_list}"

    local items_json
    items_json="$(_encounter_typed_items_for_biome "${biome_id}" | jq -R . | jq -s -c .)"

    jq -c -n --argjson tiers "${tiered}" --argjson berries "${berries_json}" \
        --argjson items "${items_json}" --argjson legendaries "${legendaries}" \
        '{tiers: $tiers, berries: $berries, items: $items, legendaries: $legendaries}'
}

# encounter_pool_path <biome>
# Print the cache file path for a biome's pool.
function encounter_pool_path {
    local biome="$1"
    printf '%s/pools/%s.json' "${POKIDLE_CACHE_DIR:-${HOME}/.cache/pokidle}" "${biome}"
}

# encounter_pool_save <biome> <body_json>
# Write a pool file for biome from the build_pool output. Pools are shipped
# with the repo and regenerated wholesale (scripts/build-shipped-pools.bash), so
# there is no on-disk version: the shipped pools always match the current code.
function encounter_pool_save {
    local biome="$1"
    local body_json="$2"
    local p
    p="$(encounter_pool_path "${biome}")"
    mkdir -p -- "${p%/*}"
    local body
    body="$(jq -c -n --arg b "${biome}" --arg ts "$(date -u +%FT%TZ)" \
        --argjson p "${body_json}" '{
        biome: $b,
        built_at: $ts,
        tiers: $p.tiers,
        berries: ($p.berries // []),
        items: ($p.items // []),
        legendaries: ($p.legendaries // [])
    }')"
    printf '%s' "${body}" >"${p}"
}

# encounter_pool_load <biome>
# Print the cached pool JSON for biome; return 1 if no pool exists.
function encounter_pool_load {
    local biome="$1"
    local p
    p="$(encounter_pool_path "${biome}")"
    if [[ ! -f "${p}" ]]; then
        printf 'encounter_pool_load: no pool for %s\n' "${biome}" >&2
        return 1
    fi
    cat "${p}"
}

# encounter_roll_pool_entry <pool_json>
# Roll a pool entry from a pool {tiers:{...}}. Pick a tier by fixed
# weights, walk forward to the next non-empty tier on an empty bucket, then pick
# uniformly inside. Returns 1 if every tier is empty.
function encounter_roll_pool_entry {
    local pool="$1"
    local -i roll=$((RANDOM % 100))
    local -i cum=0
    local -i tier_idx=0
    local -i i
    for i in 0 1 2 3; do
        cum=$((cum + ENCOUNTER_TIER_ROLL_WEIGHT[i]))
        if ((roll < cum)); then
            tier_idx=${i}
            break
        fi
    done
    local -i step
    local name
    local -i n
    local -i arr_idx
    for step in 0 1 2 3; do
        name="${ENCOUNTER_TIERS[$(((tier_idx + step) % 4))]}"
        n="$(jq --arg t "${name}" '.tiers[$t] | length' <<<"${pool}")"
        if ((n > 0)); then
            arr_idx=$((RANDOM % n))
            jq -c --arg t "${name}" --argjson i "${arr_idx}" '.tiers[$t][$i]' <<<"${pool}"
            return 0
        fi
    done
    printf 'encounter_roll_pool_entry: pool has no entries in any tier\n' >&2
    return 1
}

# encounter_roll_pokemon <entry_json> <biome_id>
# Print a JSON encounter object ready for db_insert_encounter (after adding
# session_id, encountered_at, sprite_path). Returns 1 if any roll step fails.
function encounter_roll_pokemon {
    local entry="$1"
    local biome="$2"
    local sp
    sp="$(jq -r '.species' <<<"${entry}")"
    local lo
    lo="$(jq -r '.min' <<<"${entry}")"
    local hi
    hi="$(jq -r '.max' <<<"${entry}")"

    # Pick the encountered form. Every pool entry carries a non-empty
    # varieties[]: the forms that reached this biome via its types (so a steel
    # biome yields meowth-galar, never bare Normal meowth). Roll uniformly among
    # them. /pokemon and ability/move fetches use the variety; the encounter's
    # species field stays bare.
    local -a vlist=()
    mapfile -t vlist < <(jq -r '.varieties[]' <<<"${entry}")
    local variety="${vlist[$((RANDOM % ${#vlist[@]}))]}"

    local poke
    if ! poke="$(pokeapi_get "pokemon/${variety}")"; then
        return 1
    fi
    local dex_id
    dex_id="$(jq -r '.id' <<<"${poke}")"
    local sprite_url
    sprite_url="$(jq -r '.sprites.front_default // ""' <<<"${poke}")"
    local sprite_url_shiny
    sprite_url_shiny="$(jq -r '.sprites.front_shiny // ""' <<<"${poke}")"

    local level
    level="$(encounter_roll_level "${lo}" "${hi}")"

    local ivs
    ivs="$(encounter_roll_ivs)"
    local evs
    evs="$(encounter_roll_evs)"

    local -a natures
    mapfile -t natures < <(encounter_natures_list)
    local -i nat_count="${#natures[@]}"
    local nature="${natures[$((RANDOM % nat_count))]}"
    local mods
    if ! mods="$(encounter_nature_mods "${nature}")"; then
        return 1
    fi

    local ability_obj
    if ! ability_obj="$(encounter_roll_ability_legal "${variety}")"; then
        return 1
    fi
    local ability
    ability="$(jq -r '.name' <<<"${ability_obj}")"
    local is_hidden
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<<"${ability_obj}")"

    local moves_json
    if ! moves_json="$(encounter_roll_moves_legal "${variety}" "${level}" "${sp}")"; then
        return 1
    fi

    local gender
    if ! gender="$(encounter_roll_gender "${sp}")"; then
        return 1
    fi
    local shiny
    shiny="$(encounter_roll_shiny)"
    local held_berry
    if ! held_berry="$(encounter_roll_held_berry "${biome}")"; then
        return 1
    fi

    local base_stats
    base_stats="$(jq -c '.stats' <<<"${poke}")"
    local stats
    if ! stats="$(encounter_compute_all_stats "${base_stats}" "${ivs}" "${evs}" "${level}" "${mods}")"; then
        return 1
    fi

    local final_sprite="${sprite_url}"
    if [[ "${shiny}" == "1" && -n "${sprite_url_shiny}" ]]; then
        final_sprite="${sprite_url_shiny}"
    fi

    local friendship
    if ! friendship="$(encounter_roll_friendship "${sp}")"; then
        return 1
    fi

    local berry_arg
    if [[ "${held_berry}" == "null" ]]; then
        berry_arg="null"
    else
        berry_arg="\"${held_berry}\""
    fi

    local ivs_json
    ivs_json="$(_json_int_array "${ivs}")"
    local evs_json
    evs_json="$(_json_int_array "${evs}")"
    local stats_json
    stats_json="$(_json_int_array "${stats}")"

    jq -n \
        --arg sp "${sp}" --arg variety "${variety}" --argjson dex "${dex_id}" --argjson lvl "${level}" \
        --arg nature "${nature}" --arg ability "${ability}" --argjson hidden "${is_hidden}" \
        --arg gender "${gender}" --argjson shiny "${shiny}" --argjson held "${berry_arg}" \
        --argjson friendship "${friendship}" \
        --argjson ivs "${ivs_json}" --argjson evs "${evs_json}" --argjson stats "${stats_json}" \
        --argjson moves "${moves_json}" --arg sprite "${final_sprite}" '{
            species: $sp, variety: $variety, dex_id: $dex, level: $lvl,
            nature: $nature, ability: $ability, is_hidden_ability: $hidden,
            gender: $gender, shiny: $shiny, held_berry: $held,
            friendship: $friendship,
            ivs: $ivs, evs: $evs, stats: $stats,
            moves: $moves, sprite_url: $sprite
        }'
}

# encounter_roll_friendship <species>
# Print the species' base_happiness from PokeAPI; 70 if missing.
function encounter_roll_friendship {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}")"; then
        return 1
    fi
    local val
    val="$(jq -r '.base_happiness // 70' <<<"${spec}")"
    if [[ "${val}" == "null" || -z "${val}" ]]; then
        val=70
    fi
    printf '%s' "${val}"
}

# _encounter_typed_items_for_biome <biome_id>
# Print the holdable typed-item slugs whose Showdown type is one of the biome's
# types (the biome's themeable item drops). Empty on missing data (fail-open).
function _encounter_typed_items_for_biome {
    local biome_id="$1"
    if ! command -v showdown_typed_holdable_items >/dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/showdown.bash" 2>/dev/null || return 0
    fi
    local types_csv
    types_csv="$(biome_types_for "${biome_id}" 2>/dev/null | paste -sd'|' -)"
    if [[ -z "${types_csv}" ]]; then
        return 0
    fi
    showdown_typed_holdable_items 2>/dev/null \
        | awk -F'\t' -v re="^(${types_csv})$" '$2 ~ re {print $1}'
}

# encounter_roll_pickup
# Roll a biome-agnostic pickup drop using rate-gated selection:
# with probability POKIDLE_EVOLUTION_ITEM_RATE% (default 15) pick from
# encounter_evolution_items; otherwise pick from showdown_typeless_holdable_items
# (falling back to evolution items if typeless holdable yields nothing).
# Prints {"item"}; returns 1 on an empty pool. The sprite is resolved later
# by the tick (via item_sprite), so the roll does no network fetch.
function encounter_roll_pickup {
    if ! command -v showdown_typeless_holdable_items >/dev/null; then
        # shellcheck disable=SC1091
        source "${POKIDLE_REPO_ROOT}/lib/showdown.bash" 2>/dev/null || return 1
    fi
    local -i evo_rate="${POKIDLE_EVOLUTION_ITEM_RATE:-15}"
    local -a pool=()
    if ((RANDOM % 100 < evo_rate)); then
        mapfile -t pool < <(encounter_evolution_items)
    fi
    if ((${#pool[@]} == 0)); then
        mapfile -t pool < <(showdown_typeless_holdable_items)
    fi
    if ((${#pool[@]} == 0)); then
        mapfile -t pool < <(encounter_evolution_items)
    fi
    local -i n="${#pool[@]}"
    if ((n == 0)); then
        printf 'encounter_roll_pickup: no item sources available\n' >&2
        return 1
    fi
    local name="${pool[$((RANDOM % n))]}"
    jq -n --arg item "${name}" '{item: $item}'
}

# encounter_roll_item <biome_id>
# Roll a biome item drop from the pool file's typed items + berries. Prints
# {"item"}; returns 1 on an empty pool. The sprite is resolved later by the
# tick (via item_sprite), so the roll does no network fetch.
function encounter_roll_item {
    local biome_id="$1"
    local pool
    if ! pool="$(encounter_pool_load "${biome_id}" 2>/dev/null)"; then
        return 1
    fi
    local -a candidates=()
    mapfile -t candidates < <(jq -r '(.items // [])[], (.berries // [])[]' <<<"${pool}")
    local -i n="${#candidates[@]}"
    if ((n == 0)); then
        printf 'encounter_roll_item: empty item pool for biome %s\n' "${biome_id}" >&2
        return 1
    fi
    local name="${candidates[$((RANDOM % n))]}"
    jq -n --arg item "${name}" '{item: $item}'
}
