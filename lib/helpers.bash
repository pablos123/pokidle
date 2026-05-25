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
