#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/pcache.$$"
    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/pcfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR" "$POKIDLE_CACHE_DIR" "$POKEAPI_CACHE_DIR"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKEAPI_CACHE_DIR POKIDLE_CONFIG_DIR

    # Pre-cache pokeapi responses for stats recompute (rattata).
    mkdir -p "$POKEAPI_CACHE_DIR/pokemon" "$POKEAPI_CACHE_DIR/nature"
    cat > "$POKEAPI_CACHE_DIR/pokemon/rattata.json" <<'EOF'
{"id":19,"sprites":{"front_default":"","front_shiny":""},
 "stats":[
   {"base_stat":30,"stat":{"name":"hp"}},
   {"base_stat":56,"stat":{"name":"attack"}},
   {"base_stat":35,"stat":{"name":"defense"}},
   {"base_stat":25,"stat":{"name":"special-attack"}},
   {"base_stat":35,"stat":{"name":"special-defense"}},
   {"base_stat":72,"stat":{"name":"speed"}}]}
EOF
    cat > "$POKEAPI_CACHE_DIR/nature/hardy.json" <<'EOF'
{"increased_stat":null,"decreased_stat":null}
EOF
}

teardown() {
    rm -rf "$POKIDLE_CACHE_DIR" "$POKEAPI_CACHE_DIR" "$POKIDLE_CONFIG_DIR"
}

_seed_rattata_in_current_week() {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local mon_ts dow
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    local now=$((mon_ts + 86400))   # tuesday
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json,
            friendship, iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,
            stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe)
            VALUES (1, $now, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]', 70,
                10,10,10,10,10,10, 0,0,0,0,0,0,
                17, 13, 11, 9, 10, 14);"
}

@test "pokidle tick level --json bumps eligible low-level candidate" {
    _seed_rattata_in_current_week
    local i hit=0 out
    for i in {1..40}; do
        out="$("$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null)"
        [ -n "$out" ] || continue
        local n
        n="$(jq '.leveled | length' <<< "$out")"
        if (( n > 0 )); then
            hit=1
            local from to
            from="$(jq -r '.leveled[0].from' <<< "$out")"
            to="$(jq -r '.leveled[0].to' <<< "$out")"
            [ "$from" = "5" ]
            [ "$to" = "6" ]
            break
        fi
    done
    [ "$hit" = "1" ]
}

@test "pokidle tick level --no-output: prints nothing (no 'no candidates' line)" {
    _seed_rattata_in_current_week
    run "$REPO_ROOT/pokidle" tick level --dry-run --no-notify --no-output
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pokidle tick level --no-images: accepted no-op, still prints" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    run "$REPO_ROOT/pokidle" tick level --dry-run --no-notify --no-images
    [ "$status" -eq 0 ]
    [[ "$output" == *"no candidates leveled"* ]]
}

@test "pokidle tick level --no-dry-run logs a level event" {
    _seed_rattata_in_current_week
    local i
    for i in {1..60}; do
        "$REPO_ROOT/pokidle" tick level --no-dry-run --no-notify --json 2>/dev/null > /dev/null
        local c
        c="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM event_log WHERE kind='level';")"
        if (( c > 0 )); then break; fi
    done
    run sqlite3 "$POKIDLE_DB_PATH" "SELECT kind || '|' || summary FROM event_log WHERE kind='level' LIMIT 1;"
    [ "$status" -eq 0 ]
    [[ "$output" == "level|rattata #1  "* ]]
}

@test "pokidle tick level --dry-run logs nothing" {
    _seed_rattata_in_current_week
    local i
    for i in {1..40}; do
        "$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null > /dev/null
    done
    local c
    c="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM event_log;")"
    [ "$c" = "0" ]
}

@test "pokidle log prints one line per event; --kind and --json filter" {
    _seed_rattata_in_current_week
    sqlite3 "$POKIDLE_DB_PATH" "INSERT INTO event_log(ts, kind, summary) VALUES
        ($(date +%s), 'encounter', 'Pikachu Lv.12 M [forest]'),
        ($(date +%s), 'item', 'oran-berry [forest]');"
    run "$REPO_ROOT/pokidle" log 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pikachu Lv.12 M [forest]"* ]]
    [[ "$output" == *"oran-berry [forest]"* ]]
    [ "$(printf '%s\n' "$output" | grep -c .)" = "2" ]
    run "$REPO_ROOT/pokidle" log --kind item 2>/dev/null
    [[ "$output" == *"oran-berry"* ]]
    [[ "$output" != *"Pikachu"* ]]
    run "$REPO_ROOT/pokidle" log --json 2>/dev/null
    [ "$(jq 'length' <<< "$output")" = "2" ]
}

@test "pokidle tick level: dry-run does not write to DB" {
    _seed_rattata_in_current_week
    "$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null > /dev/null
    local lvl
    lvl="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT level FROM encounters WHERE id=1;")"
    [ "$lvl" = "5" ]
}

@test "pokidle tick level: level 100 candidate skipped" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local mon_ts dow
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    local now=$((mon_ts + 86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, $now, 'rattata', 19, 100, 'hardy', 'guts', 0, 'M', 0, '[]', 70);"
    local i out leveled_max=0
    for i in {1..30}; do
        out="$("$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.leveled | length' <<< "$out")"
        (( n > leveled_max )) && leveled_max=$n
    done
    [ "$leveled_max" = "0" ]
}

@test "pokidle tick level: encounter older than current week is not touched" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local dow mon_ts old_ts
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    old_ts=$((mon_ts - 7*86400))   # last week
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $old_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json,
            friendship, iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,
            stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe)
            VALUES (1, $old_ts, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]', 70,
                10,10,10,10,10,10, 0,0,0,0,0,0, 17, 13, 11, 9, 10, 14);"

    local i out leveled_max=0
    for i in {1..30}; do
        out="$("$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.leveled | length' <<< "$out")"
        (( n > leveled_max )) && leveled_max=$n
    done
    [ "$leveled_max" = "0" ]
    local lvl
    lvl="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT level FROM encounters WHERE id=1;")"
    [ "$lvl" = "5" ]
}

@test "pokidle tick level: chance scales down with level" {
    # Level-90 rattata in the current week.
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local dow mon_ts now
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    now=$((mon_ts + 86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json,
            friendship, iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe,
            stat_hp, stat_atk, stat_def, stat_spa, stat_spd, stat_spe)
            VALUES (1, $now, 'rattata', 19, 90, 'hardy', 'guts', 0, 'M', 0, '[]', 70,
                10,10,10,10,10,10, 0,0,0,0,0,0, 17, 13, 11, 9, 10, 14);"

    # floor 0, base 9: chance at lvl 90 = 0 + 9*(100-90)/100 = 0 (int) -> never levels,
    # proving the level term drives effective chance down at high level.
    local i out leveled_max=0
    for i in {1..40}; do
        out="$(POKIDLE_LEVEL_CHANCE=9 POKIDLE_LEVEL_CHANCE_MIN=0 \
               "$REPO_ROOT/pokidle" tick level --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.leveled | length' <<< "$out")"
        (( n > leveled_max )) && leveled_max=$n
    done
    [ "$leveled_max" = "0" ]
}
