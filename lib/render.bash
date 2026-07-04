#!/usr/bin/env bash
# Shared CLI rendering helpers: inline sprite preview, sprite/name resolution,
# and encounter event-log formatting. Used by the encounters/items/current/tick
# commands. Depends on pokemon_sprite/item_sprite (api.bash),
# showdown_item_pokeapi_slug (showdown.bash) and db_log_event (db.bash), all
# resolved at call time via the entrypoint's load order.

# _pokidle_render_sprite <sprite>
# Render a sprite inline via chafa. chafa auto-detects the terminal's graphics
# protocol (kitty/sixel/iterm → pixel-perfect, symbol cells otherwise), so the
# preview is as crisp as the terminal allows. No-op if chafa is absent or the
# sprite path is empty/null.
function _pokidle_render_sprite {
    local sprite="$1"
    if [[ -z "${sprite}" || "${sprite}" == "null" ]]; then
        return 0
    fi
    if ! command -v chafa >/dev/null; then
        return 0
    fi
    if ! chafa --size="${POKIDLE_IMG_WIDTH:-16}" "${sprite}" 2>/dev/null; then
        : # rendering is best-effort
    fi
}

# _pokidle_sprite_name <enc-json>
# The Pokemon resource name whose sprite represents this encounter: the specific
# form/variety if present, else the bare species. PokeAPI serves form-specific
# sprites under the variety name (e.g. meowth-galar), so a regional-form
# encounter must resolve its sprite against the variety, not the base species.
function _pokidle_sprite_name {
    jq -r '.variety // .species' <<<"$1"
}

# _pokidle_pokemon_sprite <name> <shiny>
# Resolve a pokemon sprite via the pokeapi lib (cache-aware, rate-limited by
# pokeapi_get on JSON cache misses). Prints a local path or nothing.
# POKIDLE_FETCH_SPRITES=0 disables network entirely (used by tests/offline).
function _pokidle_pokemon_sprite {
    local name="$1"
    local shiny="$2"
    if [[ "${POKIDLE_FETCH_SPRITES:-1}" != "1" ]]; then
        return 0
    fi
    local variant=front_default
    if [[ "${shiny}" == "1" ]]; then
        variant=front_shiny
    fi
    if ! pokemon_sprite "${name}" "${variant}" 2>/dev/null; then
        return 0
    fi
}

# _pokidle_item_sprite <name>
# Resolve an item sprite via the pokeapi lib. Prints a local path or nothing;
# POKIDLE_FETCH_SPRITES=0 disables network.
function _pokidle_item_sprite {
    local name="$1"
    if [[ "${POKIDLE_FETCH_SPRITES:-1}" != "1" ]]; then
        return 0
    fi
    # Drops carry the Showdown item slug; the sprite lives under the PokeAPI slug,
    # which differs for a few renamed items (e.g. pretty-feather -> pretty-wing).
    local pokeapi
    pokeapi="$(showdown_item_pokeapi_slug "${name}")"
    if ! item_sprite "${pokeapi}" 2>/dev/null; then
        return 0
    fi
}

# _pokidle_render_encounter_row <ts> <biome> <lvl> <form> <shiny> <nat> <abil> <gender> <stats> <ivs> <evs> <moves> <held>
# Print one encounter entry — the shared layout used by both the `encounters`
# list and a `tick`. <shiny> is "1" for a shiny; <held> is a bare berry name or
# "". Names are prettified for display: the form via its Showdown name (falling
# back to a titlecased slug when Showdown can't resolve it, e.g. offline), and
# ability/nature/moves titlecased. The held berry (full "Sitrus Berry" name) and
# shiny sparkle trail the form on the first line, the berry leading the sparkle.
function _pokidle_render_encounter_row {
    local ts="$1" biome="$2" lvl="$3" form="$4" shiny="$5" nat="$6" abil="$7"
    local gender="$8" stats="$9" ivs="${10}" evs="${11}" moves="${12}" held="${13}"
    local biome_pretty
    biome_pretty="$(_pokidle_biome_display "${biome}")"
    local form_pretty
    form_pretty="$(species_display_name "${form}")"
    # Moves arrive ", "-joined; slugs have no spaces, so drop the spaces, split on
    # the comma, and titlecase each ("water-gun" -> "Water Gun").
    local moves_pretty="" sep=""
    local -a move_slugs
    IFS=',' read -ra move_slugs <<<"${moves// /}"
    local mv
    for mv in "${move_slugs[@]}"; do
        [[ -z "${mv}" ]] && continue
        moves_pretty+="${sep}$(titlecase_words "${mv}")"
        sep=", "
    done
    local trail=""
    if [[ -n "${held}" && "${held}" != "null" ]]; then
        trail=" @ $(titlecase_words "${held}") Berry"
    fi
    if [[ "${shiny}" == "1" ]]; then
        trail+=" ✨"
    fi
    printf '%s   [%s]   Lv.%s %s%s\n' "${ts}" "${biome_pretty}" "${lvl}" "${form_pretty}" "${trail}"
    printf '   %s · %s · %s\n' "$(titlecase_words "${nat}")" "$(titlecase_words "${abil}")" "${gender}"
    printf '   Stats: %s\n   IVs:   %s\n   EVs:   %s\n   Moves: %s\n' \
        "${stats}" "${ivs}" "${evs}" "${moves_pretty}"
}

# _pokidle_render_item_row <ts> <biome> <item-slug> <kind> <used>
# Print one item-drop entry — the shared layout used by the `items` list and a
# `tick` item/pickup. The slug is shown as its pretty name; <kind> is "item" or
# "pickup"; a non-empty <used> appends the "(used)" marker.
function _pokidle_render_item_row {
    local ts="$1" biome="$2" item="$3" kind="$4" used="$5"
    local biome_pretty
    biome_pretty="$(_pokidle_biome_display "${biome}")"
    local pretty
    pretty="$(titlecase_words "${item}")"
    local suffix="   (${kind})"
    if [[ -n "${used}" ]]; then
        suffix+="   (used)"
    fi
    printf '%s   [%s]   %s%s\n' "${ts}" "${biome_pretty}" "${pretty}" "${suffix}"
}

# _pokidle_biome_display <biome-id>
# The biome's human label (Crystal Cavern) for display rows, falling back to the
# raw id when biome_label can't resolve it (unknown id, or the biome lib not
# loaded — e.g. a render-only unit test). Never blanks.
function _pokidle_biome_display {
    local id="$1"
    local label
    if label="$(biome_label "${id}" 2>/dev/null)" && [[ -n "${label}" ]]; then
        printf '%s' "${label}"
        return
    fi
    printf '%s' "${id}"
}

# _pokidle_log_encounter <kind> <enc-json> <biome>
# Append an event_log row for a persisted pokemon/legendary encounter. Shiny is
# rendered as the literal "(shiny)". A held berry is appended compactly as the
# raw item slug "@sitrus-berry" (the bare berry name plus the "-berry" suffix),
# keeping the log terse.
function _pokidle_log_encounter {
    local kind="$1"
    local enc="$2"
    local biome="$3"
    local summary
    summary="$(jq -r --arg b "${biome}" '
        ((.held_berry // "") | if . == "" or . == null then "" else " @" + . + "-berry" end) as $held
        | "\(.variety // .species) Lv.\(.level) \(.gender) [\($b)]"
        + (if .shiny == 1 then " (shiny)" else "" end)
        + $held' <<<"${enc}")"
    db_log_event "${kind}" "${summary}"
}
