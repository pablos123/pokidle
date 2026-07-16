# bash completion for the pokidle CLI.
#
# Sourced into an interactive shell, so no `set -Eeuo pipefail` (it would leak
# into the user's session).
#
# Install (per user): source this file from ~/.bashrc, e.g.
#   source /path/to/pokidle/share/completions/pokidle.bash
# System-wide: symlink into your bash-completion completions dir.

# _pokidle_biome_ids
# Print every biome id, one per line. Lazily sources lib/biome.bash (located
# next to this completion file) on the first tab so the constants don't load
# until the user actually completes a biome arg. Silent (and empty) if the
# lib is missing.
function _pokidle_biome_ids {
    if ! command -v biome_ids >/dev/null 2>&1; then
        local lib="${BASH_SOURCE[0]%/*}/../../lib/biome.bash"
        if [[ ! -f "${lib}" ]]; then
            return 0
        fi
        # shellcheck disable=SC1090
        source "${lib}"
    fi
    biome_ids
}

# _pokidle
# Programmable completion for the pokidle CLI.
function _pokidle {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmd="${COMP_WORDS[1]:-}"

    local commands="daemon tick encounters export items log stats current rebuild-pool \
switch-biome biomes clean setup uninstall help"

    # First positional arg: the subcommand.
    if ((COMP_CWORD == 1)); then
        mapfile -t COMPREPLY < <(compgen -W "${commands}" -- "${cur}")
        return 0
    fi

    case "${cmd}" in
        daemon)
            if ((COMP_CWORD == 2)); then
                mapfile -t COMPREPLY < <(compgen -W "\
run start stop restart status logs enable disable" -- "${cur}")
            fi
            ;;
        tick)
            local kinds="encounter item pickup level friendship evolve legendary"
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--no-dry-run --no-notify --no-images --no-output --json" -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "${kinds}" -- "${cur}")
            fi
            ;;
        encounters)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "\
--shiny --legendary --since --until --biome --species --nature --min-iv-total \
--max-iv-total --ability --gender --move --berry \
--min-level --max-level --limit --reverse --no-images --json" -- "${cur}")
            fi
            ;;
        export)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "\
--shiny --legendary --since --until --biome --species --nature --min-iv-total \
--max-iv-total --ability --gender --move --berry \
--min-level --max-level \
--force-level --force-perfect --force-mega --force-z \
--force-legendary --force-evolved --force-shiny --force-hidden --force-nature \
--force-best-ivs" -- "${cur}")
            fi
            ;;
        items)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "\
--since --until --biome --item --kind --limit --all --reverse --no-images --json" -- "${cur}")
            fi
            ;;
        stats)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "\
--shiny --since --until --biome --species --nature --min-iv-total \
--min-level --max-level --max-iv-total --ability --gender --move --berry \
--legendary --json" -- "${cur}")
            fi
            ;;
        current)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--no-images --json" -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "items berries encounters" -- "${cur}")
            fi
            ;;
        clean)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--yes" -- "${cur}")
            else
                mapfile -t COMPREPLY < <(compgen -W "pools db showdown pokeapi all" -- "${cur}")
            fi
            ;;
        switch-biome | rebuild-pool)
            if [[ "${cmd}" == rebuild-pool && "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--items --no-items --graphql --rest --yes" -- "${cur}")
            else
                local biomes
                biomes="$(_pokidle_biome_ids)"
                mapfile -t COMPREPLY < <(compgen -W "${biomes}" -- "${cur}")
            fi
            ;;
        biomes)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--json" -- "${cur}")
            fi
            ;;
        log)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--kind --limit --reverse --json" -- "${cur}")
            fi
            ;;
        setup)
            if [[ "${cur}" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--no-enable" -- "${cur}")
            fi
            ;;
        *) ;;
    esac
    return 0
}

complete -F _pokidle pokidle
