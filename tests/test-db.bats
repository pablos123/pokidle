#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    export POKIDLE_DB_PATH
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    load_lib db
}

teardown() {
    rm -f "$POKIDLE_DB_PATH"
}

@test "db_init applies schema and creates all tables" {
    db_init
    run sqlite3 "$POKIDLE_DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"biome_sessions"* ]]
    [[ "$output" == *"daemon_state"* ]]
    [[ "$output" == *"encounters"* ]]
    [[ "$output" == *"item_drops"* ]]
}

@test "db_init is idempotent" {
    db_init
    db_init
    run sqlite3 "$POKIDLE_DB_PATH" \
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    [ "$status" -eq 0 ]
    [[ "$output" == *biome_sessions* ]]
    [[ "$output" == *daemon_state* ]]
    [[ "$output" == *encounters* ]]
    [[ "$output" == *item_drops* ]]
}

@test "db_exec inserts and db_query selects rows" {
    db_init
    db_exec "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    run db_query "SELECT biome_id FROM biome_sessions;"
    [ "$status" -eq 0 ]
    [ "$output" = "cave" ]
}

@test "db_query_json returns valid JSON array" {
    db_init
    db_exec "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    db_exec "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('forest', 1700001000);"
    run db_query_json "SELECT biome_id, started_at FROM biome_sessions ORDER BY id;"
    [ "$status" -eq 0 ]
    # Validate it parses as JSON and has 2 elements
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "2" ]
}

@test "db_open_biome_session inserts and returns session id" {
    db_init
    local id
    id="$(db_open_biome_session 'cave' 1700000000)"
    [[ "$id" =~ ^[0-9]+$ ]]
    run db_query "SELECT biome_id FROM biome_sessions WHERE id=$id;"
    [ "$output" = "cave" ]
}

@test "db_close_biome_session sets ended_at" {
    db_init
    local id
    id="$(db_open_biome_session 'cave' 1700000000)"
    db_close_biome_session "$id" 1700003600
    run db_query "SELECT ended_at FROM biome_sessions WHERE id=$id;"
    [ "$output" = "1700003600" ]
}

@test "db_active_biome_session returns the open one" {
    db_init
    local id
    id="$(db_open_biome_session 'cave' 1700000000)"
    run db_active_biome_session
    [ "$status" -eq 0 ]
    [[ "$output" == *"cave"* ]]
    [[ "$output" == *"$id"* ]]
}

@test "db_active_biome_session returns empty when none open" {
    db_init
    local id
    id="$(db_open_biome_session 'cave' 1700000000)"
    db_close_biome_session "$id" 1700003600
    run db_active_biome_session
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "db_insert_encounter persists all columns" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"

    local enc='{
        "session_id": '"$sid"',
        "encountered_at": 1700000123,
        "species": "zubat",
        "dex_id": 41,
        "level": 7,
        "nature": "adamant",
        "ability": "inner-focus",
        "is_hidden_ability": 0,
        "gender": "M",
        "shiny": 0,
        "held_berry": null,
        "friendship": 70,
        "ivs": [10,20,30,15,5,25],
        "evs": [0,0,0,0,0,0],
        "stats": [22,18,15,12,15,30],
        "moves": ["leech-life","supersonic","astonish","bite"],
        "sprite_path": "/tmp/zubat.png"
    }'
    db_insert_encounter "$enc"

    run db_query "SELECT species, level, nature, moves_json FROM encounters;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"zubat"* ]]
    [[ "$output" == *"adamant"* ]]
    [[ "$output" == *"leech-life"* ]]
}

@test "db_init adds the variety column to encounters" {
    db_init
    run sqlite3 "$POKIDLE_DB_PATH" "PRAGMA table_info(encounters);"
    [ "$status" -eq 0 ]
    [[ "$output" == *"variety"* ]]
}

@test "db_init adds variety to a pre-existing variety-less encounters table" {
    # Simulate an old DB created before the variety column existed.
    sqlite3 "$POKIDLE_DB_PATH" "CREATE TABLE encounters (
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER, encountered_at INTEGER,
        species TEXT, dex_id INTEGER, level INTEGER, nature TEXT, ability TEXT,
        is_hidden_ability INTEGER, gender TEXT, shiny INTEGER, held_berry TEXT,
        friendship INTEGER, iv_hp INTEGER, iv_atk INTEGER, iv_def INTEGER, iv_spa INTEGER,
        iv_spd INTEGER, iv_spe INTEGER, ev_hp INTEGER, ev_atk INTEGER, ev_def INTEGER,
        ev_spa INTEGER, ev_spd INTEGER, ev_spe INTEGER, stat_hp INTEGER, stat_atk INTEGER,
        stat_def INTEGER, stat_spa INTEGER, stat_spd INTEGER, stat_spe INTEGER,
        moves_json TEXT, sprite_path TEXT);"
    db_init
    run sqlite3 "$POKIDLE_DB_PATH" "PRAGMA table_info(encounters);"
    [[ "$output" == *"variety"* ]]
}

@test "db_insert_encounter persists the variety (regional form) field" {
    db_init
    local sid
    sid="$(db_open_biome_session 'crystal-cavern' 1700000000)"
    local enc='{"session_id":'"$sid"',"encountered_at":1700000123,"species":"meowth","variety":"meowth-galar","dex_id":10161,"level":7,"nature":"adamant","ability":"pickup","is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"friendship":70,"ivs":[10,20,30,15,5,25],"evs":[0,0,0,0,0,0],"stats":[22,18,15,12,15,30],"moves":["scratch"],"sprite_path":null}'
    db_insert_encounter "$enc"
    run sqlite3 "$POKIDLE_DB_PATH" "SELECT species, variety FROM encounters WHERE id=1;"
    [ "$status" -eq 0 ]
    [ "$output" = "meowth|meowth-galar" ]
}

@test "db_insert_encounter defaults variety to species when omitted" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"
    local enc='{"session_id":'"$sid"',"encountered_at":1700000123,"species":"zubat","dex_id":41,"level":7,"nature":"adamant","ability":"inner-focus","is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"friendship":70,"ivs":[10,20,30,15,5,25],"evs":[0,0,0,0,0,0],"stats":[22,18,15,12,15,30],"moves":["bite"],"sprite_path":null}'
    db_insert_encounter "$enc"
    run sqlite3 "$POKIDLE_DB_PATH" "SELECT variety FROM encounters WHERE id=1;"
    [ "$output" = "zubat" ]
}

@test "db_list_encounters supports filters" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"

    db_insert_encounter '{"session_id":'"$sid"',"encountered_at":1700000100,"species":"zubat","dex_id":41,"level":7,"nature":"adamant","ability":"inner-focus","is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"friendship":70,"ivs":[1,2,3,4,5,6],"evs":[0,0,0,0,0,0],"stats":[10,10,10,10,10,10],"moves":["bite"],"sprite_path":null}'
    db_insert_encounter '{"session_id":'"$sid"',"encountered_at":1700000200,"species":"pidgey","dex_id":16,"level":3,"nature":"jolly","ability":"keen-eye","is_hidden_ability":0,"gender":"F","shiny":1,"held_berry":"oran","friendship":70,"ivs":[31,31,31,31,31,31],"evs":[0,0,0,0,0,0],"stats":[20,20,20,20,20,20],"moves":["tackle"],"sprite_path":null}'

    run db_list_encounters --shiny --limit 10
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "1" ]
    [[ "$output" == *"pidgey"* ]]
}

@test "db_insert_item_drop persists" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"
    db_insert_item_drop "$sid" 1700000300 "everstone" "/tmp/es.png"
    run db_query "SELECT item FROM item_drops;"
    [ "$output" = "everstone" ]
}

@test "db_list_item_drops returns json" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"
    db_insert_item_drop "$sid" 1700000300 "everstone" "/tmp/es.png"
    db_insert_item_drop "$sid" 1700000400 "soothe-bell" "/tmp/sb.png"
    run db_list_item_drops --limit 10
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "2" ]
}

@test "db_state_set / db_state_get round-trip" {
    db_init
    db_state_set "last_pokemon_tick_target" "1700009999"
    run db_state_get "last_pokemon_tick_target"
    [ "$output" = "1700009999" ]
}

@test "db_state_get returns empty for missing key" {
    db_init
    run db_state_get "no_such_key"
    [ -z "$output" ]
}

@test "db_state_set overwrites existing value" {
    db_init
    db_state_set "k" "a"
    db_state_set "k" "b"
    run db_state_get "k"
    [ "$output" = "b" ]
}

@test "db_insert_encounter handles single-quote in string fields" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"
    local enc
    enc="$(jq -n --argjson sid "$sid" '{
        session_id: $sid, encountered_at: 1700000100,
        species: "o'\''ranberry-mon", dex_id: 1, level: 1,
        nature: "ada'\''mant", ability: "inner-focus", is_hidden_ability: 0,
        gender: "M", shiny: 0, held_berry: "king'\''s-rock-berry",
        friendship: 70,
        ivs: [1,2,3,4,5,6], evs: [0,0,0,0,0,0],
        stats: [10,10,10,10,10,10],
        moves: ["bi'\''te"], sprite_path: null
    }')"
    db_insert_encounter "$enc"
    run db_query "SELECT species, nature, held_berry, moves_json FROM encounters;"
    [ "$status" -eq 0 ]
    [[ "$output" == *"o'ranberry-mon"* ]]
    [[ "$output" == *"ada'mant"* ]]
    [[ "$output" == *"king's-rock-berry"* ]]
    [[ "$output" == *"bi'te"* ]]
}

@test "db_insert_item_drop handles single-quote in item name" {
    db_init
    local sid
    sid="$(db_open_biome_session 'cave' 1700000000)"
    db_insert_item_drop "$sid" 1700000300 "king's-rock" "/tmp/x.png"
    run db_query "SELECT item FROM item_drops;"
    [ "$output" = "king's-rock" ]
}

@test "db_list_encounters --limit rejects non-integer (SQL-injection guard)" {
    db_init
    run db_list_encounters --limit "1; DROP TABLE biome_sessions"
    [ "$status" -ne 0 ]
    run db_query "SELECT name FROM sqlite_master WHERE type='table' AND name='biome_sessions';"
    [ "$output" = "biome_sessions" ]
}

@test "db_list_encounters --min-iv-total rejects non-integer" {
    db_init
    run db_list_encounters --min-iv-total "abc"
    [ "$status" -ne 0 ]
}

@test "db_list_encounters rejects unknown flag" {
    db_init
    run db_list_encounters --bogus 1
    [ "$status" -ne 0 ]
}

@test "db_list_item_drops --limit rejects non-integer" {
    db_init
    run db_list_item_drops --limit "1; DROP TABLE item_drops"
    [ "$status" -ne 0 ]
    run db_query "SELECT name FROM sqlite_master WHERE type='table' AND name='item_drops';"
    [ "$output" = "item_drops" ]
}

@test "db_list_item_drops rejects unknown flag" {
    db_init
    run db_list_item_drops --bogus 1
    [ "$status" -ne 0 ]
}

@test "db_open_biome_session rejects non-integer started_at" {
    db_init
    run db_open_biome_session "cave" "not-an-int"
    [ "$status" -ne 0 ]
}

@test "db_close_biome_session rejects non-integer args" {
    db_init
    run db_close_biome_session "abc" 1700003600
    [ "$status" -ne 0 ]
    run db_close_biome_session 1 "abc"
    [ "$status" -ne 0 ]
}

@test "db_insert_item_drop rejects non-integer numeric args" {
    db_init
    run db_insert_item_drop "abc" 1700000300 "everstone" ""
    [ "$status" -ne 0 ]
}

@test "db_init creates encounters with friendship column (default 70)" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    local cols
    cols="$(sqlite3 "$POKIDLE_DB_PATH" "PRAGMA table_info(encounters);" | grep '|friendship|')"
    [[ -n "$cols" ]]
    [[ "$cols" == *"|70|"* ]]
}

@test "db_insert_encounter persists friendship value" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    local enc
    enc='{"session_id":1,"encountered_at":1700000000,"species":"eevee","dex_id":133,"level":5,"nature":"hardy","ability":"run-away","is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"friendship":50,"ivs":[10,10,10,10,10,10],"evs":[0,0,0,0,0,0],"stats":[20,11,11,11,11,11],"moves":["tackle"],"sprite_path":""}'
    db_insert_encounter "$enc"
    local fr
    fr="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT friendship FROM encounters WHERE id=1;")"
    [ "$fr" = "50" ]
}

@test "db_list_current_week_encounters returns rows in current ISO week only" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init

    # Compute Monday 00:00 local of this week using %u-based offset.
    local mon_ts now dow
    now="$(date +%s)"
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    local last_week=$((mon_ts - 7*86400))
    local this_week=$((mon_ts + 3*86400))

    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, $last_week, 'rattata', 19, 3, 'hardy', 'guts', 0, 'M', 0, '[]', 70),
                   (1, $this_week, 'pidgey',  16, 4, 'hardy', 'keen-eye', 0, 'M', 0, '[]', 70);
    "
    run db_list_current_week_encounters
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].species' <<< "$output")" = "pidgey" ]
}

@test "db_update_encounter_level_stats updates level + 6 stat columns" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json,
            friendship, stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe)
            VALUES (1, 1700000000, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]',
                70, 20, 11, 10, 8, 9, 14);"
    run db_update_encounter_level_stats 1 6 "21 12 11 9 10 15"
    [ "$status" -eq 0 ]
    local row
    row="$(sqlite3 "$POKIDLE_DB_PATH" \
        "SELECT level||','||stat_hp||','||stat_atk||','||stat_def||','||stat_spa||','||stat_spd||','||stat_spe FROM encounters WHERE id=1;")"
    [ "$row" = "6,21,12,11,9,10,15" ]
}

@test "db_update_encounter_friendship caps at 255" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, 1700000000, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]', 70);"
    db_update_encounter_friendship 1 75
    local v
    v="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT friendship FROM encounters WHERE id=1;")"
    [ "$v" = "75" ]
}

@test "db_update_encounter_evolved updates species, dex_id, sprite, stats" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json,
            friendship, sprite_path)
            VALUES (1, 1700000000, 'eevee', 133, 20, 'hardy', 'run-away', 0, 'M', 0, '[]',
                70, 'old.png');"
    db_update_encounter_evolved 1 vaporeon 134 "new.png" "60 30 30 50 50 30"
    local row
    row="$(sqlite3 "$POKIDLE_DB_PATH" \
        "SELECT species||','||dex_id||','||sprite_path||','||stat_hp||','||stat_atk||','||stat_def||','||stat_spa||','||stat_spd||','||stat_spe FROM encounters WHERE id=1;")"
    [ "$row" = "vaporeon,134,new.png,60,30,30,50,50,30" ]
}

@test "db_consume_one_item_drop marks oldest available, keeps the row" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 100, 'water-stone'),
            (1, 200, 'water-stone'),
            (1, 300, 'fire-stone');"
    run db_consume_one_item_drop water-stone 999
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    local total; total="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops;")"
    [ "$total" = "3" ]
    local c100; c100="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT consumed_at FROM item_drops WHERE encountered_at=100;")"
    [ "$c100" = "999" ]
    local c200; c200="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT IFNULL(consumed_at,'') FROM item_drops WHERE encountered_at=200;")"
    [ "$c200" = "" ]
}

@test "db_consume_one_item_drop returns 0 when no available match" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item, consumed_at) VALUES
            (1, 100, 'water-stone', 555);"
    run db_consume_one_item_drop water-stone 999
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "db_consume_one_item_drop defaults now when omitted (nounset-safe)" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 100, 'water-stone');"
    # evolution_apply calls this with one arg under the daemon's `set -u`; the
    # missing optional <now> must not crash with "$2: unbound variable".
    set -u
    run db_consume_one_item_drop water-stone
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    local consumed; consumed="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT consumed_at FROM item_drops WHERE encountered_at=100;")"
    [ -n "$consumed" ]
}

@test "db_list_item_drops hides consumed by default, --include-consumed shows" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item, consumed_at) VALUES
            (1, 100, 'water-stone', NULL),
            (1, 200, 'fire-stone', 555);"
    run db_list_item_drops
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].item' <<< "$output")" = "water-stone" ]
    run db_list_item_drops --include-consumed
    [ "$(jq 'length' <<< "$output")" = "2" ]
}

@test "db_list_current_week_encounters Sunday edge case: today's row included" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init

    # Compute current Monday using the fixed formula.
    local dow mon_ts today
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    today="$(date +%s)"

    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, $today, 'pidgey', 16, 5, 'hardy', 'keen-eye', 0, 'M', 0, '[]', 70);"
    run db_list_current_week_encounters
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].species' <<< "$output")" = "pidgey" ]
}

seed_sort_encounters() {
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id,
            level, nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES
            (1, 1700000100, 'zubat',  'zubat',        41, 30, 'hardy', 'guts', 0, 'M', 0, '[]', 70),
            (1, 1700000200, 'abra',   'abra',          63, 10, 'hardy', 'guts', 0, 'M', 0, '[]', 70),
            (1, 1700000300, 'meowth', 'meowth-galar',  52, 20, 'hardy', 'guts', 0, 'M', 0, '[]', 70);"
}

@test "db_list_encounters default sort is oldest-first by date" {
    seed_sort_encounters
    run db_list_encounters --limit 10
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.[].species] | join(",")' <<< "$output")" = "zubat,abra,meowth" ]
}

@test "db_list_encounters --reverse flips date to newest-first" {
    seed_sort_encounters
    run db_list_encounters --limit 10 --reverse
    [ "$(jq -r '[.[].species] | join(",")' <<< "$output")" = "meowth,abra,zubat" ]
}

@test "db_list_encounters --sort name orders by displayed form (A-Z), --reverse flips" {
    seed_sort_encounters
    run db_list_encounters --limit 10 --sort name
    [ "$(jq -r '[.[].variety] | join(",")' <<< "$output")" = "abra,meowth-galar,zubat" ]
    run db_list_encounters --limit 10 --sort name --reverse
    [ "$(jq -r '[.[].variety] | join(",")' <<< "$output")" = "zubat,meowth-galar,abra" ]
}

@test "db_list_encounters --sort level orders low-to-high, --reverse high-to-low" {
    seed_sort_encounters
    run db_list_encounters --limit 10 --sort level
    [ "$(jq -r '[.[].level] | join(",")' <<< "$output")" = "10,20,30" ]
    run db_list_encounters --limit 10 --sort level --reverse
    [ "$(jq -r '[.[].level] | join(",")' <<< "$output")" = "30,20,10" ]
}

@test "db_list_encounters --limit selects newest-N window then sorts" {
    seed_sort_encounters
    # Newest 2 by date are meowth(300) and abra(200); sorted by name -> abra, meowth.
    run db_list_encounters --limit 2 --sort name
    [ "$(jq 'length' <<< "$output")" = "2" ]
    [ "$(jq -r '[.[].variety] | join(",")' <<< "$output")" = "abra,meowth-galar" ]
}

@test "db_list_encounters rejects invalid --sort key" {
    db_init
    run db_list_encounters --sort bogus
    [ "$status" -ne 0 ]
}

@test "db_list_encounters no longer accepts --newest-first" {
    db_init
    run db_list_encounters --newest-first
    [ "$status" -ne 0 ]
}

@test "db_list_item_drops --sort name orders alphabetically, --reverse flips" {
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 100, 'water-stone'),
            (1, 200, 'everstone'),
            (1, 300, 'oran-berry');"
    run db_list_item_drops --sort name
    [ "$(jq -r '[.[].item] | join(",")' <<< "$output")" = "everstone,oran-berry,water-stone" ]
    run db_list_item_drops --sort name --reverse
    [ "$(jq -r '[.[].item] | join(",")' <<< "$output")" = "water-stone,oran-berry,everstone" ]
}

@test "db_list_item_drops --sort level is accepted and falls back to date" {
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 100, 'water-stone'),
            (1, 200, 'everstone');"
    run db_list_item_drops --sort level
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.[].item] | join(",")' <<< "$output")" = "water-stone,everstone" ]
}

@test "db_list_item_drops rejects an unknown --sort key" {
    db_init
    run db_list_item_drops --sort bogus
    [ "$status" -ne 0 ]
}

@test "db_list_item_drops no longer accepts --newest-first" {
    db_init
    run db_list_item_drops --newest-first
    [ "$status" -ne 0 ]
}

@test "db_log_event inserts and db_list_log returns it" {
    db_init
    db_log_event encounter "Pikachu Lv.12 M [forest]"
    run db_list_log 604800
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].kind' <<< "$output")" = "encounter" ]
    [ "$(jq -r '.[0].summary' <<< "$output")" = "Pikachu Lv.12 M [forest]" ]
}

@test "db_log_event escapes single quotes in the summary" {
    db_init
    db_log_event item "king's-rock [cave]"
    run db_list_log 604800
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].summary' <<< "$output")" = "king's-rock [cave]" ]
}

@test "db_log_prune deletes rows older than the window, keeps newer" {
    db_init
    local now old recent
    now="$(date +%s)"
    old=$((now - 8 * 86400))
    recent=$((now - 1 * 86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO event_log(ts, kind, summary) VALUES
            ($old, 'item', 'stale'),
            ($recent, 'item', 'fresh');"
    db_log_prune $((7 * 86400))
    run sqlite3 "$POKIDLE_DB_PATH" "SELECT summary FROM event_log ORDER BY ts;"
    [ "$output" = "fresh" ]
}

@test "db_list_log read filter hides out-of-window rows even if unpruned" {
    db_init
    local now old recent
    now="$(date +%s)"
    old=$((now - 8 * 86400))
    recent=$((now - 1 * 86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO event_log(ts, kind, summary) VALUES
            ($old, 'item', 'stale'),
            ($recent, 'item', 'fresh');"
    run db_list_log $((7 * 86400))
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].summary' <<< "$output")" = "fresh" ]
}

@test "db_list_log --kind filters, --reverse and --limit apply" {
    db_init
    local now
    now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO event_log(ts, kind, summary) VALUES
            ($((now - 300)), 'encounter', 'first'),
            ($((now - 200)), 'item',      'an-item'),
            ($((now - 100)), 'encounter', 'second');"
    run db_list_log --kind encounter 604800
    [ "$(jq 'length' <<< "$output")" = "2" ]
    [ "$(jq -r '[.[].summary] | join(",")' <<< "$output")" = "first,second" ]
    run db_list_log --reverse 604800
    [ "$(jq -r '.[0].summary' <<< "$output")" = "second" ]
    run db_list_log --limit 1 604800
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].summary' <<< "$output")" = "first" ]
}

@test "db_list_log requires an integer retention" {
    db_init
    run db_list_log
    [ "$status" -ne 0 ]
    run db_list_log notanint
    [ "$status" -ne 0 ]
}

@test "db_init adds consumed_at column to a pre-existing item_drops" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    # Simulate an old DB whose item_drops predates consumed_at.
    sqlite3 "$POKIDLE_DB_PATH" "CREATE TABLE item_drops(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER, encountered_at INTEGER, item TEXT, sprite_path TEXT);"
    db_init
    run _db_column_exists item_drops consumed_at
    [ "$status" -eq 0 ]
    # Idempotent: a second init is a no-op and does not error.
    run db_init
    [ "$status" -eq 0 ]
    run _db_column_exists item_drops consumed_at
    [ "$status" -eq 0 ]
}

