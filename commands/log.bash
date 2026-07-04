#!/usr/bin/env bash
# `pokidle log` — recent tick event log.

# pokidle_log_help
# Print the `pokidle log` subcommand help.
function pokidle_log_help {
    cat <<'EOF'
pokidle log — one line per logged tick event within the retention window
(POKIDLE_LOG_RETENTION_DAYS, default 7). Oldest-first by default.

Usage:
  pokidle log [options]

Options:
  --kind KIND   encounter|item|level|friendship|evolve|legendary
  --limit N     Cap rows
  --reverse     Newest first (default: oldest first)
  --json        Emit raw JSON
  -h, --help    Show this help
EOF
}

# pokidle_log [options...]
# One line per logged tick event within the retention window
# (POKIDLE_LOG_RETENTION_DAYS, default 7). Oldest-first by default. Flags:
# --kind <k> --limit N --reverse --json.
function pokidle_log {
    db_init
    local -i json_mode=0
    local -a args=()
    while (($# > 0)); do
        case "$1" in
            --json)
                json_mode=1
                shift
                ;;
            --kind | --limit)
                if (($# < 2)); then
                    printf 'log: %s needs a value\n' "$1" >&2
                    return 2
                fi
                args+=("$1" "$2")
                shift 2
                ;;
            --reverse)
                args+=("$1")
                shift
                ;;
            -h | --help | help)
                pokidle_log_help
                return 0
                ;;
            -*)
                printf 'log: unknown option %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'log: unexpected argument %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    local -i retention=$((${POKIDLE_LOG_RETENTION_DAYS:-7} * 86400))
    local rows
    rows="$(db_list_log "${args[@]}" "${retention}")"

    if ((json_mode)); then
        printf '%s\n' "${rows}"
        return
    fi

    # One jq pass formats the timestamp (strflocaltime honours $TZ, matching
    # date -d) and emits TSV; one awk pass pads and prints.
    jq -r '.[] | [(.ts | strflocaltime("%F %H:%M")), .kind, .summary] | @tsv' <<<"${rows}" |
        awk -F'\t' '{ printf "%s   %-10s %s\n", $1, $2, $3 }'
}
