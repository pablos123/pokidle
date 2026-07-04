#!/usr/bin/env bash
# `pokidle biomes` — list the biome catalog.

# Dependency: the biome catalog globals (BIOME_IDS/LABELS/TYPES). Guarded so a
# standalone source resolves it; a no-op under the entrypoint (already loaded).
# shellcheck source=lib/biome.bash disable=SC2154
command -v biome_types_for >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/biome.bash"

# pokidle_biomes_help
# Print the `pokidle biomes` subcommand help.
function pokidle_biomes_help {
    cat <<'EOF'
pokidle biomes — list all 36 biomes (label + types) in catalog order.

Usage:
  pokidle biomes [--json]

Options:
  --json        Emit the catalog as a JSON array of {id, label, types}.
  -h, --help    Show this help
EOF
}

# pokidle_biomes [--json]
# List the full biome catalog (label + two types) in catalog order. Read-only:
# prints static data from lib/biome.bash, no DB or pool-cache access.
function pokidle_biomes {
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --json)
                emit_json=1
                shift
                ;;
            -h | --help | help)
                pokidle_biomes_help
                return 0
                ;;
            -*)
                printf 'biomes: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'biomes: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    local id
    if ((emit_json)); then
        local -a objs=()
        for id in "${BIOME_IDS[@]}"; do
            objs+=("$(jq -n --arg id "${id}" --arg label "${BIOME_LABELS[${id}]}" \
                --arg types "${BIOME_TYPES[${id}]}" \
                '{id: $id, label: $label, types: ($types | split(" "))}')")
        done
        printf '%s\n' "${objs[@]}" | jq -s '.'
        return 0
    fi

    for id in "${BIOME_IDS[@]}"; do
        printf '%-16s%s\n' "${BIOME_LABELS[${id}]}" "${BIOME_TYPES[${id}]// / \/ }"
    done
}
