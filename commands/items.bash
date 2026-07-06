#!/usr/bin/env bash
# `pokidle items` — pretty list of item drops.

# pokidle_items_help
# Print the `pokidle items` subcommand help.
function pokidle_items_help {
    cat <<'EOF'
pokidle items — pretty list of item drops.

Usage:
  pokidle items [options]

Options:
  --since DATE   Drops at/after DATE (YYYY-MM-DD or any date(1) string)
  --until DATE   Drops at/before DATE
  --biome ID     Filter by biome
  --item NAME    Substring match on item
  --limit N      Cap rows (default: 50)
  --all          Include used (consumed) drops
  --sort KEY     date|name (default: date)
  --reverse      Reverse the sort (default: ascending)
  --no-images    Skip inline sprite previews
  --json         Emit raw JSON
  -h, --help     Show this help
EOF
}

# pokidle_items [options...]
# Pretty-print item drops (or raw JSON with --json; --all includes consumed
# drops). Remaining args are db_list_item_drops options.
function pokidle_items {
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
            --all)
                args+=(--include-consumed)
                shift
                ;;
            -h | --help | help)
                pokidle_items_help
                return 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    local rows
    local _db_list_errctx="items"
    if ! rows="$(db_list_item_drops "${args[@]}")"; then
        return 2
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
    # matching date -d) into one US-delimited line per row; the bash loop only
    # renders sprites and prints. The unit separator (\x1f, non-whitespace) is
    # used instead of a tab so read preserves empty fields (e.g. a blank sprite
    # path).
    local US=$'\037'
    local id ts_fmt biome item sprite consumed kind
    local -i first=1
    while IFS="${US}" read -r id ts_fmt biome item sprite consumed kind; do
        if ((first)); then
            first=0
        else
            printf -- '%s\n' "${sep_line}"
        fi
        if ((!no_images)); then
            if [[ -z "${sprite}" || ! -f "${sprite}" ]]; then
                sprite="$(_pokidle_item_sprite "${item}")"
                # Persist a freshly-resolved sprite so the row is permanently
                # repaired: its original drop-time fetch failed transiently (see
                # the item_sprite retry). No-op when still unresolved.
                if [[ -n "${sprite}" && -f "${sprite}" ]]; then
                    db_update_item_drop_sprite "${id}" "${sprite}"
                fi
            fi
            _pokidle_render_sprite "${sprite}"
        fi
        _pokidle_render_item_row "${ts_fmt}" "${biome}" "${item}" "${kind}" "${consumed}"
        printf '\n'
    done < <(jq -r --arg US "${US}" '.[] | [
        .id,
        (.encountered_at | strflocaltime("%F %H:%M")),
        .biome_id, .item, (.sprite_path // ""), (.consumed_at // ""), (.kind // "item")
    ] | map(tostring) | join($US)' <<<"${rows}")
}
