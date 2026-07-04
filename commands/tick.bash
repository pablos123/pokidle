#!/usr/bin/env bash
# `pokidle tick` — run a single roll now (default: dry-run, no DB write).
# shellcheck disable=SC2154  # POKIDLE_DB_PATH/CACHE_DIR come from the entrypoint

# pokidle_tick_help
# Print the `pokidle tick` subcommand help.
function pokidle_tick_help {
    cat <<'EOF'
pokidle tick — run a single roll now (default: dry-run, no DB write).

Usage:
  pokidle tick <kind> [options]

Kinds:
  encounter | item | pickup | level | friendship | evolve | legendary

Options:
  --no-dry-run   Persist DB writes
  --no-notify    Skip notify-send
  --no-images    Skip the inline sprite preview
  --no-output    Print nothing (still notifies)
  --json         Emit JSON to stdout
  -h, --help     Show this help
EOF
}

# _pokidle_print_encounter <enc_with_meta>
# Print a just-rolled encounter using the exact layout of one `encounters` list
# entry (timestamped now). Pulls the fields in one jq pass, then defers to the
# shared _pokidle_render_encounter_row.
function _pokidle_print_encounter {
    local enc="$1"
    local US=$'\037'
    local form lvl shiny nat abil gender stats ivs evs moves held biome
    IFS="${US}" read -r form lvl shiny nat abil gender stats ivs evs moves held biome < <(
        jq -r --arg US "${US}" '[
            (.variety // .species), (.level | tostring), (.shiny | tostring),
            .nature, .ability, .gender,
            ((.stats // []) | map(tostring) | join("/")),
            ((.ivs // []) | map(tostring) | join("/")),
            ((.evs // []) | map(tostring) | join("/")),
            ((.moves // []) | join(", ")),
            (.held_berry // ""), (.biome_id // "")
        ] | join($US)' <<<"${enc}"
    )
    _pokidle_render_encounter_row "$(date '+%F %H:%M')" "${biome}" "${lvl}" "${form}" \
        "${shiny}" "${nat}" "${abil}" "${gender}" "${stats}" "${ivs}" "${evs}" "${moves}" "${held}"
}

# pokidle_tick <kind> [options]
# Run a single roll. An explicit kind is required — bare `tick` prints usage and
# exits 2 (mirrors `daemon <verb>`). kind: encounter | item (level/friendship/
# evolve/legendary dispatch to their own functions). Flags: --dry-run (default) /
# --no-dry-run / --no-notify / --no-images / --no-output / --json.
function pokidle_tick {
    local kind="${1-}"
    if [[ -n "${kind}" ]]; then
        shift
    fi

    # Validate the kind up-front (before any DB/biome work). Sub-commands that
    # manage their own flags and DB init are dispatched early; encounter/item
    # fall through to the shared roll logic below.
    case "${kind}" in
        level)
            pokidle_tick_level "$@"
            return
            ;;
        friendship)
            pokidle_tick_friendship "$@"
            return
            ;;
        evolve)
            pokidle_tick_evolve "$@"
            return
            ;;
        legendary)
            pokidle_tick_legendary "$@"
            return
            ;;
        encounter | item | pickup) ;;
        -h | --help | help)
            pokidle_tick_help
            return 0
            ;;
        '')
            printf 'tick: a kind is required\n' >&2
            usage >&2
            return 2
            ;;
        -*)
            printf 'tick: unknown option %s\n' "${kind}" >&2
            usage >&2
            return 2
            ;;
        *)
            printf 'tick: unknown kind: %s\n' "${kind}" >&2
            usage >&2
            return 2
            ;;
    esac

    local -i dry_run=1
    local -i no_notify=0
    local -i no_images=0
    local -i no_output=0
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-dry-run)
                dry_run=0
                shift
                ;;
            --no-notify)
                no_notify=1
                shift
                ;;
            --no-images)
                no_images=1
                shift
                ;;
            --no-output)
                no_output=1
                shift
                ;;
            --json)
                emit_json=1
                shift
                ;;
            -*)
                printf 'tick: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'tick: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    db_init

    local row
    row="$(db_active_biome_session)"
    local sid
    local biome
    if [[ -z "${row}" ]]; then
        biome="$(biome_pick_random)"
        sid="$(db_open_biome_session "${biome}" "$(date +%s)")"
    else
        IFS=$'\t' read -r sid biome _ <<<"${row}"
    fi
    local label
    label="$(biome_label "${biome}")"

    case "${kind}" in
        encounter)
            if [[ ! -f "$(encounter_pool_path "${biome}")" ]]; then
                printf 'tick: no pool for %s — run rebuild-pool first\n' "${biome}" >&2
                return 1
            fi
            local pool
            pool="$(encounter_pool_load "${biome}")"
            local enc
            if ! enc="$(encounter_roll_importable "${pool}" "${biome}")"; then
                printf 'tick: no importable pokemon for %s after retries — skipping tick\n' "${biome}" >&2
                return 0
            fi

            local sprite_path
            sprite_path="$(_pokidle_pokemon_sprite \
                "$(_pokidle_sprite_name "${enc}")" "$(jq -r '.shiny' <<<"${enc}")")"

            local enc_with_meta
            enc_with_meta="$(jq -c \
                --arg label "${label}" --arg sp "${sprite_path}" --arg bid "${biome}" '
                . + {biome_label: $label, sprite_path: $sp, biome_id: $bid}
            ' <<<"${enc}")"

            if ((dry_run == 0)); then
                local enc_for_db
                enc_for_db="$(jq -c \
                    --argjson sid "${sid}" --argjson ts "$(date +%s)" --arg sp "${sprite_path}" '
                    . + {session_id: $sid, encountered_at: $ts, sprite_path: $sp}
                ' <<<"${enc}")"
                db_insert_encounter "${enc_for_db}"
                _pokidle_log_encounter encounter "${enc}" "${biome}"
            fi
            if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_POKEMON:-1}" == "1" ]]; then
                notify_pokemon "${enc_with_meta}"
            fi
            if ((no_output == 0)); then
                if ((!no_images)); then
                    _pokidle_render_sprite "${sprite_path}"
                fi
                if ((emit_json)); then
                    printf '%s\n' "${enc_with_meta}"
                else
                    _pokidle_print_encounter "${enc_with_meta}"
                fi
            fi
            ;;
        item)
            local item_json
            if ! item_json="$(encounter_roll_item "${biome}")"; then
                printf 'tick: item roll failed for %s\n' "${biome}" >&2
                return 1
            fi
            local item_name
            item_name="$(jq -r '.item' <<<"${item_json}")"
            local sprite_path
            sprite_path="$(_pokidle_item_sprite "${item_name}")"
            local item_with_meta
            item_with_meta="$(jq -c --arg l "${label}" --arg sp "${sprite_path}" --arg bid "${biome}" '
                . + {biome_label: $l, sprite_path: $sp, biome_id: $bid}
            ' <<<"${item_json}")"
            if ((dry_run == 0)); then
                db_insert_item_drop "${sid}" "$(date +%s)" "${item_name}" "${sprite_path}" item
                db_log_event item "${item_name} [${biome}]"
            fi
            if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_ITEM:-1}" == "1" ]]; then
                notify_item "${item_with_meta}"
            fi
            if ((no_output == 0)); then
                if ((!no_images)); then
                    _pokidle_render_sprite "${sprite_path}"
                fi
                if ((emit_json)); then
                    printf '%s\n' "${item_with_meta}"
                else
                    _pokidle_render_item_row "$(date '+%F %H:%M')" "${biome}" "${item_name}" item ""
                fi
            fi
            ;;
        pickup)
            local item_json
            if ! item_json="$(encounter_roll_pickup)"; then
                printf 'tick: pickup roll failed\n' >&2
                return 1
            fi
            local item_name
            item_name="$(jq -r '.item' <<<"${item_json}")"
            local sprite_path
            sprite_path="$(_pokidle_item_sprite "${item_name}")"
            local item_with_meta
            item_with_meta="$(jq -c --arg l "${label}" --arg sp "${sprite_path}" --arg bid "${biome}" '
                . + {biome_label: $l, sprite_path: $sp, biome_id: $bid}
            ' <<<"${item_json}")"
            if ((dry_run == 0)); then
                db_insert_item_drop "${sid}" "$(date +%s)" "${item_name}" "${sprite_path}" pickup
                db_log_event pickup "${item_name}"
            fi
            if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_PICKUP:-1}" == "1" ]]; then
                notify_pickup "${item_with_meta}"
            fi
            if ((no_output == 0)); then
                if ((!no_images)); then
                    _pokidle_render_sprite "${sprite_path}"
                fi
                if ((emit_json)); then
                    printf '%s\n' "${item_with_meta}"
                else
                    _pokidle_render_item_row "$(date '+%F %H:%M')" "${biome}" "${item_name}" pickup ""
                fi
            fi
            ;;
        *)
            printf 'tick: unknown kind %s\n' "${kind}" >&2
            return 2
            ;;
    esac
}
# pokidle_tick_level [flags]
# Probabilistically level up current-week encounters (chance falls off toward
# level 100), recomputing stats. Flags as pokidle_tick (--no-images is accepted
# for a uniform interface but is a no-op: this tick renders no inline sprite).
function pokidle_tick_level {
    local -i dry_run=1
    local -i no_notify=0
    local -i no_output=0
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-dry-run)
                dry_run=0
                shift
                ;;
            --no-notify)
                no_notify=1
                shift
                ;;
            --no-images)
                shift
                ;;
            --no-output)
                no_output=1
                shift
                ;;
            --json)
                emit_json=1
                shift
                ;;
            -*)
                printf 'tick level: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'tick level: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    db_init
    local rows
    rows="$(db_list_current_week_encounters)"
    local -i notify_on=0
    if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_LEVEL:-0}" == "1" ]]; then
        notify_on=1
    fi
    local leveled='[]'
    # One jq pass flattens every row into a US-delimited record (id, species,
    # level, nature, and the IV/EV sextets as space-joined strings), read in a
    # single loop — no per-row re-index or field forks.
    local US=$'\037'
    local -a leveled_objs=()
    local id species level nature ivs evs
    while IFS="${US}" read -r id species level nature ivs evs; do
        if ((level >= 100)); then
            continue
        fi
        # Chance falls off linearly with level: from POKIDLE_LEVEL_CHANCE at
        # low level down to POKIDLE_LEVEL_CHANCE_MIN near level 100.
        local base_chance="${POKIDLE_LEVEL_CHANCE:-30}"
        local floor_chance="${POKIDLE_LEVEL_CHANCE_MIN:-5}"
        local -i chance=$((floor_chance + (base_chance - floor_chance) * (100 - level) / 100))
        if ((chance < floor_chance)); then
            chance=${floor_chance}
        fi
        if ((RANDOM % 100 >= chance)); then
            continue
        fi

        local -i new_level=$((level + ${POKIDLE_LEVEL_GAIN:-1}))
        if ((new_level > 100)); then
            new_level=100
        fi

        local poke
        if ! poke="$(pokeapi_get "pokemon/${species}")"; then
            continue
        fi
        local base_stats
        base_stats="$(jq -c '.stats' <<<"${poke}")"
        local mods
        if ! mods="$(encounter_nature_mods "${nature}")"; then
            continue
        fi
        local stats
        if ! stats="$(encounter_compute_all_stats "${base_stats}" "${ivs}" "${evs}" "${new_level}" "${mods}")"; then
            continue
        fi

        if ((dry_run == 0)); then
            db_update_encounter_level_stats "${id}" "${new_level}" "${stats}"
            db_log_event level "${species} #${id}  ${level} → ${new_level}"
        fi
        if ((notify_on)); then
            notify_level "${species}" "${level}" "${new_level}"
        fi
        leveled_objs+=("$(jq -n -c --argjson id "${id}" --arg sp "${species}" \
            --argjson from "${level}" --argjson to "${new_level}" \
            '{id:$id, species:$sp, from:$from, to:$to}')")
    done < <(jq -r --arg US "${US}" '.[] | [
        .id, (.variety // .species), (.level | tostring), .nature,
        "\(.iv_hp) \(.iv_atk) \(.iv_def) \(.iv_spa) \(.iv_spd) \(.iv_spe)",
        "\(.ev_hp) \(.ev_atk) \(.ev_def) \(.ev_spa) \(.ev_spd) \(.ev_spe)"
    ] | join($US)' <<<"${rows}")

    if ((${#leveled_objs[@]} > 0)); then
        leveled="$(printf '%s\n' "${leveled_objs[@]}" | jq -s -c '.')"
    fi

    if ((no_output)); then
        return 0
    fi
    if ((emit_json)); then
        jq -n --argjson l "${leveled}" '{leveled: $l}'
    else
        local -i lc
        lc="$(jq 'length' <<<"${leveled}")"
        if ((lc == 0)); then
            printf 'level: no candidates leveled this tick\n'
        else
            jq -r '.[] | "level: \(.species) #\(.id)  \(.from) -> \(.to)"' <<<"${leveled}"
        fi
    fi
}
# pokidle_tick_friendship [flags]
# Probabilistically raise friendship on current-week encounters. Flags as
# pokidle_tick (--no-images is accepted for a uniform interface but is a no-op:
# this tick renders no inline sprite).
function pokidle_tick_friendship {
    local -i dry_run=1
    local -i no_notify=0
    local -i no_output=0
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-dry-run)
                dry_run=0
                shift
                ;;
            --no-notify)
                no_notify=1
                shift
                ;;
            --no-images)
                shift
                ;;
            --no-output)
                no_output=1
                shift
                ;;
            --json)
                emit_json=1
                shift
                ;;
            -*)
                printf 'tick friendship: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'tick friendship: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    db_init
    local rows
    rows="$(db_list_current_week_encounters)"
    local -i notify_on=0
    if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_FRIENDSHIP:-0}" == "1" ]]; then
        notify_on=1
    fi
    local befriended='[]'
    # One jq pass flattens each row to a US-delimited (id, species, friendship)
    # record, read in a single loop — no per-row re-index or field forks.
    local US=$'\037'
    local -a befriended_objs=()
    local id species fr_old
    while IFS="${US}" read -r id species fr_old; do
        if ((fr_old >= 255)); then
            continue
        fi
        if ((RANDOM % 100 >= ${POKIDLE_FRIENDSHIP_CHANCE:-50})); then
            continue
        fi

        local -i fr_new=$((fr_old + ${POKIDLE_FRIENDSHIP_GAIN:-5}))
        if ((fr_new > 255)); then
            fr_new=255
        fi

        if ((dry_run == 0)); then
            db_update_encounter_friendship "${id}" "${fr_new}"
            db_log_event friendship "${species} #${id}  ${fr_old} → ${fr_new}"
        fi
        if ((notify_on)); then
            notify_friendship "${species}" "${fr_old}" "${fr_new}"
        fi
        befriended_objs+=("$(jq -n -c --argjson id "${id}" --arg sp "${species}" \
            --argjson from "${fr_old}" --argjson to "${fr_new}" \
            '{id:$id, species:$sp, from:$from, to:$to}')")
    done < <(jq -r --arg US "${US}" \
        '.[] | [.id, (.variety // .species), (.friendship | tostring)] | join($US)' <<<"${rows}")

    if ((${#befriended_objs[@]} > 0)); then
        befriended="$(printf '%s\n' "${befriended_objs[@]}" | jq -s -c '.')"
    fi

    if ((no_output)); then
        return 0
    fi
    if ((emit_json)); then
        jq -n --argjson b "${befriended}" '{befriended: $b}'
    else
        local -i bc
        bc="$(jq 'length' <<<"${befriended}")"
        if ((bc == 0)); then
            printf 'friendship: no candidates befriended this tick\n'
        else
            jq -r '.[] | "friendship: \(.species) #\(.id)  \(.from) -> \(.to)"' <<<"${befriended}"
        fi
    fi
}
# pokidle_tick_evolve [flags]
# Probabilistically evolve eligible current-week encounters (chance keyed to the
# species' pool tier), consuming item drops for item evolutions. Flags as
# pokidle_tick (--no-images is accepted for a uniform interface but is a no-op:
# this tick renders no inline sprite).
function pokidle_tick_evolve {
    local -i dry_run=1
    local -i no_notify=0
    local -i no_output=0
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-dry-run)
                dry_run=0
                shift
                ;;
            --no-notify)
                no_notify=1
                shift
                ;;
            --no-images)
                shift
                ;;
            --no-output)
                no_output=1
                shift
                ;;
            --json)
                emit_json=1
                shift
                ;;
            -*)
                printf 'tick evolve: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'tick evolve: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    db_init

    local active
    active="$(db_active_biome_session)"
    if [[ -z "${active}" ]]; then
        printf 'tick evolve: no active biome session\n' >&2
        return 1
    fi
    local sid
    local biome
    IFS=$'\t' read -r sid biome _ <<<"${active}"

    local rows
    rows="$(db_list_current_week_encounters)"
    local evolved='[]'
    # One jq pass flattens each row to a US-delimited record: id, the encountered
    # form (variety), the bare species, and the encounter object the evolution
    # checker expects (emitted as a JSON field via tojson) — no per-row re-index
    # or field forks.
    #
    # Evolution is intentionally FULL RANDOM: a form/regional encounter
    # (variety != species, e.g. meowth-galar) evolves via its BARE-species chain
    # — pokemon-species/<variety> 404s, and PokeAPI's evolution-chain is
    # species-keyed with no form discriminator, so there is no reliable way to
    # map a source form to its "correct" branch without a static table (which
    # this project deliberately avoids). We embrace the randomness as a game
    # mechanic: any form may evolve into any viable branch. The chain lookup
    # therefore uses `species` (bare); `variety` is carried only for display so
    # the encountered form's name is shown. Do NOT "fix" this into a static
    # regional-evolution map — that is a deliberate design choice, not a bug.
    local US=$'\037'
    local -a evolved_objs=()
    local enc_id variety species enc_obj
    while IFS="${US}" read -r enc_id variety species enc_obj; do
        local spec
        if ! spec="$(pokeapi_get "pokemon-species/${species}" 2>/dev/null)"; then
            continue
        fi
        local chain_url
        chain_url="$(jq -r '.evolution_chain.url' <<<"${spec}")"
        if [[ -z "${chain_url}" || "${chain_url}" == "null" ]]; then
            continue
        fi
        local chain_id="${chain_url%/}"
        chain_id="${chain_id##*/}"
        local chain
        if ! chain="$(pokeapi_get "evolution-chain/${chain_id}" 2>/dev/null)"; then
            continue
        fi
        local stages
        stages="$(evolution_next_stages "${chain}" "${species}")"
        local -i stage_count
        stage_count="$(jq 'length' <<<"${stages}")"
        if ((stage_count == 0)); then
            continue
        fi

        local viable
        viable="$(evolution_enumerate_viable_paths "${enc_obj}" "${stages}")"
        local -i v_n
        v_n="$(jq 'length' <<<"${viable}")"
        if ((v_n == 0)); then
            continue
        fi

        local tier
        tier="$(evolution_tier_lookup "${biome}" "${species}")"
        local chance
        case "${tier}" in
            common) chance="${POKIDLE_EVOLVE_CHANCE_COMMON:-25}" ;;
            uncommon) chance="${POKIDLE_EVOLVE_CHANCE_UNCOMMON:-15}" ;;
            rare) chance="${POKIDLE_EVOLVE_CHANCE_RARE:-8}" ;;
            very_rare) chance="${POKIDLE_EVOLVE_CHANCE_VERY_RARE:-3}" ;;
            *) chance="${POKIDLE_EVOLVE_CHANCE_COMMON:-25}" ;;
        esac
        if ((RANDOM % 100 >= chance)); then
            continue
        fi

        local -i idx=$((RANDOM % v_n))
        # One read pulls the chosen path's species, kind, and the path object
        # itself (as JSON) — instead of three jq forks on the same value.
        local new_species kind pick
        IFS="${US}" read -r new_species kind pick < <(jq -r --arg US "${US}" --argjson idx "${idx}" \
            '.[$idx] | [.species, .kind, tojson] | join($US)' <<<"${viable}")

        # Display the encountered form on the "from" side and the rolled result
        # form on the "to" side. evolution_apply echoes the variety it actually
        # rolled (random, full-random mechanic above); in --dry-run it is not
        # called, so fall back to the bare evolved species for the preview.
        local to_form="${new_species}"
        if ((dry_run == 0)); then
            if ! to_form="$(evolution_apply "${enc_id}" "${pick}")"; then
                continue
            fi
            db_log_event evolve "${variety} → ${to_form} #${enc_id}"
        fi
        if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_EVOLVE:-1}" == "1" ]]; then
            local sprite_meta
            sprite_meta="$(sqlite3 "${POKIDLE_DB_PATH}" \
                "SELECT sprite_path FROM encounters WHERE id=${enc_id};")"
            local b_label
            b_label="$(biome_label "${biome}")"
            local notify_obj
            notify_obj="$(jq -n --arg from "${variety}" --arg to "${to_form}" \
                --arg label "${b_label}" --arg sp "${sprite_meta}" --arg bid "${biome}" \
                '{from:$from, to:$to, biome_label:$label, sprite_path:$sp, biome_id:$bid}')"
            notify_evolution "${notify_obj}"
        fi
        evolved_objs+=("$(jq -n -c \
            --argjson id "${enc_id}" --arg from "${variety}" --arg to "${to_form}" --arg kind "${kind}" \
            '{id:$id, from:$from, to:$to, kind:$kind}')")
    done < <(jq -r --arg US "${US}" '.[] | [
        (.id | tostring), (.variety // .species), .species,
        ({gender, level, friendship,
          stats: [.stat_hp, .stat_atk, .stat_def, .stat_spa, .stat_spd, .stat_spe],
          moves: (.moves_json | fromjson)} | tojson)
    ] | join($US)' <<<"${rows}")

    if ((${#evolved_objs[@]} > 0)); then
        evolved="$(printf '%s\n' "${evolved_objs[@]}" | jq -s -c '.')"
    fi

    if ((no_output)); then
        return 0
    fi
    if ((emit_json)); then
        jq -n --argjson e "${evolved}" '{evolved: $e}'
    else
        local -i ec
        ec="$(jq 'length' <<<"${evolved}")"
        if ((ec == 0)); then
            printf 'evolve: no candidates evolved this tick\n'
        else
            jq -r '.[] | "evolve: #\(.id) \(.from) -> \(.to) (\(.kind))"' <<<"${evolved}"
        fi
    fi
}
# pokidle_tick_legendary [flags]
# Roll for a legendary spawn (POKIDLE_LEGENDARY_CHANCE%); on success build and
# optionally persist/notify the encounter. Flags as pokidle_tick.
function pokidle_tick_legendary {
    local -i dry_run=1
    local -i no_notify=0
    local -i no_images=0
    local -i no_output=0
    local -i emit_json=0
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                dry_run=1
                shift
                ;;
            --no-dry-run)
                dry_run=0
                shift
                ;;
            --no-notify)
                no_notify=1
                shift
                ;;
            --no-images)
                no_images=1
                shift
                ;;
            --no-output)
                no_output=1
                shift
                ;;
            --json)
                emit_json=1
                shift
                ;;
            -*)
                printf 'tick legendary: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'tick legendary: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    db_init

    local active
    active="$(db_active_biome_session)"
    local sid
    local biome
    if [[ -z "${active}" ]]; then
        biome="$(biome_pick_random)"
        sid="$(db_open_biome_session "${biome}" "$(date +%s)")"
    else
        IFS=$'\t' read -r sid biome _ <<<"${active}"
    fi

    local chance="${POKIDLE_LEGENDARY_CHANCE:-3}"
    if ((RANDOM % 100 >= chance)); then
        if ((no_output == 0)); then
            if ((emit_json)); then
                jq -n '{spawned: false}'
            else
                printf 'legendary: no spawn this tick (chance=%s)\n' "${chance}"
            fi
        fi
        return 0
    fi

    local enc
    if ! enc="$(legendary_roll_importable "${biome}")"; then
        printf 'legendary: no importable legendary for biome %s after retries — skipping\n' "${biome}" >&2
        return 0
    fi
    local species
    species="$(jq -r '.species' <<<"${enc}")"
    local sprite_url
    sprite_url="$(jq -r '.sprite_url // ""' <<<"${enc}")"
    local sprite_path=""
    if [[ -n "${sprite_url}" ]] && { ((no_notify == 0)) || { ((no_output == 0)) && ((!no_images)); }; }; then
        # Key by the variety (e.g. shaymin-sky), not the bare species, so a form
        # legendary's sprite never collides with the base form's cached PNG.
        sprite_path="${POKIDLE_CACHE_DIR}/sprites/$(_pokidle_sprite_name "${enc}").png"
        mkdir -p -- "${sprite_path%/*}"
        if [[ ! -f "${sprite_path}" ]]; then
            if ! curl --silent --show-error --output "${sprite_path}" "${sprite_url}"; then
                sprite_path=""
            fi
        fi
    fi

    local label
    label="$(biome_label "${biome}")"
    local enc_with_meta
    enc_with_meta="$(jq -c \
        --arg label "${label}" --arg sp "${sprite_path}" --arg bid "${biome}" '
        . + {biome_label: $label, sprite_path: $sp, biome_id: $bid}
    ' <<<"${enc}")"

    if ((dry_run == 0)); then
        local enc_for_db
        enc_for_db="$(jq -c \
            --argjson sid "${sid}" --argjson ts "$(date +%s)" --arg sp "${sprite_path}" '
            . + {session_id: $sid, encountered_at: $ts, sprite_path: $sp}
        ' <<<"${enc}")"
        db_insert_encounter "${enc_for_db}"
        _pokidle_log_encounter legendary "${enc}" "${biome}"
    fi

    if ((no_notify == 0)) && [[ "${POKIDLE_NOTIFY_POKEMON:-1}" == "1" ]]; then
        notify_pokemon "${enc_with_meta}"
    fi

    if ((no_output == 0)); then
        if ((!no_images)); then
            _pokidle_render_sprite "${sprite_path}"
        fi
        if ((emit_json)); then
            printf '%s\n' "${enc_with_meta}"
        else
            _pokidle_print_encounter "${enc_with_meta}"
        fi
    fi
}
