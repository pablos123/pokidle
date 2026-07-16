#!/usr/bin/env bash
# `pokidle daemon` — daemon lifecycle (run loop + systemctl/journalctl wrappers).
# shellcheck disable=SC2154  # POKIDLE_* config vars come from the entrypoint

# pokidle_daemon_help
# Print the `pokidle daemon` subcommand help.
function pokidle_daemon_help {
    cat <<'EOF'
pokidle daemon — daemon lifecycle.

Usage:
  pokidle daemon <verb> [args...]

Verbs:
  run        Main encounter loop (used by the systemd unit)
  start      Start the systemd user service
  stop       Stop it
  restart    Restart it (reload current code)
  status     systemctl status + current biome + tick state
  logs [a]   journalctl --user -u pokidle (args passed through)
  enable     Start on login
  disable    Don't start on login

Options:
  -h, --help    Show this help
EOF
}

# Daemon scheduler helpers.
# Default: target is in [next clock hour, next clock hour + interval) so ticks
# fire ~hourly with a small random jitter (matches passive-game spec).
# POKIDLE_TICK_FAST=1: cadence-based mode for smoke tests; target is in
# [now, now + interval). Useful for `timeout 200 ./pokidle daemon` runs.
# _pokidle_next_tick_target <now> <interval>
# Print the next tick's target epoch.
function _pokidle_next_tick_target {
    local -i now="$1"
    local -i interval="$2"
    if [[ "${POKIDLE_TICK_FAST:-0}" == "1" ]]; then
        printf '%d' "$((now + RANDOM % interval))"
        return
    fi
    local -i next_hour=$(((now / 3600 + 1) * 3600))
    printf '%d' "$((next_hour + RANDOM % interval))"
}

# True when a whole interval elapsed past a tick target. In normal operation the
# loop wakes within seconds of a target; only downtime (suspend/resume, NTP step,
# a stalled loop) lets wall-clock run a full cycle past it. Such ticks are
# "missed" — reschedule them silently instead of firing every overdue kind at
# once (which made all notifications appear simultaneously after a wake).
# _pokidle_tick_missed <now> <target> <interval>
# True (exit 0) if a whole interval has elapsed past the tick target.
function _pokidle_tick_missed {
    local -i now="$1"
    local -i target="$2"
    local -i interval="$3"
    ((now - target >= interval))
}

# Wait in small chunks, not one long sleep. coreutils `sleep` counts monotonic
# time, which freezes during suspend; a single `sleep $((next_event - now))`
# therefore drifts arbitrarily far behind wall clock across a suspend (an hourly
# tick can stay asleep for days). Capping each sleep means the loop re-reads
# `date +%s` at least every chunk, so a post-resume wall-clock jump is noticed
# within one chunk and the per-kind target checks handle it.
# _pokidle_sleep_chunk <next_event> <now>
# Print seconds to sleep: min(next_event - now, POKIDLE_SLEEP_CHUNK), floored at 1.
function _pokidle_sleep_chunk {
    local -i next_event="$1"
    local -i now="$2"
    local -i cap="${POKIDLE_SLEEP_CHUNK:-60}"
    local -i gap=$((next_event - now))
    if ((gap > cap)); then
        gap=${cap}
    fi
    if ((gap < 1)); then
        gap=1
    fi
    printf '%d' "${gap}"
}

# _pokidle_should_rotate_biome <started_at> <now>
# True (exit 0) if the active biome session has outlived POKIDLE_BIOME_HOURS.
function _pokidle_should_rotate_biome {
    local -i started_at="$1"
    local -i now="$2"
    local -i hours="${POKIDLE_BIOME_HOURS:-3}"
    ((now - started_at >= hours * 3600))
}

# pokidle_daemon
# Run the main scheduling loop: hold a single-instance lock, open/rotate the
# biome session, restore or schedule per-kind tick targets, then sleep until the
# next due event and fire the matching tick. Used by the systemd unit.
function _pokidle_daemon_run {
    # Single-instance guard: hold an exclusive lock for the daemon's lifetime.
    if command -v flock >/dev/null; then
        local lock_file="${POKIDLE_RUNTIME_DIR:-${POKIDLE_CACHE_DIR}}/pokidle.daemon.lock"
        mkdir -p -- "${lock_file%/*}"
        exec {POKIDLE_LOCK_FD}>"${lock_file}"
        if ! flock --nonblock "${POKIDLE_LOCK_FD}"; then
            printf 'daemon: another pokidle daemon is already running (lock: %s)\n' "${lock_file}" >&2
            return 1
        fi
    fi

    db_init
    if ! biome_validate; then
        printf 'daemon: biome config invalid; aborting\n' >&2
        return 1
    fi

    local active
    active="$(db_active_biome_session)"
    local biome
    local sid
    local biome_started_at
    if [[ -z "${active}" ]]; then
        biome="$(biome_pick_random)"
        biome_started_at="$(date +%s)"
        sid="$(db_open_biome_session "${biome}" "${biome_started_at}")"
    else
        IFS=$'\t' read -r sid biome biome_started_at <<<"${active}"
        # If active session is older than the rotation window, close + rotate now.
        if _pokidle_should_rotate_biome "${biome_started_at}" "$(date +%s)"; then
            db_close_biome_session "${sid}" "$(date +%s)"
            biome="$(biome_pick_random_excluding "${biome}")"
            biome_started_at="$(date +%s)"
            sid="$(db_open_biome_session "${biome}" "${biome_started_at}")"
            _pokidle_announce_biome "${biome}"
        fi
    fi

    # Restore tick targets, or schedule fresh.
    local now
    now="$(date +%s)"
    local next_pokemon
    next_pokemon="$(db_state_get last_pokemon_tick_target)"
    if ((${next_pokemon:-0} <= now)); then
        next_pokemon="$(_pokidle_next_tick_target "${now}" "${POKIDLE_POKEMON_INTERVAL:-3600}")"
        _pokidle_persist_target last_pokemon_tick_target "${next_pokemon}"
    fi
    local next_item
    next_item="$(db_state_get last_item_tick_target)"
    if ((${next_item:-0} <= now)); then
        next_item="$(_pokidle_next_tick_target "${now}" "${POKIDLE_ITEM_INTERVAL:-7200}")"
        _pokidle_persist_target last_item_tick_target "${next_item}"
    fi
    local next_pickup
    next_pickup="$(db_state_get last_pickup_tick_target)"
    if ((${next_pickup:-0} <= now)); then
        next_pickup="$(_pokidle_next_tick_target "${now}" "${POKIDLE_PICKUP_INTERVAL:-7200}")"
        _pokidle_persist_target last_pickup_tick_target "${next_pickup}"
    fi
    local next_level
    next_level="$(db_state_get last_level_tick_target)"
    if ((${next_level:-0} <= now)); then
        next_level="$(_pokidle_next_tick_target "${now}" "${POKIDLE_LEVEL_INTERVAL:-3600}")"
        _pokidle_persist_target last_level_tick_target "${next_level}"
    fi
    local next_friendship
    next_friendship="$(db_state_get last_friendship_tick_target)"
    if ((${next_friendship:-0} <= now)); then
        next_friendship="$(_pokidle_next_tick_target "${now}" "${POKIDLE_FRIENDSHIP_INTERVAL:-1800}")"
        _pokidle_persist_target last_friendship_tick_target "${next_friendship}"
    fi
    local next_evolve
    next_evolve="$(db_state_get last_evolve_tick_target)"
    if ((${next_evolve:-0} <= now)); then
        next_evolve="$(_pokidle_next_tick_target "${now}" "${POKIDLE_EVOLVE_INTERVAL:-10800}")"
        _pokidle_persist_target last_evolve_tick_target "${next_evolve}"
    fi
    local next_legendary
    next_legendary="$(db_state_get last_legendary_tick_target)"
    if ((${next_legendary:-0} <= now)); then
        next_legendary="$(_pokidle_next_tick_target "${now}" "${POKIDLE_LEGENDARY_INTERVAL:-86400}")"
        _pokidle_persist_target last_legendary_tick_target "${next_legendary}"
    fi

    # shellcheck disable=SC2064  # expand sid now so the trap closes the right session
    trap "_pokidle_shutdown ${sid}; exit 0" INT TERM

    while :; do
        now="$(date +%s)"

        if _pokidle_should_rotate_biome "${biome_started_at}" "${now}"; then
            db_close_biome_session "${sid}" "${now}"
            biome="$(biome_pick_random_excluding "${biome}")"
            biome_started_at="${now}"
            sid="$(db_open_biome_session "${biome}" "${biome_started_at}")"
            _pokidle_announce_biome "${biome}"
        fi

        if ((now >= next_pokemon)); then
            if _pokidle_should_fire "${now}" "${next_pokemon}" "${POKIDLE_POKEMON_ENABLED:-1}" "${POKIDLE_POKEMON_INTERVAL:-3600}"; then
                if ! pokidle_tick encounter --no-dry-run; then
                    printf 'daemon: encounter tick failed (continuing)\n' >&2
                fi
            fi
            next_pokemon="$(_pokidle_next_tick_target "${now}" "${POKIDLE_POKEMON_INTERVAL:-3600}")"
            _pokidle_persist_target last_pokemon_tick_target "${next_pokemon}"
        fi
        if ((now >= next_item)); then
            if _pokidle_should_fire "${now}" "${next_item}" "${POKIDLE_ITEM_ENABLED:-1}" "${POKIDLE_ITEM_INTERVAL:-7200}"; then
                if ! pokidle_tick item --no-dry-run; then
                    printf 'daemon: item tick failed (continuing)\n' >&2
                fi
            fi
            next_item="$(_pokidle_next_tick_target "${now}" "${POKIDLE_ITEM_INTERVAL:-7200}")"
            _pokidle_persist_target last_item_tick_target "${next_item}"
        fi
        if ((now >= next_pickup)); then
            if _pokidle_should_fire "${now}" "${next_pickup}" "${POKIDLE_PICKUP_ENABLED:-1}" "${POKIDLE_PICKUP_INTERVAL:-7200}"; then
                if ! pokidle_tick pickup --no-dry-run; then
                    printf 'daemon: pickup tick failed (continuing)\n' >&2
                fi
            fi
            next_pickup="$(_pokidle_next_tick_target "${now}" "${POKIDLE_PICKUP_INTERVAL:-7200}")"
            _pokidle_persist_target last_pickup_tick_target "${next_pickup}"
        fi
        if ((now >= next_level)); then
            if _pokidle_should_fire "${now}" "${next_level}" "${POKIDLE_LEVEL_ENABLED:-1}" "${POKIDLE_LEVEL_INTERVAL:-3600}"; then
                if ! pokidle_tick level --no-dry-run --json >/dev/null; then
                    printf 'daemon: level tick failed (continuing)\n' >&2
                fi
            fi
            next_level="$(_pokidle_next_tick_target "${now}" "${POKIDLE_LEVEL_INTERVAL:-3600}")"
            _pokidle_persist_target last_level_tick_target "${next_level}"
        fi
        if ((now >= next_friendship)); then
            if _pokidle_should_fire "${now}" "${next_friendship}" "${POKIDLE_FRIENDSHIP_ENABLED:-1}" "${POKIDLE_FRIENDSHIP_INTERVAL:-1800}"; then
                if ! pokidle_tick friendship --no-dry-run --json >/dev/null; then
                    printf 'daemon: friendship tick failed (continuing)\n' >&2
                fi
            fi
            next_friendship="$(_pokidle_next_tick_target "${now}" "${POKIDLE_FRIENDSHIP_INTERVAL:-1800}")"
            _pokidle_persist_target last_friendship_tick_target "${next_friendship}"
        fi
        if ((now >= next_evolve)); then
            if _pokidle_should_fire "${now}" "${next_evolve}" "${POKIDLE_EVOLVE_ENABLED:-1}" "${POKIDLE_EVOLVE_INTERVAL:-10800}"; then
                if ! pokidle_tick evolve --no-dry-run --json >/dev/null; then
                    printf 'daemon: evolve tick failed (continuing)\n' >&2
                fi
            fi
            next_evolve="$(_pokidle_next_tick_target "${now}" "${POKIDLE_EVOLVE_INTERVAL:-10800}")"
            _pokidle_persist_target last_evolve_tick_target "${next_evolve}"
        fi
        if ((now >= next_legendary)); then
            if _pokidle_should_fire "${now}" "${next_legendary}" "${POKIDLE_LEGENDARY_ENABLED:-1}" "${POKIDLE_LEGENDARY_INTERVAL:-86400}"; then
                if ! pokidle_tick legendary --no-dry-run --json >/dev/null; then
                    printf 'daemon: legendary tick failed (continuing)\n' >&2
                fi
            fi
            next_legendary="$(_pokidle_next_tick_target "${now}" "${POKIDLE_LEGENDARY_INTERVAL:-86400}")"
            _pokidle_persist_target last_legendary_tick_target "${next_legendary}"
        fi

        db_log_prune $((${POKIDLE_LOG_RETENTION_DAYS:-7} * 86400))

        local -i biome_end=$((biome_started_at + ${POKIDLE_BIOME_HOURS:-3} * 3600))
        local -i next_event=${next_pokemon}
        if ((next_item < next_event)); then
            next_event=${next_item}
        fi
        if ((next_pickup < next_event)); then
            next_event=${next_pickup}
        fi
        if ((next_level < next_event)); then
            next_event=${next_level}
        fi
        if ((next_friendship < next_event)); then
            next_event=${next_friendship}
        fi
        if ((next_evolve < next_event)); then
            next_event=${next_evolve}
        fi
        if ((next_legendary < next_event)); then
            next_event=${next_legendary}
        fi
        if ((biome_end < next_event)); then
            next_event=${biome_end}
        fi
        sleep "$(_pokidle_sleep_chunk "${next_event}" "${now}")"
    done
}

# _pokidle_require_systemctl
# Ensure systemctl exists before a lifecycle verb shells out to it.
function _pokidle_require_systemctl {
    if ! command -v systemctl >/dev/null; then
        printf 'daemon: systemctl not found (the daemon is a systemd user service)\n' >&2
        return 1
    fi
}

# pokidle_daemon <verb> [args...]
# Verb dispatcher for the daemon lifecycle. `run` is the blocking encounter loop
# (systemd ExecStart); the rest are thin systemctl/journalctl wrappers. An
# explicit verb is required — bare `daemon` prints usage and exits 2.
function pokidle_daemon {
    local verb="${1-}"
    if [[ -n "${verb}" ]]; then
        shift
    fi
    case "${verb}" in
        run)
            _pokidle_daemon_run "$@"
            ;;
        start | stop | restart | enable | disable)
            _pokidle_require_systemctl || return 1
            systemctl --user "${verb}" pokidle.service
            ;;
        status)
            pokidle_status "$@"
            ;;
        logs)
            if ! command -v journalctl >/dev/null; then
                printf 'daemon: journalctl not found\n' >&2
                return 1
            fi
            journalctl --user -u pokidle.service "$@"
            ;;
        -h | --help | help)
            pokidle_daemon_help
            return 0
            ;;
        '')
            _pokidle_usage_error pokidle_daemon_help 'daemon: a verb is required'
            return
            ;;
        -*)
            _pokidle_usage_error pokidle_daemon_help 'daemon: unknown option %s' "${verb}"
            return
            ;;
        *)
            _pokidle_usage_error pokidle_daemon_help 'daemon: unknown verb: %s' "${verb}"
            return
            ;;
    esac
}

# _pokidle_persist_target <state_key> <target>
# Persist a tick target to daemon_state, warning (non-fatal) on failure.
function _pokidle_persist_target {
    local key="$1"
    local target="$2"
    if ! db_state_set "${key}" "${target}"; then
        printf 'daemon: persist %s failed (continuing)\n' "${key}" >&2
    fi
}

# _pokidle_should_fire <now> <target> <enabled> <interval>
# True (exit 0) if a tick should fire now: the kind is enabled and the target
# was not missed (a full interval overdue, e.g. after suspend/resume).
function _pokidle_should_fire {
    local -i now="$1"
    local -i target="$2"
    local enabled="$3"
    local -i interval="$4"
    if [[ "${enabled}" != "1" ]]; then
        return 1
    fi
    if _pokidle_tick_missed "${now}" "${target}" "${interval}"; then
        return 1
    fi
    return 0
}

# _pokidle_announce_biome <biome>
# Send a biome-change notification with the biome's pool and berry counts,
# unless POKIDLE_NOTIFY_BIOME is disabled.
function _pokidle_announce_biome {
    local biome="$1"
    if [[ "${POKIDLE_NOTIFY_BIOME:-1}" != "1" ]]; then
        return 0
    fi
    local label
    label="$(biome_label "${biome}")"
    local p
    p="$(encounter_pool_path "${biome}")"
    local pool_size
    local berry_count
    if [[ -f "${p}" ]]; then
        pool_size="$(jq '[.tiers[] | length] | add // 0' "${p}")"
        berry_count="$(jq '.berries | length' "${p}")"
    else
        pool_size=0
        berry_count=0
    fi
    notify_biome_change "${biome}" "${label}" "${pool_size}" "${berry_count}"
}

# _pokidle_shutdown <sid>
# Log daemon shutdown. The biome session is left open so a restart resumes it.
function _pokidle_shutdown {
    local sid="$1"
    printf 'pokidle: shutting down (session #%s left open)\n' "${sid}" >&2
}

# pokidle_status
# Print the systemd unit status, the current biome, and the daemon_state table.
function pokidle_status {
    printf '=== systemctl --user status pokidle.service ===\n'
    if ! systemctl --user status pokidle.service --no-pager 2>&1; then
        : # non-zero when inactive; output already shown
    fi
    printf '\n=== current biome ===\n'
    pokidle_current
    printf '\n=== daemon_state ===\n'
    db_init
    db_query "SELECT key, value FROM daemon_state ORDER BY key;" |
        awk -F'\t' '{ printf "  %-32s %s\n", $1, $2 }'
}
