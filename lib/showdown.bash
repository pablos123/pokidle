#!/usr/bin/env bash
# Pokémon Showdown set text formatter.

# _sd_stat_label <index>
# Print the Showdown stat label (HP/Atk/Def/SpA/SpD/Spe) for index 0..5.
function _sd_stat_label {
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

# showdown_species_name <slug>
# Map a PokeAPI species/variety slug to its Pokémon Showdown species name.
# Default: titlecase each hyphen-separated segment and rejoin with hyphens, so
# regional/forme suffixes survive intact (meowth-galar -> Meowth-Galar) — unlike
# titlecase_words, which would flatten the hyphen to a space. A handful of
# species carry irregular Showdown names (punctuation, spaces, a lowercase
# tail) and are mapped directly.
function showdown_species_name {
    local slug="$1"
    case "${slug}" in
        mr-mime) printf 'Mr. Mime'; return ;;
        mr-rime) printf 'Mr. Rime'; return ;;
        mime-jr) printf 'Mime Jr.'; return ;;
        type-null) printf 'Type: Null'; return ;;
        farfetchd) printf "Farfetch'd"; return ;;
        sirfetchd) printf "Sirfetch'd"; return ;;
        tapu-koko) printf 'Tapu Koko'; return ;;
        tapu-lele) printf 'Tapu Lele'; return ;;
        tapu-bulu) printf 'Tapu Bulu'; return ;;
        tapu-fini) printf 'Tapu Fini'; return ;;
        jangmo-o) printf 'Jangmo-o'; return ;;
        hakamo-o) printf 'Hakamo-o'; return ;;
        kommo-o) printf 'Kommo-o'; return ;;
    esac
    local -a segs
    IFS='-' read -ra segs <<<"${slug}"
    local out="" sep="" s
    for s in "${segs[@]}"; do
        out+="${sep}${s^}"
        sep="-"
    done
    printf '%s' "${out}"
}

# showdown_format <encounter_json>
# Print a Pokémon Showdown set block for the encounter JSON.
function showdown_format {
    local enc="$1"
    local species
    species="$(jq -r '.species' <<<"${enc}")"
    local nature
    nature="$(jq -r '.nature' <<<"${enc}")"
    local ability
    ability="$(jq -r '.ability' <<<"${enc}")"
    local level
    level="$(jq -r '.level' <<<"${enc}")"
    local shiny
    shiny="$(jq -r '.shiny' <<<"${enc}")"
    local held
    held="$(jq -r '.held_berry // ""' <<<"${enc}")"
    local item
    item="$(jq -r '.held_item // ""' <<<"${enc}")"

    local sp_t
    sp_t="$(showdown_species_name "${species}")"
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

    local evs_line=""
    local sep=""
    local -i i
    local v
    for i in {0..5}; do
        v="$(jq -r ".evs[${i}]" <<<"${enc}")"
        if [[ "${v}" != "0" ]]; then
            evs_line+="${sep}${v} $(_sd_stat_label "${i}")"
            sep=" / "
        fi
    done
    if [[ -n "${evs_line}" ]]; then
        printf 'EVs: %s\n' "${evs_line}"
    fi

    local ivs_line=""
    sep=""
    for i in {0..5}; do
        v="$(jq -r ".ivs[${i}]" <<<"${enc}")"
        ivs_line+="${sep}${v} $(_sd_stat_label "${i}")"
        sep=" / "
    done
    printf 'IVs: %s\n' "${ivs_line}"

    local mv
    while IFS= read -r mv; do
        if [[ -z "${mv}" ]]; then
            continue
        fi
        printf -- '- %s\n' "$(titlecase_words "${mv}")"
    done < <(jq -r '.moves[]' <<<"${enc}")
}
