# bash completion for the pokidle and pokeapi CLIs.
#
# Install (per user): source this file from ~/.bashrc, e.g.
#   source /path/to/pokidle/share/completions/pokidle.bash
# System-wide: symlink into your bash-completion completions dir.

# _pokidle_biome_ids
# Print every biome id, one per line. Resolves biomes.json the same way the
# pokidle CLI does: POKIDLE_CONFIG_DIR, then XDG config, then the repo config
# next to this completion file. Silent (and empty) if none is found.
_pokidle_biome_ids() {
    local f
    for f in \
        "${POKIDLE_CONFIG_DIR:-}/biomes.json" \
        "${XDG_CONFIG_HOME:-${HOME}/.config}/pokidle/biomes.json" \
        "$(dirname -- "${BASH_SOURCE[0]}")/../../config/biomes.json"; do
        [[ -n "${f}" && -f "${f}" ]] || continue
        if command -v jq >/dev/null 2>&1; then
            jq -r '.biomes[].id' "${f}"
        else
            # Fallback: pull "id" values without jq.
            grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "${f}" |
                sed -E 's/.*"([^"]+)"$/\1/'
        fi
        return 0
    done
}

# _pokidle
# Programmable completion for the pokidle CLI.
_pokidle() {
    local cur cmd
    cur="${COMP_WORDS[COMP_CWORD]}"
    cmd="${COMP_WORDS[1]:-}"

    local commands="daemon tick encounters items stats current rebuild-pool \
switch-biome clean setup uninstall status help"

    # First positional arg: the subcommand.
    if ((COMP_CWORD == 1)); then
        mapfile -t COMPREPLY < <(compgen -W "${commands}" -- "${cur}")
        return 0
    fi

    case "${cmd}" in
        tick)
            local kinds="pokemon item level friendship evolve legendary"
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--no-dry-run --no-notify --json" -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "${kinds}" -- "${cur}")
            fi
            ;;
        encounters)
            mapfile -t COMPREPLY < <(compgen -W "\
--shiny --since --until --biome --species --nature --min-iv-total \
--limit --newest-first --json --export" -- "${cur}")
            ;;
        items)
            mapfile -t COMPREPLY < <(compgen -W "\
--since --until --biome --item --limit --all --newest-first --json" -- "${cur}")
            ;;
        clean)
            mapfile -t COMPREPLY < <(compgen -W "pools db all --yes" -- "${cur}")
            ;;
        switch-biome | rebuild-pool)
            local biomes
            biomes="$(_pokidle_biome_ids)"
            if [[ "${cmd}" == rebuild-pool && "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--yes" -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "${biomes}" -- "${cur}")
            fi
            ;;
        setup)
            mapfile -t COMPREPLY < <(compgen -W "--no-enable" -- "${cur}")
            ;;
    esac
    return 0
}

# _pokeapi
# Programmable completion for the pokeapi CLI.
_pokeapi() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"

    local commands="get pokemon move ability type species item nature \
natures stats types moves id name forms sprite-url sprite cache-path \
cache-clear help"

    # Only the subcommand is completed; resource names need the network/cache.
    if ((COMP_CWORD == 1)); then
        mapfile -t COMPREPLY < <(compgen -W "${commands}" -- "${cur}")
    fi
    return 0
}

complete -F _pokidle pokidle
complete -F _pokeapi pokeapi
