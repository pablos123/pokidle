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
    sp_t="$(titlecase_words "${species}")"
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
