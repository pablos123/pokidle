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
        mr-mime)
            printf 'Mr. Mime'
            return
            ;;
        mr-rime)
            printf 'Mr. Rime'
            return
            ;;
        mime-jr)
            printf 'Mime Jr.'
            return
            ;;
        type-null)
            printf 'Type: Null'
            return
            ;;
        farfetchd)
            printf "Farfetch'd"
            return
            ;;
        sirfetchd)
            printf "Sirfetch'd"
            return
            ;;
        tapu-koko)
            printf 'Tapu Koko'
            return
            ;;
        tapu-lele)
            printf 'Tapu Lele'
            return
            ;;
        tapu-bulu)
            printf 'Tapu Bulu'
            return
            ;;
        tapu-fini)
            printf 'Tapu Fini'
            return
            ;;
        jangmo-o)
            printf 'Jangmo-o'
            return
            ;;
        hakamo-o)
            printf 'Hakamo-o'
            return
            ;;
        kommo-o)
            printf 'Kommo-o'
            return
            ;;
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
    # One jq pass pulls every field (scalars, EV/IV arrays joined by space,
    # moves joined by comma — move slugs never contain commas) into a
    # US-delimited record. Replaces the ~20 jq forks per mon (7 scalars + 6 EVs
    # + 6 IVs + 1 moves) that made `export` crawl. Titlecasing and stat labels
    # stay in bash (pure, no exec). US (\x1f) is non-whitespace so read keeps
    # empty fields (e.g. a blank held item).
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

    local -a evs ivs
    read -ra evs <<<"${evs_raw}"
    read -ra ivs <<<"${ivs_raw}"

    local evs_line=""
    local sep=""
    local -i i
    for i in {0..5}; do
        if [[ "${evs[i]}" != "0" ]]; then
            evs_line+="${sep}${evs[i]} $(_sd_stat_label "${i}")"
            sep=" / "
        fi
    done
    if [[ -n "${evs_line}" ]]; then
        printf 'EVs: %s\n' "${evs_line}"
    fi

    local ivs_line=""
    sep=""
    for i in {0..5}; do
        ivs_line+="${sep}${ivs[i]} $(_sd_stat_label "${i}")"
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
