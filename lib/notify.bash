#!/usr/bin/env bash
# lib/notify.bash — notify-send + sound playback.

_titlecase() {
    local s="$1"
    printf '%s' "${s^}"
}

_titlecase_words() {
    local s="$1"
    s="${s//-/ }"
    local out=""
    local w
    for w in $s; do
        out+="${w^} "
    done
    printf '%s' "${out% }"
}

_biome_icon_path() {
    local id="$1"
    [[ -n "$id" ]] || return 0
    local p="$POKIDLE_DATA_DIR/biomes/$id.png"
    [[ -f "$p" ]] && printf '%s' "$p"
}

_notify_icon_path() {
    local name="$1"
    [[ -n "$name" ]] || return 0
    local p="$POKIDLE_DATA_DIR/notify/$name.png"
    [[ -f "$p" ]] && printf '%s' "$p"
}

_emit() {
    local title="$1"
    local body="$2"
    local urgency="$3"
    local icon="$4"
    # Display duration in ms. notify-send -t; daemon may ignore for critical
    # urgency (shiny/legendary often persist regardless). Empty = daemon default.
    local timeout="${POKIDLE_NOTIFY_TIMEOUT_MS:-10000}"
    if [[ "${POKIDLE_NO_NOTIFY:-0}" == "1" ]]; then
        printf 'TITLE: %s\nBODY: %s\nURGENCY: %s\nICON: %s\nTIMEOUT: %s\n' \
            "$title" "$body" "$urgency" "$icon" "$timeout"
        return 0
    fi
    local args=(-u "$urgency")
    [[ -n "$timeout" ]] && args+=(-t "$timeout")
    [[ -n "$icon" ]] && args+=(-i "$icon")
    args+=(-h "string:desktop-entry:pokidle")
    notify-send "${args[@]}" "$title" "$body" || \
        printf 'notify-send failed (non-fatal)\n' >&2
}

notify_pokemon() {
    local enc="$1"
    local species level nature ability shiny held is_legendary
    species="$(jq -r '.species' <<< "$enc")"
    level="$(jq -r '.level' <<< "$enc")"
    nature="$(jq -r '.nature' <<< "$enc")"
    ability="$(jq -r '.ability' <<< "$enc")"
    shiny="$(jq -r '.shiny' <<< "$enc")"
    held="$(jq -r '.held_berry // ""' <<< "$enc")"
    is_legendary="$(jq -r '.is_legendary // false' <<< "$enc")"

    local moves
    moves="$(jq -r '.moves | map("• \(.)") | join("\n")' <<< "$enc")"

    local sp_title nat_title abil_title
    sp_title="$(_titlecase_words "$species")"
    nat_title="$(_titlecase "$nature")"
    abil_title="$(_titlecase_words "$ability")"

    local prefix="" urgency="normal" sound_kind="encounter"
    if [[ "$shiny" == "1" && "$is_legendary" == "true" ]]; then
        prefix="[SHINY LEGENDARY ✨⚡] "
        urgency="${POKIDLE_NOTIFY_URGENCY_LEGENDARY:-critical}"
        sound_kind="legendary"
    elif [[ "$is_legendary" == "true" ]]; then
        prefix="[LEGENDARY ⚡] "
        urgency="${POKIDLE_NOTIFY_URGENCY_LEGENDARY:-critical}"
        sound_kind="legendary"
    elif [[ "$shiny" == "1" ]]; then
        prefix="[SHINY ✨] "
        urgency="${POKIDLE_NOTIFY_URGENCY_SHINY:-critical}"
        sound_kind="shiny"
    fi

    local title body icon
    title="${prefix}Lv.$level $sp_title"
    body="$nat_title  ·  $abil_title"$'\n\n'"$moves"
    [[ -n "$held" && "$held" != "null" ]] && body+=$'\n\n'"Held: $held"

    icon="$(jq -r '.sprite_path // ""' <<< "$enc")"
    [[ -n "$icon" && -f "$icon" ]] || icon="$(_notify_icon_path encounter)"

    _emit "$title" "$body" "$urgency" "$icon"
    _play_sound "$sound_kind"
}

_play_sound() {
    local kind="$1"

    # Suppressed notifications → no sound either (used by tests).
    [[ "${POKIDLE_NO_NOTIFY:-0}" == "1" ]] && return 0

    # Per-kind enable toggle, mirroring POKIDLE_NOTIFY_<KIND>. Defaults:
    # shiny + legendary on, everything else off.
    local enabled_default
    case "$kind" in
        shiny|legendary)                       enabled_default=1 ;;
        encounter|item|biome|level|friendship) enabled_default=0 ;;
        *) return 0 ;;
    esac
    local toggle="POKIDLE_SOUND_${kind^^}_ENABLED"
    [[ "${!toggle:-$enabled_default}" == "1" ]] || return 0

    local sounds_dir="${POKIDLE_SOUND_DIR:-$POKIDLE_DATA_DIR/sounds}"
    local file=""
    case "$kind" in
        legendary)
            # Falls back legendary → shiny → encounter if a file is missing.
            file="${POKIDLE_SOUND_LEGENDARY:-$sounds_dir/legendary.ogg}"
            [[ -f "$file" ]] || file="${POKIDLE_SOUND_SHINY:-$sounds_dir/shiny.ogg}"
            [[ -f "$file" ]] || file="${POKIDLE_SOUND_ENCOUNTER:-$sounds_dir/encounter.ogg}"
            ;;
        shiny)      file="${POKIDLE_SOUND_SHINY:-$sounds_dir/shiny.ogg}" ;;
        encounter)  file="${POKIDLE_SOUND_ENCOUNTER:-$sounds_dir/encounter.ogg}" ;;
        item)       file="${POKIDLE_SOUND_ITEM:-$sounds_dir/item.ogg}" ;;
        biome)      file="${POKIDLE_SOUND_BIOME:-$sounds_dir/biome.ogg}" ;;
        level)      file="${POKIDLE_SOUND_LEVEL:-$sounds_dir/level.ogg}" ;;
        friendship) file="${POKIDLE_SOUND_FRIENDSHIP:-$sounds_dir/friendship.ogg}" ;;
    esac
    [[ -f "$file" ]] || return 0
    if   command -v paplay >/dev/null; then paplay "$file" >/dev/null 2>&1 &
    elif command -v aplay  >/dev/null; then aplay  -q "$file" >/dev/null 2>&1 &
    fi
}

notify_item() {
    local item_json="$1"
    local name icon
    name="$(jq -r '.item' <<< "$item_json")"
    icon="$(jq -r '.sprite_path // ""' <<< "$item_json")"
    [[ -n "$icon" && -f "$icon" ]] || icon="$(_notify_icon_path item)"
    local title body
    title="Found $(_titlecase_words "$name")"
    body=""
    _emit "$title" "$body" "low" "$icon"
    _play_sound item
}

notify_evolution() {
    local evo_json="$1"
    local from to icon
    from="$(jq -r '.from' <<< "$evo_json")"
    to="$(jq -r '.to' <<< "$evo_json")"
    icon="$(jq -r '.sprite_path // ""' <<< "$evo_json")"
    [[ -n "$icon" && -f "$icon" ]] || icon="$(_notify_icon_path evolution)"

    local from_t to_t title body
    from_t="$(_titlecase_words "$from")"
    to_t="$(_titlecase_words "$to")"
    title="$from_t evolved into $to_t!"
    body=""

    _emit "$title" "$body" "normal" "$icon"
    _play_sound encounter
}

notify_biome_change() {
    local id="$1" label="$2" pool_size="$3" berry_count="$4"
    local title="Biome changed → $label"
    local body="Encounters: $pool_size species, $berry_count berries"
    _emit "$title" "$body" "low" "$(_biome_icon_path "$id")"
    _play_sound biome
}

notify_level() {
    local species="$1" from="$2" to="$3"
    local sp_title title body
    sp_title="$(_titlecase_words "$species")"
    title="$sp_title leveled $from → $to"
    body=""
    _emit "$title" "$body" "low" "$(_notify_icon_path level-up)"
    _play_sound level
}

notify_friendship() {
    local species="$1" from="$2" to="$3"
    local sp_title title body
    sp_title="$(_titlecase_words "$species")"
    title="$sp_title friendship $from → $to"
    body=""
    _emit "$title" "$body" "low" "$(_notify_icon_path friendship)"
    _play_sound friendship
}
