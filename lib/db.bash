#!/usr/bin/env bash
# lib/db.bash — sqlite wrappers.
# Requires:
#   POKIDLE_DB_PATH      path to sqlite db file
#   POKIDLE_REPO_ROOT    repo root (for locating schema.sql)

: "${POKIDLE_DB_PATH:?POKIDLE_DB_PATH must be set before sourcing lib/db.bash}"

# Guard: numeric args must be integer to avoid SQL injection via raw interpolation.
_db_assert_int() {
    [[ "$1" =~ ^-?[0-9]+$ ]] || {
        printf 'db: %s: expected integer, got %q\n' "${2:-arg}" "$1" >&2
        return 2
    }
}

db_init() {
    local schema="${POKIDLE_REPO_ROOT}/schema.sql"
    if [[ ! -f "$schema" ]]; then
        printf 'db_init: schema.sql not found at %s\n' "$schema" >&2
        return 1
    fi
    mkdir -p -- "$(dirname -- "$POKIDLE_DB_PATH")"
    sqlite3 "$POKIDLE_DB_PATH" < "$schema"
}

db_exec() {
    sqlite3 "$POKIDLE_DB_PATH" "$@"
}

db_query() {
    sqlite3 -separator $'\t' "$POKIDLE_DB_PATH" "$@"
}

db_query_json() {
    sqlite3 -json "$POKIDLE_DB_PATH" "$@"
}

db_open_biome_session() {
    local biome="$1" started_at="$2"
    _db_assert_int "$started_at" started_at || return $?
    db_query "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('${biome//\'/\'\'}', $started_at); SELECT last_insert_rowid();"
}

db_close_biome_session() {
    local id="$1" ended_at="$2"
    _db_assert_int "$id" id || return $?
    _db_assert_int "$ended_at" ended_at || return $?
    db_exec "UPDATE biome_sessions SET ended_at=$ended_at WHERE id=$id;"
}

# Prints "id\tbiome_id\tstarted_at" of the active session, or empty.
db_active_biome_session() {
    db_query "SELECT id, biome_id, started_at FROM biome_sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1;"
}

# Insert an encounter described by a JSON object on stdin or argv[1].
# Required keys: session_id, encountered_at, species, dex_id, level, nature,
# ability, is_hidden_ability, gender, shiny, held_berry, ivs[6], evs[6],
# stats[6], moves[], sprite_path.
db_insert_encounter() {
    local enc="$1" jq_filter sql
    # jq filter emits SQL literals: NULL for null, single-quoted with doubled
    # internal quotes for strings (SQL standard), bare for numbers.
    read -r -d '' jq_filter <<'JQ' || true
def sqstr: if . == null then "NULL" else "'" + (tostring | gsub("'"; "''")) + "'" end;
"INSERT INTO encounters (
    session_id, encountered_at, species, dex_id, level,
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
    sql="$(jq -r "$jq_filter" <<< "$enc")"
    db_exec "$sql"
}

# List encounters as JSON. Supports filters parsed from argv:
#   --shiny --since YYYY-MM-DD --until YYYY-MM-DD --biome <id>
#   --species <name> --nature <name> --min-iv-total N --limit N
db_list_encounters() {
    local where=() limit=50 ts
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --shiny)         where+=("e.shiny=1"); shift ;;
            --since)         ts="$(date -d "$2" +%s)" || return 2
                             where+=("e.encountered_at >= $ts"); shift 2 ;;
            --until)         ts="$(date -d "$2" +%s)" || return 2
                             where+=("e.encountered_at <= $ts"); shift 2 ;;
            --biome)         where+=("s.biome_id='${2//\'/\'\'}'"); shift 2 ;;
            --species)       where+=("e.species LIKE '%${2//\'/\'\'}%'"); shift 2 ;;
            --nature)        where+=("e.nature='${2//\'/\'\'}'"); shift 2 ;;
            --min-iv-total)  _db_assert_int "$2" --min-iv-total || return $?
                             where+=("(e.iv_hp+e.iv_atk+e.iv_def+e.iv_spa+e.iv_spd+e.iv_spe) >= $2"); shift 2 ;;
            --limit)         _db_assert_int "$2" --limit || return $?
                             limit="$2"; shift 2 ;;
            *)               printf 'db_list_encounters: unknown flag: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    local sql="SELECT e.*, s.biome_id FROM encounters e JOIN biome_sessions s ON s.id=e.session_id"
    if (( ${#where[@]} )); then
        local joined
        printf -v joined '%s AND ' "${where[@]}"
        sql+=" WHERE ${joined% AND }"
    fi
    sql+=" ORDER BY e.encountered_at DESC LIMIT $limit;"
    db_query_json "$sql"
}

db_insert_item_drop() {
    local session_id="$1" ts="$2" item="$3" sprite="$4"
    _db_assert_int "$session_id" session_id || return $?
    _db_assert_int "$ts" ts || return $?
    local sprite_sql="NULL"
    [[ -n "$sprite" ]] && sprite_sql="'${sprite//\'/\'\'}'"
    db_exec "INSERT INTO item_drops(session_id, encountered_at, item, sprite_path)
             VALUES ($session_id, $ts, '${item//\'/\'\'}', $sprite_sql);"
}

db_list_item_drops() {
    local where=() limit=50 ts
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since)  ts="$(date -d "$2" +%s)" || return 2
                      where+=("d.encountered_at >= $ts"); shift 2 ;;
            --until)  ts="$(date -d "$2" +%s)" || return 2
                      where+=("d.encountered_at <= $ts"); shift 2 ;;
            --biome)  where+=("s.biome_id='${2//\'/\'\'}'"); shift 2 ;;
            --item)   where+=("d.item LIKE '%${2//\'/\'\'}%'"); shift 2 ;;
            --limit)  _db_assert_int "$2" --limit || return $?
                      limit="$2"; shift 2 ;;
            *)        printf 'db_list_item_drops: unknown flag: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    local sql="SELECT d.*, s.biome_id FROM item_drops d JOIN biome_sessions s ON s.id=d.session_id"
    if (( ${#where[@]} )); then
        local joined
        printf -v joined '%s AND ' "${where[@]}"
        sql+=" WHERE ${joined% AND }"
    fi
    sql+=" ORDER BY d.encountered_at DESC LIMIT $limit;"
    db_query_json "$sql"
}

# Returns JSON array of encounter rows whose encountered_at falls within
# the current local ISO week (Mon 00:00 — Sun 23:59:59).
db_list_current_week_encounters() {
    local mon_ts sun_ts dow
    # %u: 1=Mon..7=Sun. Compute Monday at 00:00 local.
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    sun_ts=$((mon_ts + 7*86400 - 1))
    db_query_json "
        SELECT * FROM encounters
        WHERE encountered_at BETWEEN $mon_ts AND $sun_ts
        ORDER BY id ASC;"
}

# Update level + stat_* columns of encounter <id>.
# stats_str is "hp atk def spa spd spe" (space-separated integers).
db_update_encounter_level_stats() {
    local id="$1" level="$2" stats_str="$3"
    _db_assert_int "$id" id || return $?
    _db_assert_int "$level" level || return $?
    local stats=($stats_str)
    local s
    for s in "${stats[@]}"; do
        _db_assert_int "$s" stat || return $?
    done
    db_exec "UPDATE encounters
        SET level=$level,
            stat_hp=${stats[0]}, stat_atk=${stats[1]}, stat_def=${stats[2]},
            stat_spa=${stats[3]}, stat_spd=${stats[4]}, stat_spe=${stats[5]}
        WHERE id=$id;"
}

db_update_encounter_friendship() {
    local id="$1" friendship="$2"
    _db_assert_int "$id" id || return $?
    _db_assert_int "$friendship" friendship || return $?
    db_exec "UPDATE encounters SET friendship=$friendship WHERE id=$id;"
}

# Update species/dex_id/sprite_path + 6 stat columns after evolution.
db_update_encounter_evolved() {
    local id="$1" species="$2" dex_id="$3" sprite="$4" stats_str="$5"
    _db_assert_int "$id" id || return $?
    _db_assert_int "$dex_id" dex_id || return $?
    local stats=($stats_str)
    local s
    for s in "${stats[@]}"; do
        _db_assert_int "$s" stat || return $?
    done
    local sprite_sql="NULL"
    [[ -n "$sprite" ]] && sprite_sql="'${sprite//\'/\'\'}'"
    db_exec "UPDATE encounters
        SET species='${species//\'/\'\'}', dex_id=$dex_id, sprite_path=$sprite_sql,
            stat_hp=${stats[0]}, stat_atk=${stats[1]}, stat_def=${stats[2]},
            stat_spa=${stats[3]}, stat_spd=${stats[4]}, stat_spe=${stats[5]}
        WHERE id=$id;"
}

# Delete the oldest item_drops row whose item equals <name>. Prints count
# of deleted rows (0 or 1).
db_delete_one_item_drop() {
    local item="$1"
    local id
    id="$(db_query "SELECT id FROM item_drops
                    WHERE item='${item//\'/\'\'}'
                    ORDER BY id ASC LIMIT 1;")"
    if [[ -z "$id" ]]; then
        printf '0'
        return 0
    fi
    db_exec "DELETE FROM item_drops WHERE id=$id;"
    printf '1'
}

db_state_set() {
    local key="$1" value="$2"
    db_exec "INSERT INTO daemon_state(key, value) VALUES ('${key//\'/\'\'}', '${value//\'/\'\'}')
             ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

db_state_get() {
    local key="$1"
    db_query "SELECT value FROM daemon_state WHERE key='${key//\'/\'\'}';"
}
