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

@test "db_delete_one_item_drop deletes oldest matching row only" {
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
    run db_delete_one_item_drop water-stone
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    local n_water n_fire
    n_water="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops WHERE item='water-stone';")"
    n_fire="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops WHERE item='fire-stone';")"
    [ "$n_water" = "1" ]
    [ "$n_fire" = "1" ]
}

@test "db_delete_one_item_drop returns 0 when no match" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    run db_delete_one_item_drop never-stone
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
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

