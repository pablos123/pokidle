#!/usr/bin/env bash
# sqlite wrappers.
# Requires:
#   POKIDLE_DB_PATH      path to sqlite db file
#   POKIDLE_REPO_ROOT    repo root (for locating schema.sql)

: "${POKIDLE_DB_PATH:?POKIDLE_DB_PATH must be set before sourcing lib/db.bash}"

# _db_assert_int <value> [name=arg]
# Return 2 with a diagnostic if value is not an integer. Guards against SQL
# injection via raw interpolation of numeric arguments.
function _db_assert_int {
    if [[ ! "$1" =~ ^-?[0-9]+$ ]]; then
        printf 'db: %s: expected integer, got %q\n' "${2:-arg}" "$1" >&2
        return 2
    fi
}

# _db_column_exists <table> <column>
# True (exit 0) if <table> has a column named <column>.
function _db_column_exists {
    local table="$1"
    local col="$2"
    # shellcheck disable=SC2154  # POKIDLE_DB_PATH asserted set at top of file
    sqlite3 "${POKIDLE_DB_PATH}" "PRAGMA table_info(${table});" |
        cut -d'|' -f2 | grep --fixed-strings --quiet --line-regexp -- "${col}"
}

# db_init
# Create the database from schema.sql and apply additive column migrations.
# Returns 1 if schema.sql is missing.
function db_init {
    # shellcheck disable=SC2154  # POKIDLE_REPO_ROOT exported by the pokidle entrypoint
    local schema="${POKIDLE_REPO_ROOT}/schema.sql"
    if [[ ! -f "${schema}" ]]; then
        printf 'db_init: schema.sql not found at %s\n' "${schema}" >&2
        return 1
    fi
    mkdir -p -- "${POKIDLE_DB_PATH%/*}"
    sqlite3 "${POKIDLE_DB_PATH}" <"${schema}"
    # Additive migrations: schema.sql uses CREATE TABLE IF NOT EXISTS, which
    # never adds columns to a pre-existing table. Add new columns here.
    if ! _db_column_exists item_drops consumed_at; then
        db_exec "ALTER TABLE item_drops ADD COLUMN consumed_at INTEGER;"
    fi
    # variety holds the specific encountered form (e.g. meowth-galar). Bare-form
    # mons leave it equal to species. Rows predating this column read as NULL.
    if ! _db_column_exists encounters variety; then
        db_exec "ALTER TABLE encounters ADD COLUMN variety TEXT;"
    fi
}

# db_exec <sql>...
# Run SQL with no result formatting.
function db_exec {
    sqlite3 "${POKIDLE_DB_PATH}" "$@"
}

# db_query <sql>...
# Run SQL with tab-separated output.
function db_query {
    sqlite3 -separator $'\t' "${POKIDLE_DB_PATH}" "$@"
}

# db_query_json <sql>...
# Run SQL with JSON output.
function db_query_json {
    sqlite3 -json "${POKIDLE_DB_PATH}" "$@"
}

# db_open_biome_session <biome_id> <started_at>
# Insert a biome session row and print its rowid.
function db_open_biome_session {
    local biome="$1"
    local started_at="$2"
    if ! _db_assert_int "${started_at}" started_at; then
        return 2
    fi
    db_query "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('${biome//\'/\'\'}', ${started_at}); SELECT last_insert_rowid();"
}

# db_close_biome_session <id> <ended_at>
# Set ended_at on biome session <id>.
function db_close_biome_session {
    local id="$1"
    local ended_at="$2"
    if ! _db_assert_int "${id}" id; then
        return 2
    fi
    if ! _db_assert_int "${ended_at}" ended_at; then
        return 2
    fi
    db_exec "UPDATE biome_sessions SET ended_at=${ended_at} WHERE id=${id};"
}

# db_active_biome_session
# Print "id\tbiome_id\tstarted_at" of the active (open) session, or empty.
function db_active_biome_session {
    db_query "SELECT id, biome_id, started_at FROM biome_sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1;"
}

# db_insert_encounter <encounter_json>
# Insert an encounter described by a JSON object in argv[1].
# Required keys: session_id, encountered_at, species, dex_id, level, nature,
# ability, is_hidden_ability, gender, shiny, held_berry, ivs[6], evs[6],
# stats[6], moves[], sprite_path.
# Optional: variety (the specific form, e.g. meowth-galar); defaults to species.
function db_insert_encounter {
    local enc="$1"
    # jq filter emits SQL literals: NULL for null, single-quoted with doubled
    # internal quotes for strings (SQL standard), bare for numbers.
    local jq_filter
    # read returns 1 at the delimiter-less EOF; the heredoc form forces || true.
    read -r -d '' jq_filter <<'JQ' || true
def sqstr: if . == null then "NULL" else "'" + (tostring | gsub("'"; "''")) + "'" end;
"INSERT INTO encounters (
    session_id, encountered_at, species, variety, dex_id, level,
    nature, ability, is_hidden_ability, gender, shiny, held_berry,
    friendship,
    iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
    ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,
    stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe,
    moves_json, sprite_path
) VALUES (
    \(.session_id),
    \(.encountered_at),
    \(.species | sqstr),
    \((.variety // .species) | sqstr),
    \(.dex_id),
    \(.level),
    \(.nature | sqstr),
    \(.ability | sqstr),
    \(.is_hidden_ability),
    \(.gender | sqstr),
    \(.shiny),
    \(.held_berry | sqstr),
    \(.friendship),
    \(.ivs[0]), \(.ivs[1]), \(.ivs[2]), \(.ivs[3]), \(.ivs[4]), \(.ivs[5]),
    \(.evs[0]), \(.evs[1]), \(.evs[2]), \(.evs[3]), \(.evs[4]), \(.evs[5]),
    \(.stats[0]), \(.stats[1]), \(.stats[2]), \(.stats[3]), \(.stats[4]), \(.stats[5]),
    \(.moves | tojson | sqstr),
    \(.sprite_path | sqstr)
);"
JQ
    local sql
    sql="$(jq -r "${jq_filter}" <<<"${enc}")"
    db_exec "${sql}"
}

# db_list_encounters [filters...]
# List encounters as JSON. Filters parsed from argv:
#   --shiny --since YYYY-MM-DD --until YYYY-MM-DD --biome <id>
#   --species <name> --nature <name> --min-iv-total N --limit N
#   --sort date|name|level --reverse
# Always selects the newest N rows (--limit), then orders that window by the
# chosen key. Ascending by default (date=oldest-first); --reverse flips it.
function db_list_encounters {
    local -a where=()
    local -i limit=50
    local ts
    local sort_key="date"
    local -i reverse=0
    while (($# > 0)); do
        case "$1" in
            --shiny)
                where+=("e.shiny=1")
                shift
                ;;
            --since)
                if ! ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                where+=("e.encountered_at >= ${ts}")
                shift 2
                ;;
            --until)
                if ! ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                where+=("e.encountered_at <= ${ts}")
                shift 2
                ;;
            --biome)
                where+=("s.biome_id='${2//\'/\'\'}'")
                shift 2
                ;;
            --species)
                where+=("e.species LIKE '%${2//\'/\'\'}%'")
                shift 2
                ;;
            --nature)
                where+=("e.nature='${2//\'/\'\'}'")
                shift 2
                ;;
            --min-iv-total)
                if ! _db_assert_int "$2" --min-iv-total; then
                    return 2
                fi
                where+=("(e.iv_hp+e.iv_atk+e.iv_def+e.iv_spa+e.iv_spd+e.iv_spe) >= $2")
                shift 2
                ;;
            --limit)
                if ! _db_assert_int "$2" --limit; then
                    return 2
                fi
                limit="$2"
                shift 2
                ;;
            --sort)
                case "$2" in
                    date | name | level)
                        sort_key="$2"
                        ;;
                    *)
                        printf 'db_list_encounters: invalid --sort: %s (date|name|level)\n' "$2" >&2
                        return 2
                        ;;
                esac
                shift 2
                ;;
            --reverse)
                reverse=1
                shift
                ;;
            *)
                printf 'db_list_encounters: unknown flag: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done
    local order_expr
    case "${sort_key}" in
        name) order_expr="COALESCE(variety, species) COLLATE NOCASE" ;;
        level) order_expr="level" ;;
        *) order_expr="encountered_at" ;;
    esac
    local dir="ASC"
    if ((reverse)); then
        dir="DESC"
    fi
    local sql="SELECT e.*, s.biome_id FROM encounters e JOIN biome_sessions s ON s.id=e.session_id"
    if ((${#where[@]})); then
        local joined
        printf -v joined '%s AND ' "${where[@]}"
        sql+=" WHERE ${joined% AND }"
    fi
    sql+=" ORDER BY e.encountered_at DESC LIMIT ${limit}"
    sql="SELECT * FROM (${sql}) ORDER BY ${order_expr} ${dir}, encountered_at ${dir}, id ${dir};"
    db_query_json "${sql}"
}

# db_insert_item_drop <session_id> <ts> <item> <sprite>
# Insert an item drop row. <sprite> may be empty (stored as NULL).
function db_insert_item_drop {
    local session_id="$1"
    local ts="$2"
    local item="$3"
    local sprite="$4"
    if ! _db_assert_int "${session_id}" session_id; then
        return 2
    fi
    if ! _db_assert_int "${ts}" ts; then
        return 2
    fi
    local sprite_sql="NULL"
    if [[ -n "${sprite}" ]]; then
        sprite_sql="'${sprite//\'/\'\'}'"
    fi
    db_exec "INSERT INTO item_drops(session_id, encountered_at, item, sprite_path)
             VALUES (${session_id}, ${ts}, '${item//\'/\'\'}', ${sprite_sql});"
}

# db_list_item_drops [filters...]
# List item drops as JSON. Filters parsed from argv:
#   --since YYYY-MM-DD --until YYYY-MM-DD --biome <id> --item <name>
#   --limit N --sort date|name --reverse --include-consumed
# Always selects the newest N rows (--limit), then orders that window by the
# chosen key. Ascending by default (date=oldest-first); --reverse flips it.
# --sort level is accepted but treated as date (items have no level).
# Consumed drops are excluded unless --include-consumed is given.
function db_list_item_drops {
    local -a where=()
    local -i limit=50
    local ts
    local sort_key="date"
    local -i reverse=0
    local -i include_consumed=0
    while (($# > 0)); do
        case "$1" in
            --since)
                if ! ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                where+=("d.encountered_at >= ${ts}")
                shift 2
                ;;
            --until)
                if ! ts="$(date -d "$2" +%s)"; then
                    return 2
                fi
                where+=("d.encountered_at <= ${ts}")
                shift 2
                ;;
            --biome)
                where+=("s.biome_id='${2//\'/\'\'}'")
                shift 2
                ;;
            --item)
                where+=("d.item LIKE '%${2//\'/\'\'}%'")
                shift 2
                ;;
            --limit)
                if ! _db_assert_int "$2" --limit; then
                    return 2
                fi
                limit="$2"
                shift 2
                ;;
            --sort)
                case "$2" in
                    date | name | level)
                        sort_key="$2"
                        ;;
                    *)
                        printf 'db_list_item_drops: invalid --sort: %s (date|name)\n' "$2" >&2
                        return 2
                        ;;
                esac
                shift 2
                ;;
            --reverse)
                reverse=1
                shift
                ;;
            --include-consumed)
                include_consumed=1
                shift
                ;;
            *)
                printf 'db_list_item_drops: unknown flag: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done
    if ((!include_consumed)); then
        where+=("d.consumed_at IS NULL")
    fi
    local order_expr="encountered_at"
    if [[ "${sort_key}" == "name" ]]; then
        order_expr="item COLLATE NOCASE"
    fi
    local dir="ASC"
    if ((reverse)); then
        dir="DESC"
    fi
    local sql="SELECT d.*, s.biome_id FROM item_drops d JOIN biome_sessions s ON s.id=d.session_id"
    if ((${#where[@]})); then
        local joined
        printf -v joined '%s AND ' "${where[@]}"
        sql+=" WHERE ${joined% AND }"
    fi
    sql+=" ORDER BY d.encountered_at DESC LIMIT ${limit}"
    sql="SELECT * FROM (${sql}) ORDER BY ${order_expr} ${dir}, encountered_at ${dir}, id ${dir};"
    db_query_json "${sql}"
}

# db_list_current_week_encounters
# Print a JSON array of encounter rows whose encountered_at falls within the
# current local ISO week (Mon 00:00 — Sun 23:59:59).
function db_list_current_week_encounters {
    # %u: 1=Mon..7=Sun. Compute Monday at 00:00 local.
    local dow
    dow="$(date +%u)"
    local mon_ts
    if ! mon_ts="$(date -d "$((dow - 1)) days ago $(date +%F) 00:00:00" +%s 2>/dev/null)"; then
        mon_ts="$(date -v-$((dow - 1))d -v0H -v0M -v0S +%s)"
    fi
    local -i sun_ts=$((mon_ts + 7 * 86400 - 1))
    db_query_json "
        SELECT * FROM encounters
        WHERE encountered_at BETWEEN ${mon_ts} AND ${sun_ts}
        ORDER BY id ASC;"
}

# db_update_encounter_level_stats <id> <level> <stats_str>
# Update level + stat_* columns of encounter <id>.
# stats_str is "hp atk def spa spd spe" (space-separated integers).
function db_update_encounter_level_stats {
    local id="$1"
    local level="$2"
    local stats_str="$3"
    if ! _db_assert_int "${id}" id; then
        return 2
    fi
    if ! _db_assert_int "${level}" level; then
        return 2
    fi
    local -a stats
    read -ra stats <<<"${stats_str}"
    local s
    for s in "${stats[@]}"; do
        if ! _db_assert_int "${s}" stat; then
            return 2
        fi
    done
    db_exec "UPDATE encounters
        SET level=${level},
            stat_hp=${stats[0]}, stat_atk=${stats[1]}, stat_def=${stats[2]},
            stat_spa=${stats[3]}, stat_spd=${stats[4]}, stat_spe=${stats[5]}
        WHERE id=${id};"
}

# db_update_encounter_friendship <id> <friendship>
# Update the friendship column of encounter <id>.
function db_update_encounter_friendship {
    local id="$1"
    local friendship="$2"
    if ! _db_assert_int "${id}" id; then
        return 2
    fi
    if ! _db_assert_int "${friendship}" friendship; then
        return 2
    fi
    db_exec "UPDATE encounters SET friendship=${friendship} WHERE id=${id};"
}

# db_update_encounter_evolved <id> <species> <dex_id> <sprite> <stats_str> <variety>
# Update species/variety/dex_id/sprite_path + the 6 stat columns after an
# evolution. stats_str is "hp atk def spa spd spe" (space-separated integers).
# variety is the evolved form; defaults to species when empty.
function db_update_encounter_evolved {
    local id="$1"
    local species="$2"
    local dex_id="$3"
    local sprite="$4"
    local stats_str="$5"
    local variety="${6:-$species}"
    if ! _db_assert_int "${id}" id; then
        return 2
    fi
    if ! _db_assert_int "${dex_id}" dex_id; then
        return 2
    fi
    local -a stats
    read -ra stats <<<"${stats_str}"
    local s
    for s in "${stats[@]}"; do
        if ! _db_assert_int "${s}" stat; then
            return 2
        fi
    done
    local sprite_sql="NULL"
    if [[ -n "${sprite}" ]]; then
        sprite_sql="'${sprite//\'/\'\'}'"
    fi
    db_exec "UPDATE encounters
        SET species='${species//\'/\'\'}', variety='${variety//\'/\'\'}', dex_id=${dex_id}, sprite_path=${sprite_sql},
            stat_hp=${stats[0]}, stat_atk=${stats[1]}, stat_def=${stats[2]},
            stat_spa=${stats[3]}, stat_spd=${stats[4]}, stat_spe=${stats[5]}
        WHERE id=${id};"
}

# db_consume_one_item_drop <item> [now=epoch]
# Soft-delete the oldest unconsumed item_drops row for <item> by setting
# consumed_at=<now>. The row is preserved for history. Prints "1" if a row was
# consumed, "0" if none was available.
function db_consume_one_item_drop {
    local item="$1"
    local now="${2-}"
    if [[ -z "${now}" ]]; then
        now="$(date +%s)"
    fi
    if ! _db_assert_int "${now}" now; then
        return 2
    fi
    local id
    id="$(db_query "SELECT id FROM item_drops
                    WHERE item='${item//\'/\'\'}' AND consumed_at IS NULL
                    ORDER BY encountered_at ASC, id ASC LIMIT 1;")"
    if [[ -z "${id}" ]]; then
        printf '0'
        return 0
    fi
    db_exec "UPDATE item_drops SET consumed_at=${now} WHERE id=${id};"
    printf '1'
}

# db_state_set <key> <value>
# Upsert a daemon_state key/value pair.
function db_state_set {
    local key="$1"
    local value="$2"
    db_exec "INSERT INTO daemon_state(key, value) VALUES ('${key//\'/\'\'}', '${value//\'/\'\'}')
             ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

# db_state_get <key>
# Print the value stored for a daemon_state key.
function db_state_get {
    local key="$1"
    db_query "SELECT value FROM daemon_state WHERE key='${key//\'/\'\'}';"
}

# db_log_event <kind> <summary>
# Append one event_log row stamped with the current epoch.
function db_log_event {
    local kind="$1"
    local summary="$2"
    db_exec "INSERT INTO event_log(ts, kind, summary)
             VALUES ($(date +%s), '${kind//\'/\'\'}', '${summary//\'/\'\'}');"
}

# db_log_prune <retention_seconds>
# Delete event_log rows older than <retention_seconds> before now.
function db_log_prune {
    local retention="$1"
    if ! _db_assert_int "${retention}" retention; then
        return 2
    fi
    db_exec "DELETE FROM event_log WHERE ts < ($(date +%s) - ${retention});"
}

# db_list_log [--kind K] [--limit N] [--reverse] <retention_seconds>
# List event_log rows within the retention window as JSON. Oldest-first by
# default; --reverse flips to newest-first. <retention_seconds> is required.
function db_list_log {
    local -a where=()
    local -i limit=0
    local -i reverse=0
    local retention=""
    while (($# > 0)); do
        case "$1" in
            --kind)
                where+=("kind='${2//\'/\'\'}'")
                shift 2
                ;;
            --limit)
                if ! _db_assert_int "$2" --limit; then
                    return 2
                fi
                limit="$2"
                shift 2
                ;;
            --reverse)
                reverse=1
                shift
                ;;
            -*)
                printf 'db_list_log: unknown flag: %s\n' "$1" >&2
                return 2
                ;;
            *)
                retention="$1"
                shift
                ;;
        esac
    done
    if ! _db_assert_int "${retention}" retention; then
        return 2
    fi
    where+=("ts >= ($(date +%s) - ${retention})")
    local dir="ASC"
    if ((reverse)); then
        dir="DESC"
    fi
    local joined
    printf -v joined '%s AND ' "${where[@]}"
    local sql="SELECT id, ts, kind, summary FROM event_log WHERE ${joined% AND } ORDER BY ts ${dir}, id ${dir}"
    if ((limit > 0)); then
        sql+=" LIMIT ${limit}"
    fi
    sql+=";"
    db_query_json "${sql}"
}
