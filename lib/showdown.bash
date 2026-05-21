#!/usr/bin/env bash
# lib/showdown.bash — Pokémon Showdown set text formatter.

_sd_titlecase_words() {
    local s="${1//-/ }"
    local out=""
    local w
    for w in $s; do
        out+="${w^} "
    done
    printf '%s' "${out% }"
}

_sd_stat_label() {
    case "$1" in
        0) echo HP ;;  1) echo Atk ;;  2) echo Def ;;
        3) echo SpA ;; 4) echo SpD ;;  5) echo Spe ;;
    esac
}

showdown_format() {
    local enc="$1"
    local species nature ability level shiny held item
    species="$(jq -r '.species' <<< "$enc")"
    nature="$(jq -r '.nature' <<< "$enc")"
    ability="$(jq -r '.ability' <<< "$enc")"
    level="$(jq -r '.level' <<< "$enc")"
    shiny="$(jq -r '.shiny' <<< "$enc")"
    held="$(jq -r '.held_berry // ""' <<< "$enc")"
    item="$(jq -r '.held_item // ""' <<< "$enc")"

    local sp_t ab_t nat_t
    sp_t="$(_sd_titlecase_words "$species")"
    ab_t="$(_sd_titlecase_words "$ability")"
    nat_t="$(_sd_titlecase_words "$nature")"

    # held_item is a full item slug (e.g. leftovers, choice-band, occa-berry)
    # rendered as-is; held_berry is a bare berry name needing the "Berry" word.
    if [[ -n "$item" && "$item" != "null" ]]; then
        printf '%s @ %s\n' "$sp_t" "$(_sd_titlecase_words "$item")"
    elif [[ -n "$held" && "$held" != "null" ]]; then
        local berry_t
        berry_t="$(_sd_titlecase_words "$held")"
        printf '%s @ %s Berry\n' "$sp_t" "$berry_t"
    else
        printf '%s\n' "$sp_t"
    fi
    printf 'Ability: %s\n' "$ab_t"
    printf 'Level: %s\n' "$level"
    [[ "$shiny" == "1" ]] && printf 'Shiny: Yes\n'
    printf '%s Nature\n' "$nat_t"

    local evs_line=""
    local i v sep=""
    for i in {0..5}; do
        v="$(jq -r ".evs[$i]" <<< "$enc")"
        if [[ "$v" != "0" ]]; then
            evs_line+="${sep}${v} $(_sd_stat_label "$i")"
            sep=" / "
        fi
    done
    [[ -n "$evs_line" ]] && printf 'EVs: %s\n' "$evs_line"

    local ivs_line=""
    sep=""
    for i in {0..5}; do
        v="$(jq -r ".ivs[$i]" <<< "$enc")"
        ivs_line+="${sep}${v} $(_sd_stat_label "$i")"
        sep=" / "
    done
    printf 'IVs: %s\n' "$ivs_line"

    local mv
    while IFS= read -r mv; do
        [[ -z "$mv" ]] && continue
        printf -- '- %s\n' "$(_sd_titlecase_words "$mv")"
    done < <(jq -r '.moves[]' <<< "$enc")
}
