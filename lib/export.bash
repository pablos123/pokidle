#!/usr/bin/env bash
# Pokémon Showdown set text formatter.

# Dependencies: sourced once at load, guarded so standalone/test re-sourcing is
# a no-op. POKIDLE_REPO_ROOT is set by the entrypoint and by the tests.
# shellcheck source=lib/showdown.bash disable=SC2154
command -v showdown_species_name >/dev/null 2>&1 || source "${POKIDLE_REPO_ROOT}/lib/showdown.bash"

# _export_stat_label <index>
# Print the Showdown stat label (HP/Atk/Def/SpA/SpD/Spe) for index 0..5.
function _export_stat_label {
    # shellcheck disable=SC2249  # index is always 0..5 from the caller's loop
    case "$1" in
        0) printf '%s' HP ;;
        1) printf '%s' Atk ;;
        2) printf '%s' Def ;;
        3) printf '%s' SpA ;;
        4) printf '%s' SpD ;;
        5) printf '%s' Spe ;;
    esac
}

# export_species_name <slug>
# Map a PokeAPI species/variety slug to its Pokémon Showdown species name, the
# authoritative source (handles spaces, punctuation, lowercase tails: Great Tusk,
# Mr. Mime, Kommo-o, …). Returns non-zero (printing nothing) when Showdown can't
# resolve a name — a guessed name would make the Showdown import fail silently,
# so the caller must fail controllably instead.
function export_species_name {
    local slug="$1"
    local name
    if ! name="$(showdown_species_name "${slug}")"; then
        printf 'export_species_name: no Showdown name for %s\n' "${slug}" >&2
        return 1
    fi
    printf '%s' "${name}"
}

# export_format <encounter_json>
# Print a Pokémon Showdown set block for the encounter JSON.
function export_format {
    local enc="$1"
    # One jq pass pulls every field (scalars, EV/IV arrays joined by space,
    # moves joined by comma — move slugs never contain commas) into a
    # US-delimited record; no per-field forks. Titlecasing and stat labels stay
    # in bash (pure, no exec). US (\x1f) is non-whitespace so read keeps empty
    # fields (e.g. a blank held item).
    local US=$'\037'
    local species nature ability level shiny held item evs_raw ivs_raw moves_raw
    IFS="${US}" read -r species nature ability level shiny held item \
        evs_raw ivs_raw moves_raw < <(jq -r --arg US "${US}" '[
            .species, .nature, .ability, (.level | tostring), (.shiny | tostring),
            (.held_berry // ""), (.held_item // ""),
            (.evs | map(tostring) | join(" ")),
            (.ivs | map(tostring) | join(" ")),
            (.moves | join(","))
        ] | join($US)' <<<"${enc}")

    local sp_t
    if ! sp_t="$(export_species_name "${species}")"; then
        return 1
    fi
    local ab_t
    ab_t="$(titlecase_words "${ability}")"
    local nat_t
    nat_t="$(titlecase_words "${nature}")"

    # held_item is a full item slug (e.g. leftovers, choice-band, occa-berry)
    # rendered as-is; held_berry is a bare berry name needing the "Berry" word.
    if [[ -n "${item}" && "${item}" != "null" ]]; then
        printf '%s @ %s\n' "${sp_t}" "$(titlecase_words "${item}")"
    elif [[ -n "${held}" && "${held}" != "null" ]]; then
        local berry_t
        berry_t="$(titlecase_words "${held}")"
        printf '%s @ %s Berry\n' "${sp_t}" "${berry_t}"
    else
        printf '%s\n' "${sp_t}"
    fi
    printf 'Ability: %s\n' "${ab_t}"
    printf 'Level: %s\n' "${level}"
    if [[ "${shiny}" == "1" ]]; then
        printf 'Shiny: Yes\n'
    fi
    printf '%s Nature\n' "${nat_t}"

    local -a evs ivs
    read -ra evs <<<"${evs_raw}"
    read -ra ivs <<<"${ivs_raw}"

    local evs_line=""
    local sep=""
    local -i i
    for i in {0..5}; do
        if [[ "${evs[i]}" != "0" ]]; then
            evs_line+="${sep}${evs[i]} $(_export_stat_label "${i}")"
            sep=" / "
        fi
    done
    if [[ -n "${evs_line}" ]]; then
        printf 'EVs: %s\n' "${evs_line}"
    fi

    local ivs_line=""
    sep=""
    for i in {0..5}; do
        ivs_line+="${sep}${ivs[i]} $(_export_stat_label "${i}")"
        sep=" / "
    done
    printf 'IVs: %s\n' "${ivs_line}"

    local -a moves
    IFS=',' read -ra moves <<<"${moves_raw}"
    local mv
    for mv in "${moves[@]}"; do
        if [[ -z "${mv}" ]]; then
            continue
        fi
        printf -- '- %s\n' "$(titlecase_words "${mv}")"
    done
}
