#!/usr/bin/env bash
# `pokidle encounters` — pretty list of recorded Pokémon encounters.

# pokidle_encounters_help
# Print the `pokidle encounters` subcommand help.
function pokidle_encounters_help {
    cat <<'EOF'
pokidle encounters — pretty list of Pokémon encounters.

Usage:
  pokidle encounters [options]

Options:
  --shiny            Only shinies
  --legendary        Only legendary/mythical catches
  --since DATE       Encounters at/after DATE (YYYY-MM-DD or any date(1) string)
  --until DATE       Encounters at/before DATE
  --biome ID         Filter by biome
  --species NAME     Substring match on species
  --nature NAME      Exact nature match
  --min-iv-total N   Min summed IVs
  --max-iv-total N   Max summed IVs
  --ability SLUG     Exact ability match
  --gender G         Exact gender match (M|F|genderless)
  --move SLUG        Exact move slug match (any move slot)
  --berry SLUG       Exact held-berry match
  --min-level N      Encounters at/above level N
  --max-level N      Encounters at/below level N
  --limit N          Cap rows (default: 50)
  --sort KEY         date|name|level (default: date)
  --reverse          Reverse the sort (default: ascending)
  --no-images        Skip inline sprite previews
  --json             Emit raw JSON
  -h, --help         Show this help
EOF
}

# pokidle_list [options...]
# Pretty-print pokemon encounters (or raw JSON with --json). Remaining args are
# db_list_encounters options.
function pokidle_list {
    db_init
    local -i json_mode=0
    local -i no_images=0
    local -a args=()
    while (($# > 0)); do
        case "$1" in
            --json)
                json_mode=1
                shift
                ;;
            --no-images)
                no_images=1
                shift
                ;;
            -h | --help | help)
                pokidle_encounters_help
                return 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    local rows rc=0
    local _db_list_errctx="encounters"
    rows="$(db_list_encounters "${args[@]}")" || rc=$?
    if ((rc != 0)); then
        # shellcheck disable=SC2154  # POKIDLE_RC_USAGE is defined in lib/db.bash
        ((rc == POKIDLE_RC_USAGE)) && {
            pokidle_encounters_help >&2
            return 2
        }
        return "${rc}"
    fi

    if ((json_mode)); then
        printf '%s\n' "${rows}"
        return
    fi

    local sep_char="${POKIDLE_SEPARATOR:--}"
    local sep_line
    printf -v sep_line '%*s' 80 ''
    sep_line="${sep_line// /${sep_char}}"

    # One jq pass extracts and formats every field (date via strflocaltime,
    # matching date -d; the displayed name is the encountered form, falling back
    # to the bare species when the variety column is NULL) into one US-delimited
    # line per row; the bash loop only renders sprites and prints. The unit
    # separator (\x1f, non-whitespace) keeps read from collapsing empty fields
    # such as a blank sprite path.
    local US=$'\037'
    local id ts_fmt biome lvl form shiny nat abil gender sprite stats ivs evs moves held
    local -i first=1
    while IFS="${US}" read -r id ts_fmt biome lvl form shiny nat abil gender sprite stats ivs evs moves held; do
        if ((first)); then
            first=0
        else
            printf -- '%s\n' "${sep_line}"
        fi
        if ((!no_images)); then
            if [[ -z "${sprite}" || ! -f "${sprite}" ]]; then
                sprite="$(_pokidle_pokemon_sprite "${form}" "${shiny}")"
                # Persist a freshly-resolved sprite so the row is permanently
                # repaired when the original fetch failed transiently. No-op when
                # still unresolved.
                if [[ -n "${sprite}" && -f "${sprite}" ]]; then
                    db_update_encounter_sprite "${id}" "${sprite}"
                fi
            fi
            _pokidle_render_sprite "${sprite}"
        fi
        _pokidle_render_encounter_row "${ts_fmt}" "${biome}" "${lvl}" "${form}" "${shiny}" \
            "${nat}" "${abil}" "${gender}" "${stats}" "${ivs}" "${evs}" "${moves}" "${held}"
        printf '\n'
    done < <(jq -r --arg US "${US}" '.[] | [
        .id,
        (.encountered_at | strflocaltime("%F %H:%M")),
        .biome_id, .level, (.variety // .species), .shiny, .nature, .ability, .gender,
        (.sprite_path // ""),
        "\(.stat_hp)/\(.stat_atk)/\(.stat_def)/\(.stat_spa)/\(.stat_spd)/\(.stat_spe)",
        "\(.iv_hp)/\(.iv_atk)/\(.iv_def)/\(.iv_spa)/\(.iv_spd)/\(.iv_spe)",
        "\(.ev_hp)/\(.ev_atk)/\(.ev_def)/\(.ev_spa)/\(.ev_spd)/\(.ev_spe)",
        (.moves_json | fromjson | join(", ")),
        (.held_berry // "")
    ] | map(tostring) | join($US)' <<<"${rows}")
}
