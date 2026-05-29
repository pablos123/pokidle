#!/usr/bin/env bash
# notify-send + sound playback.

# _biome_icon_path <id>
# Print the biome icon path if the file exists; print nothing otherwise.
function _biome_icon_path {
    local id="$1"
    if [[ -z "${id}" ]]; then
        return 0
    fi
    # shellcheck disable=SC2154  # POKIDLE_DATA_DIR exported by the pokidle entrypoint
    local path="${POKIDLE_DATA_DIR}/biomes/${id}.png"
    if [[ -f "${path}" ]]; then
        printf '%s' "${path}"
    fi
}

# _notify_icon_path <name>
# Print the notify icon path for name if the file exists; nothing otherwise.
function _notify_icon_path {
    local name="$1"
    if [[ -z "${name}" ]]; then
        return 0
    fi
    # shellcheck disable=SC2154  # POKIDLE_DATA_DIR exported by the pokidle entrypoint
    local path="${POKIDLE_DATA_DIR}/notify/${name}.png"
    if [[ -f "${path}" ]]; then
        printf '%s' "${path}"
    fi
}

# _emit <title> <body> <urgency> <icon>
# Send a desktop notification, or print the fields when POKIDLE_NO_NOTIFY=1.
# A notify-send failure is logged but non-fatal.
function _emit {
    local title="$1"
    local body="$2"
    local urgency="$3"
    local icon="$4"
    # Display duration in ms (notify-send --expire-time); empty = daemon default.
    local timeout="${POKIDLE_NOTIFY_TIMEOUT_MS:-10000}"
    if [[ "${POKIDLE_NO_NOTIFY:-0}" == "1" ]]; then
        printf 'TITLE: %s\nBODY: %s\nURGENCY: %s\nICON: %s\nTIMEOUT: %s\n' \
            "${title}" "${body}" "${urgency}" "${icon}" "${timeout}"
        return 0
    fi
    local -a args=(--urgency "${urgency}")
    if [[ -n "${timeout}" ]]; then
        args+=(--expire-time "${timeout}")
    fi
    if [[ -n "${icon}" ]]; then
        args+=(--icon "${icon}")
    fi
    args+=(--hint "string:desktop-entry:pokidle")
    if ! notify-send "${args[@]}" "${title}" "${body}"; then
        printf 'notify-send failed (non-fatal)\n' >&2
    fi
}

# notify_pokemon <encounter_json>
# Notify about an encounter (with shiny/legendary prefix) and play its sound.
function notify_pokemon {
    local enc="$1"
    local species
    species="$(jq -r '.species' <<<"${enc}")"
    # Defense in depth: never emit an empty-species encounter notification.
    if [[ -z "${species}" || "${species}" == "null" ]]; then
        printf 'notify_pokemon: empty species, skipping notification\n' >&2
        return 1
    fi
    local level
    level="$(jq -r '.level' <<<"${enc}")"
    local nature
    nature="$(jq -r '.nature' <<<"${enc}")"
    local ability
    ability="$(jq -r '.ability' <<<"${enc}")"
    local shiny
    shiny="$(jq -r '.shiny' <<<"${enc}")"
    local held
    held="$(jq -r '.held_berry // ""' <<<"${enc}")"
    local is_legendary
    is_legendary="$(jq -r '.is_legendary // false' <<<"${enc}")"

    local moves
    moves="$(jq -r '.moves | map("• \(.)") | join("\n")' <<<"${enc}")"

    local sp_title
    sp_title="$(titlecase_words "${species}")"
    local nat_title
    nat_title="$(titlecase "${nature}")"
    local abil_title
    abil_title="$(titlecase_words "${ability}")"

    local prefix=""
    local urgency="normal"
    local sound_kind="encounter"
    if [[ "${shiny}" == "1" && "${is_legendary}" == "true" ]]; then
        prefix="[SHINY LEGENDARY ✨⚡] "
        sound_kind="legendary"
    elif [[ "${is_legendary}" == "true" ]]; then
        prefix="[LEGENDARY ⚡] "
        sound_kind="legendary"
    elif [[ "${shiny}" == "1" ]]; then
        prefix="[SHINY ✨] "
        sound_kind="shiny"
    fi

    local title="${prefix}Lv.${level} ${sp_title}"
    local body="${nat_title}  ·  ${abil_title}"$'\n\n'"${moves}"
    if [[ -n "${held}" && "${held}" != "null" ]]; then
        body+=$'\n\n'"Held: ${held}"
    fi

    local icon
    icon="$(jq -r '.sprite_path // ""' <<<"${enc}")"
    if [[ -z "${icon}" || ! -f "${icon}" ]]; then
        icon="$(_notify_icon_path encounter)"
    fi

    _emit "${title}" "${body}" "${urgency}" "${icon}"
    _play_sound "${sound_kind}"
}

# _play_sound <kind>
# Play the sound for kind if its per-kind toggle is on and the file exists.
# Playback is backgrounded; unknown kinds and POKIDLE_NO_NOTIFY=1 are no-ops.
function _play_sound {
    local kind="$1"

    # Suppressed notifications → no sound either (used by tests).
    if [[ "${POKIDLE_NO_NOTIFY:-0}" == "1" ]]; then
        return 0
    fi

    # Per-kind enable toggle, mirroring POKIDLE_NOTIFY_<KIND>. Defaults:
    # shiny + legendary on, everything else off.
    local -i enabled_default
    case "${kind}" in
        shiny | legendary) enabled_default=1 ;;
        encounter | item | biome | level | friendship) enabled_default=0 ;;
        *) return 0 ;;
    esac
    local toggle="POKIDLE_SOUND_${kind^^}_ENABLED"
    if [[ "${!toggle:-${enabled_default}}" != "1" ]]; then
        return 0
    fi

    # shellcheck disable=SC2154  # POKIDLE_DATA_DIR exported by the pokidle entrypoint
    local sounds_dir="${POKIDLE_SOUND_DIR:-${POKIDLE_DATA_DIR}/sounds}"
    local file=""
    # shellcheck disable=SC2249  # kind is validated by the enabled_default case above
    case "${kind}" in
        legendary)
            # Falls back legendary → shiny → encounter if a file is missing.
            file="${POKIDLE_SOUND_LEGENDARY:-${sounds_dir}/legendary.ogg}"
            if [[ ! -f "${file}" ]]; then
                file="${POKIDLE_SOUND_SHINY:-${sounds_dir}/shiny.ogg}"
            fi
            if [[ ! -f "${file}" ]]; then
                file="${POKIDLE_SOUND_ENCOUNTER:-${sounds_dir}/encounter.ogg}"
            fi
            ;;
        shiny) file="${POKIDLE_SOUND_SHINY:-${sounds_dir}/shiny.ogg}" ;;
        encounter) file="${POKIDLE_SOUND_ENCOUNTER:-${sounds_dir}/encounter.ogg}" ;;
        item) file="${POKIDLE_SOUND_ITEM:-${sounds_dir}/item.ogg}" ;;
        biome) file="${POKIDLE_SOUND_BIOME:-${sounds_dir}/biome.ogg}" ;;
        level) file="${POKIDLE_SOUND_LEVEL:-${sounds_dir}/level.ogg}" ;;
        friendship) file="${POKIDLE_SOUND_FRIENDSHIP:-${sounds_dir}/friendship.ogg}" ;;
    esac
    if [[ ! -f "${file}" ]]; then
        return 0
    fi
    if command -v paplay >/dev/null; then
        paplay "${file}" >/dev/null 2>&1 &
    elif command -v aplay >/dev/null; then
        aplay --quiet "${file}" >/dev/null 2>&1 &
    fi
}

# notify_item <item_json>
# Notify about a found item and play the item sound.
function notify_item {
    local item_json="$1"
    local name
    name="$(jq -r '.item' <<<"${item_json}")"
    # Defense in depth: never emit a "Found " notification for a missing item.
    if [[ -z "${name}" || "${name}" == "null" ]]; then
        printf 'notify_item: empty item name, skipping notification\n' >&2
        return 1
    fi
    local icon
    icon="$(jq -r '.sprite_path // ""' <<<"${item_json}")"
    if [[ -z "${icon}" || ! -f "${icon}" ]]; then
        icon="$(_notify_icon_path item)"
    fi
    local name_t
    name_t="$(titlecase_words "${name}")"
    local title="Found ${name_t}"
    local body=""
    _emit "${title}" "${body}" "low" "${icon}"
    _play_sound item
}

# notify_evolution <evo_json>
# Notify about an evolution and play the encounter sound.
function notify_evolution {
    local evo_json="$1"
    local from
    from="$(jq -r '.from' <<<"${evo_json}")"
    local to
    to="$(jq -r '.to' <<<"${evo_json}")"
    local icon
    icon="$(jq -r '.sprite_path // ""' <<<"${evo_json}")"
    if [[ -z "${icon}" || ! -f "${icon}" ]]; then
        icon="$(_notify_icon_path evolution)"
    fi

    local from_t
    from_t="$(titlecase_words "${from}")"
    local to_t
    to_t="$(titlecase_words "${to}")"
    local title="${from_t} evolved into ${to_t}!"
    local body=""

    _emit "${title}" "${body}" "normal" "${icon}"
    _play_sound encounter
}

# notify_biome_change <id> <label> <pool_size> <berry_count>
# Notify about a biome change and play the biome sound.
function notify_biome_change {
    local id="$1"
    local label="$2"
    local pool_size="$3"
    local berry_count="$4"
    local title="Biome changed → ${label}"
    local body="Encounters: ${pool_size} species, ${berry_count} berries"
    _emit "${title}" "${body}" "low" "$(_biome_icon_path "${id}")"
    _play_sound biome
}

# notify_level <species> <from> <to>
# Notify about a level-up and play the level sound.
function notify_level {
    local species="$1"
    local from="$2"
    local to="$3"
    local sp_title
    sp_title="$(titlecase_words "${species}")"
    local title="${sp_title} leveled ${from} → ${to}"
    local body=""
    _emit "${title}" "${body}" "low" "$(_notify_icon_path level-up)"
    _play_sound level
}

# notify_friendship <species> <from> <to>
# Notify about a friendship change and play the friendship sound.
function notify_friendship {
    local species="$1"
    local from="$2"
    local to="$3"
    local sp_title
    sp_title="$(titlecase_words "${species}")"
    local title="${sp_title} friendship ${from} → ${to}"
    local body=""
    _emit "${title}" "${body}" "low" "$(_notify_icon_path friendship)"
    _play_sound friendship
}
