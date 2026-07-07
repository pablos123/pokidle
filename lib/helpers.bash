#!/usr/bin/env bash
# Shared helpers used across the entrypoints and libs. Pure functions only —
# no file-scope constants — so re-sourcing in tests is harmless.

# titlecase <word>
# Print word with its first letter capitalized.
function titlecase {
    printf '%s' "${1^}"
}

# titlecase_words <text>
# Print text with hyphens turned to spaces and each word capitalized.
function titlecase_words {
    local text="${1//-/ }"
    local -a words
    read -ra words <<<"${text}"
    local out=""
    local word
    for word in "${words[@]}"; do
        out+="${word^} "
    done
    printf '%s' "${out% }"
}

# species_display_name <slug>
# Human-friendly name for a Pokémon species/variety slug, for display surfaces
# (lists, ticks, notifications). Uses the canonical Showdown display name when it
# resolves (Meowth-Galar, Mr. Mime, Kommo-o), else a titlecased slug (offline, or
# the slug absent from Showdown data, or the showdown lib not loaded). Never
# blanks. Not for export — that path must fail hard on an unknown name.
function species_display_name {
    local slug="$1"
    local name
    if name="$(showdown_species_name "${slug}" 2>/dev/null)" && [[ -n "${name}" ]]; then
        printf '%s' "${name}"
        return
    fi
    titlecase_words "${slug}"
}

# _pokidle_usage_error <help_fn> <fmt> [args...]
# Print a one-line usage error to stderr, follow it with the command's full
# help on stderr, and return 2. <fmt> is a printf format without the trailing
# newline. Use it as a rejecting case arm's action, followed by a bare return
# so the 2 propagates out of the command function:
#   -*) _pokidle_usage_error pokidle_stats_help 'stats: unknown option %s' "$1"
#       return ;;
function _pokidle_usage_error {
    local help_fn="$1"
    local fmt="$2"
    shift 2
    # shellcheck disable=SC2059  # fmt is a caller-supplied printf template
    printf "${fmt}\n" "$@" >&2
    "${help_fn}" >&2
    return 2
}

# strip_slashes <path>
# Print path with one leading and one trailing slash removed.
function strip_slashes {
    local s="${1#/}"
    printf '%s' "${s%/}"
}

# atomic_write <path>
# Write stdin to path atomically: create the parent dir, stage in a temp file
# alongside it, then rename into place.
function atomic_write {
    local path="$1"
    local dir="${path%/*}"
    mkdir -p -- "${dir}"
    local tmp
    tmp="$(mktemp -- "${dir}/.tmp.XXXXXX")"
    cat >"${tmp}"
    mv -- "${tmp}" "${path}"
}
