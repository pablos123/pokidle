#!/usr/bin/env bats

load helpers

setup() {
    # shellcheck disable=SC1090
    source "${LIB_DIR}/helpers.bash"
}

@test "titlecase: capitalizes first letter" {
    run titlecase "pikachu"
    [ "$status" -eq 0 ]
    [ "$output" = "Pikachu" ]
}

@test "titlecase_words: hyphens become spaces, each word capitalized" {
    run titlecase_words "leaf-blade"
    [ "$status" -eq 0 ]
    [ "$output" = "Leaf Blade" ]
}

@test "titlecase_words: multi-word input" {
    run titlecase_words "king-of-the-hill"
    [ "$output" = "King Of The Hill" ]
}

@test "species_display_name: falls back to titlecased slug when Showdown unavailable" {
    # showdown lib not sourced here, so showdown_species_name is undefined ->
    # the helper must degrade to a titlecased slug, never blank.
    run species_display_name "meowth-galar"
    [ "$status" -eq 0 ]
    [ "$output" = "Meowth Galar" ]
}

@test "strip_slashes: removes one leading and one trailing slash" {
    run strip_slashes "/pokemon/25/"
    [ "$output" = "pokemon/25" ]
}

@test "strip_slashes: leaves a bare key untouched" {
    run strip_slashes "pokemon/25"
    [ "$output" = "pokemon/25" ]
}

@test "atomic_write: writes stdin and creates parent dirs" {
    local target="${BATS_TMPDIR}/aw.$$/sub/file.txt"
    printf 'hello' | atomic_write "${target}"
    [ -f "${target}" ]
    [ "$(cat "${target}")" = "hello" ]
}

@test "atomic_write: leaves no temp files behind" {
    local target="${BATS_TMPDIR}/aw2.$$/file.txt"
    printf 'x' | atomic_write "${target}"
    run find "${BATS_TMPDIR}/aw2.$$" -name '.tmp.*'
    [ -z "$output" ]
}
