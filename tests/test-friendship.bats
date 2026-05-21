#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/pcfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    cp "$REPO_ROOT/config/biomes.json" "$POKIDLE_CONFIG_DIR/biomes.json"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT POKIDLE_CONFIG_DIR
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
}

teardown() { rm -rf "$POKIDLE_CONFIG_DIR"; }

_seed_friendly() {
    local fr="${1:-70}"
    local mon_ts dow
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    local now=$((mon_ts + 86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, $now, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]', $fr);"
}

@test "pokidle tick friendship --json bumps friendship by 5 when roll < 50" {
    _seed_friendly 70
    local i hit=0 out
    for i in {1..30}; do
        out="$("$REPO_ROOT/pokidle" tick friendship --dry-run --no-notify --json 2>/dev/null)"
        local n
        n="$(jq '.befriended | length' <<< "$out")"
        if (( n > 0 )); then
            hit=1
            [ "$(jq -r '.befriended[0].from' <<< "$out")" = "70" ]
            [ "$(jq -r '.befriended[0].to' <<< "$out")" = "75" ]
            break
        fi
    done
    [ "$hit" = "1" ]
}

@test "pokidle tick friendship: caps at 255" {
    _seed_friendly 254
    local i hit=0 out
    for i in {1..30}; do
        out="$("$REPO_ROOT/pokidle" tick friendship --no-dry-run --no-notify --json 2>/dev/null)"
        local n
        n="$(jq '.befriended | length' <<< "$out")"
        if (( n > 0 )); then
            hit=1
            [ "$(jq -r '.befriended[0].to' <<< "$out")" = "255" ]
            break
        fi
    done
    [ "$hit" = "1" ]
    local v
    v="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT friendship FROM encounters WHERE id=1;")"
    [ "$v" = "255" ]
}

@test "pokidle tick friendship: at 255 skipped" {
    _seed_friendly 255
    local i out leveled_max=0
    for i in {1..20}; do
        out="$("$REPO_ROOT/pokidle" tick friendship --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.befriended | length' <<< "$out")"
        (( n > leveled_max )) && leveled_max=$n
    done
    [ "$leveled_max" = "0" ]
}

@test "pokidle tick friendship: encounter older than current week is not touched" {
    local dow mon_ts old_ts
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    old_ts=$((mon_ts - 7*86400))
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('plain', $old_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship)
            VALUES (1, $old_ts, 'rattata', 19, 5, 'hardy', 'guts', 0, 'M', 0, '[]', 70);"

    local i out hit_max=0
    for i in {1..30}; do
        out="$("$REPO_ROOT/pokidle" tick friendship --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.befriended | length' <<< "$out")"
        (( n > hit_max )) && hit_max=$n
    done
    [ "$hit_max" = "0" ]
    local fr
    fr="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT friendship FROM encounters WHERE id=1;")"
    [ "$fr" = "70" ]
}
