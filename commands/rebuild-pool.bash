#!/usr/bin/env bash
# `pokidle rebuild-pool` — regenerate biome pools from the live PokeAPI.
# shellcheck disable=SC2154  # POKIDLE_*/showdown cache dirs come from the entrypoint + libs

# pokidle_rebuild_pool_help
# Print the `pokidle rebuild-pool` subcommand help.
function pokidle_rebuild_pool_help {
    cat <<'EOF'
pokidle rebuild-pool — regenerate biome encounter pools (type-derived, via
cached PokeAPI GraphQL queries).

Usage:
  pokidle rebuild-pool [biome] [--items] [--no-items] [--yes]

With a biome id, rebuild just that pool. With none, rebuild all (wiping the pool
cache first).

Options:
  --items       Build ONLY the holdable item / form-item artifacts, then stop.
  --no-items    Skip the item artifacts on a full rebuild.
  --graphql     Force the GraphQL data path (fail if the endpoint is down).
  --rest        Force the classic REST data path.
  --yes, -y     Skip the all-mode confirmation prompt.
  -h, --help    Show this help
EOF
}

# pokidle_rebuild_pool [biome] [--items] [--no-items] [--yes]
# Rebuild one biome's pool, or all of them (wiping the pool cache first; --yes
# skips the all-mode confirm). Pools are type-derived from the live PokeAPI.
# --items: build ONLY the holdable item artifact, then return (no biome loop).
# --no-items: skip the item artifact even on a full rebuild.
# Default full rebuild (no biome target) builds the artifact first, then pools.
function pokidle_rebuild_pool {
    local -i force=0
    local -i items_only=0
    local -i do_items=1
    local target=""
    local method=""
    while (($# > 0)); do
        case "$1" in
            --yes | -y)
                force=1
                shift
                ;;
            --items)
                items_only=1
                shift
                ;;
            --no-items)
                do_items=0
                shift
                ;;
            --graphql)
                method=graphql
                shift
                ;;
            --rest)
                method=rest
                shift
                ;;
            -h | --help | help)
                pokidle_rebuild_pool_help
                return 0
                ;;
            -*)
                _pokidle_usage_error pokidle_rebuild_pool_help 'rebuild-pool: unknown option %s' "$1"
                return
                ;;
            *)
                if [[ -n "${target}" ]]; then
                    _pokidle_usage_error pokidle_rebuild_pool_help 'rebuild-pool: unexpected argument %s (one biome at most)' "$1"
                    return
                fi
                target="$1"
                shift
                ;;
        esac
    done

    # A named target must be a real biome — fail fast rather than loop-and-warn.
    if [[ -n "${target}" ]] && ! biome_exists "${target}"; then
        printf 'rebuild-pool: unknown biome %s\n' "${target}" >&2
        return 2
    fi

    # full=1 when no biome target is given (i.e. a full rebuild of all pools).
    local -i full=0
    [[ -z "${target}" ]] && full=1

    # Build the Showdown artifacts (holdable items + form-item registry) when:
    # --items flag, or full rebuild without --no-items.
    if ((items_only || (do_items && full))); then
        if _showdown_build_holdable_meta >/dev/null; then
            printf 'rebuilt items artifact: %s\n' "${POKIDLE_SHOWDOWN_CACHE_DIR}/items-holdable.tsv"
        else
            printf 'rebuild-pool: item artifact build failed\n' >&2
        fi
        if _showdown_build_form_items_meta >/dev/null; then
            printf 'rebuilt form-item registry: %s\n' "${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
        else
            printf 'rebuild-pool: form-item registry build failed\n' >&2
        fi
    fi
    if ((items_only)); then
        return 0
    fi

    local biomes
    if [[ -n "${target}" ]]; then
        biomes="${target}"
    else
        biomes="$(biome_ids)"
        local -i n
        n="$(printf '%s\n' "${biomes}" | grep --count .)"
        if ((!force)); then
            printf 'Rebuild all %s pools (wipes %s/pools first)? [y/N] ' \
                "${n}" "${POKIDLE_CACHE_DIR}"
            local ans
            read -r ans
            if [[ ! "${ans}" =~ ^[Yy]$ ]]; then
                printf 'aborted\n'
                return 0
            fi
        fi
        rm -rf -- "${POKIDLE_CACHE_DIR}/pools"
    fi
    local b
    while IFS= read -r b; do
        if [[ -z "${b}" ]]; then
            continue
        fi
        local pool
        if ! pool="$(encounter_build_pool "${b}" "${method}")"; then
            printf 'rebuild-pool: build failed for %s\n' "${b}" >&2
            continue
        fi
        encounter_pool_save "${b}" "${pool}"
        local c
        c="$(jq '.tiers.common    | length' <<<"${pool}")"
        local u
        u="$(jq '.tiers.uncommon  | length' <<<"${pool}")"
        local r
        r="$(jq '.tiers.rare      | length' <<<"${pool}")"
        local v
        v="$(jq '.tiers.very_rare | length' <<<"${pool}")"
        printf 'rebuilt pool: %s (common=%s uncommon=%s rare=%s very_rare=%s)\n' \
            "${b}" "${c}" "${u}" "${r}" "${v}"
    done <<<"${biomes}"
}
