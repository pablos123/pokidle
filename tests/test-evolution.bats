#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_REPO_ROOT
    source "$REPO_ROOT/lib/evolution.bash"
}

@test "evolution_check_hard_filters: gender mismatch -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"gender":1}'   # 1 = female-only per PokeAPI canonical; encounter is M -> mismatch
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: gender match -> pass" {
    local enc='{"gender":"F","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"gender":1}'   # 1 = female-only per PokeAPI canonical; encounter is F -> match
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_check_hard_filters: min_level below threshold -> fail" {
    local enc='{"gender":"M","level":15,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"min_level":20}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: min_happiness below -> fail" {
    local enc='{"gender":"M","level":40,"friendship":150,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"min_happiness":220}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: time_of_day mismatch -> fail" {
    EVOLUTION_TIME_OF_DAY=day
    export EVOLUTION_TIME_OF_DAY
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"time_of_day":"night"}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: known_move not in list -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":["tackle","growl"]}'
    local evo='{"known_move":{"name":"mimic"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: known_move in list -> pass" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":["mimic"]}'
    local evo='{"known_move":{"name":"mimic"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_check_hard_filters: relative_physical_stats atk>def required, atk<=def -> fail" {
    # encounter.stats indices: 0=hp, 1=atk, 2=def, 3=spa, 4=spd, 5=spe
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,15,20,20,20,20],"moves":[]}'
    local evo='{"relative_physical_stats":1}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_path_kind: use-item with item -> item kind" {
    local evo='{"item":{"name":"water-stone"},"trigger":{"name":"use-item"}}'
    [ "$(evolution_path_kind "$evo")" = "item" ]
}

@test "evolution_path_kind: held_item -> item kind" {
    local evo='{"held_item":{"name":"kings-rock"}}'
    [ "$(evolution_path_kind "$evo")" = "item" ]
}

@test "evolution_path_kind: bare level evo -> synthetic" {
    local evo='{"min_level":16,"trigger":{"name":"level-up"}}'
    [ "$(evolution_path_kind "$evo")" = "synthetic" ]
}

@test "evolution_path_item_name extracts name from item or held_item" {
    [ "$(evolution_path_item_name '{"item":{"name":"water-stone"}}')" = "water-stone" ]
    [ "$(evolution_path_item_name '{"held_item":{"name":"kings-rock"}}')" = "kings-rock" ]
    [ "$(evolution_path_item_name '{"min_level":16}')" = "" ]
}

@test "evolution_enumerate_viable_paths: synthetic only when no item" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    local enc='{"gender":"M","level":20,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local stages='[{"species":"linoone","evolution_details":[{"min_level":20,"trigger":{"name":"level-up"}}]}]'
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].species' <<< "$output")" = "linoone" ]
    [ "$(jq -r '.[0].kind' <<< "$output")" = "synthetic" ]
}

@test "evolution_enumerate_viable_paths: item path requires item in DB" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);"
    local enc='{"gender":"M","level":20,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local stages='[{"species":"vaporeon","evolution_details":[
        {"item":{"name":"water-stone"},"trigger":{"name":"use-item"}}]}]'
    # No item in DB → no viable path.
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$(jq 'length' <<< "$output")" = "0" ]

    # Add item.
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES (1, 1, 'water-stone');"
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].kind' <<< "$output")" = "item" ]
    [ "$(jq -r '.[0].item' <<< "$output")" = "water-stone" ]
}

@test "evolution_enumerate_viable_paths: hard filter blocks evo" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    # Female-only path: encounter is M → blocked. (PokeAPI canonical: 1=female)
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local stages='[{"species":"gardevoir","evolution_details":[{"min_level":30,"gender":1}]}]'
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$(jq 'length' <<< "$output")" = "0" ]
}

@test "evolution_apply: synthetic path updates encounter species/dex/sprite/stats" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    load_lib encounter
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'zigzagoon', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    pokeapi_get() {
        case "$1" in
            pokemon/linoone)
                printf '%s' '{"id":264,"sprites":{"front_default":"linoone.png","front_shiny":""},
                  "stats":[
                    {"base_stat":78,"stat":{"name":"hp"}},
                    {"base_stat":70,"stat":{"name":"attack"}},
                    {"base_stat":61,"stat":{"name":"defense"}},
                    {"base_stat":50,"stat":{"name":"special-attack"}},
                    {"base_stat":61,"stat":{"name":"special-defense"}},
                    {"base_stat":100,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"linoone","kind":"synthetic","evo":{"min_level":20}}'
    run evolution_apply 1 "$path"
    [ "$status" -eq 0 ]
    # sprite_local is "" because the stub URL "linoone.png" is not a real URL;
    # curl fails and sprite_local is cleared. Verify species/dex_id only.
    local row
    row="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT species||','||dex_id FROM encounters WHERE id=1;")"
    [ "$row" = "linoone,264" ]
}

@test "evolution_apply: refreshes the variety to the evolved form" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    load_lib encounter
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'zigzagoon', 'zigzagoon', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    pokeapi_get() {
        case "$1" in
            pokemon/linoone)
                printf '%s' '{"id":264,"sprites":{"front_default":"linoone.png","front_shiny":""},
                  "stats":[
                    {"base_stat":78,"stat":{"name":"hp"}},
                    {"base_stat":70,"stat":{"name":"attack"}},
                    {"base_stat":61,"stat":{"name":"defense"}},
                    {"base_stat":50,"stat":{"name":"special-attack"}},
                    {"base_stat":61,"stat":{"name":"special-defense"}},
                    {"base_stat":100,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"linoone","kind":"synthetic","evo":{"min_level":20}}'
    run evolution_apply 1 "$path"
    [ "$status" -eq 0 ]
    local variety
    variety="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT variety FROM encounters WHERE id=1;")"
    [ "$variety" = "linoone" ]
}

@test "evolution_apply: caches the evolved sprite under the variety, not the bare species" {
    # A form evolution (e.g. linoone-galar) has its own sprite; caching it under
    # the bare species would collide with the base form's PNG and show the wrong
    # sprite. The stored sprite_path must be keyed by the resolved variety.
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/ecache.$$"
    mkdir -p "$POKIDLE_CACHE_DIR"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR
    load_lib db
    load_lib encounter
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'zigzagoon', 'zigzagoon-galar', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    # Pin the (otherwise random) variety pick to the regional form.
    encounter_pick_variety() { printf 'linoone-galar'; }
    export -f encounter_pick_variety
    # Make the sprite download succeed by creating the --output target.
    curl() {
        local a out="" next=""
        for a in "$@"; do
            if [[ "$next" == "1" ]]; then out="$a"; next=""; fi
            [[ "$a" == "--output" ]] && next=1
        done
        [[ -n "$out" ]] && printf 'PNG' >"$out"
        return 0
    }
    export -f curl

    pokeapi_get() {
        case "$1" in
            pokemon/linoone-galar)
                printf '%s' '{"id":264,"sprites":{"front_default":"http://x/lg.png","front_shiny":""},
                  "stats":[
                    {"base_stat":78,"stat":{"name":"hp"}},
                    {"base_stat":70,"stat":{"name":"attack"}},
                    {"base_stat":61,"stat":{"name":"defense"}},
                    {"base_stat":50,"stat":{"name":"special-attack"}},
                    {"base_stat":61,"stat":{"name":"special-defense"}},
                    {"base_stat":100,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"linoone","kind":"synthetic","evo":{"min_level":20}}'
    run evolution_apply 1 "$path"
    [ "$status" -eq 0 ]
    [ "$output" = "linoone-galar" ]
    local sp
    sp="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT sprite_path FROM encounters WHERE id=1;")"
    [[ "$sp" == *"/sprites/linoone-galar.png" ]]
}

@test "evolution_apply: prints the resolved result variety on stdout" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    load_lib encounter
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'zigzagoon', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    pokeapi_get() {
        case "$1" in
            pokemon/linoone)
                printf '%s' '{"id":264,"sprites":{"front_default":"linoone.png","front_shiny":""},
                  "stats":[
                    {"base_stat":78,"stat":{"name":"hp"}},
                    {"base_stat":70,"stat":{"name":"attack"}},
                    {"base_stat":61,"stat":{"name":"defense"}},
                    {"base_stat":50,"stat":{"name":"special-attack"}},
                    {"base_stat":61,"stat":{"name":"special-defense"}},
                    {"base_stat":100,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"linoone","kind":"synthetic","evo":{"min_level":20}}'
    local out
    out="$(evolution_apply 1 "$path" 2>/dev/null)"
    [ "$out" = "linoone" ]
}

@test "pokidle tick evolve --json: synthetic candidate evolves on tier-pass" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/pcache.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/pcfg.$$"
    mkdir -p "$POKIDLE_CACHE_DIR/pools" "$POKIDLE_CONFIG_DIR"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_CONFIG_DIR

    cat > "$POKIDLE_CACHE_DIR/pools/orchard.json" <<'EOF'
{"biome":"orchard","tiers":{
  "common":[{"species":"zigzagoon","varieties":["zigzagoon"],"min":3,"max":5}],
  "uncommon":[],"rare":[],"very_rare":[]
}}
EOF

    local mon_ts now dow
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    now=$((mon_ts + 86400))
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, $now, 'zigzagoon', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    POKIDLE_POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKIDLE_POKEAPI_CACHE_DIR
    mkdir -p "$POKIDLE_POKEAPI_CACHE_DIR/pokemon-species" "$POKIDLE_POKEAPI_CACHE_DIR/pokemon"
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/pokemon-species/zigzagoon.json" <<'EOF'
{"evolution_chain":{"url":"https://x/evolution-chain/64/"},"base_happiness":70}
EOF
    mkdir -p "$POKIDLE_POKEAPI_CACHE_DIR/evolution-chain"
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/evolution-chain/64.json" <<'EOF'
{"chain":{"species":{"name":"zigzagoon"},"evolution_details":[],
  "evolves_to":[{"species":{"name":"linoone"},"evolution_details":[
    {"min_level":20,"trigger":{"name":"level-up"}}],"evolves_to":[]}]}}
EOF
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/pokemon/linoone.json" <<'EOF'
{"id":264,"sprites":{"front_default":"lin.png","front_shiny":""},
  "stats":[
    {"base_stat":78,"stat":{"name":"hp"}},
    {"base_stat":70,"stat":{"name":"attack"}},
    {"base_stat":61,"stat":{"name":"defense"}},
    {"base_stat":50,"stat":{"name":"special-attack"}},
    {"base_stat":61,"stat":{"name":"special-defense"}},
    {"base_stat":100,"stat":{"name":"speed"}}]}
EOF
    mkdir -p "$POKIDLE_POKEAPI_CACHE_DIR/nature"
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/nature/hardy.json" <<'EOF'
{"increased_stat":null,"decreased_stat":null}
EOF

    local i hit=0 out
    for i in {1..50}; do
        out="$("$REPO_ROOT/pokidle" tick evolve --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.evolved | length' <<< "$out")"
        if (( n > 0 )); then
            hit=1
            [ "$(jq -r '.evolved[0].from' <<< "$out")" = "zigzagoon" ]
            [ "$(jq -r '.evolved[0].to'   <<< "$out")" = "linoone" ]
            break
        fi
    done
    [ "$hit" = "1" ]
}

@test "pokidle tick evolve --json: a form encounter evolves and 'from' shows its variety" {
    # Full-random evolution: a form/regional encounter (variety != species) is
    # NOT skipped — it evolves via the bare-species chain — and the notification
    # 'from' must show the encountered form, not the bare species.
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/pcache.$$"
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/pcfg.$$"
    mkdir -p "$POKIDLE_CACHE_DIR/pools" "$POKIDLE_CONFIG_DIR"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT POKIDLE_CACHE_DIR POKIDLE_CONFIG_DIR

    cat > "$POKIDLE_CACHE_DIR/pools/orchard.json" <<'EOF'
{"biome":"orchard","tiers":{
  "common":[{"species":"zigzagoon","varieties":["zigzagoon-galar"],"min":3,"max":5}],
  "uncommon":[],"rare":[],"very_rare":[]
}}
EOF

    local mon_ts now dow
    dow="$(date +%u)"
    mon_ts="$(date -d "$(( dow - 1 )) days ago $(date +%F) 00:00:00" +%s 2>/dev/null \
              || date -v-$(( dow - 1 ))d -v0H -v0M -v0S +%s)"
    now=$((mon_ts + 86400))
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', $mon_ts);
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, $now, 'zigzagoon', 'zigzagoon-galar', 263, 20, 'hardy', 'pickup', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    POKIDLE_POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKIDLE_POKEAPI_CACHE_DIR
    mkdir -p "$POKIDLE_POKEAPI_CACHE_DIR/pokemon-species" "$POKIDLE_POKEAPI_CACHE_DIR/pokemon" \
        "$POKIDLE_POKEAPI_CACHE_DIR/evolution-chain" "$POKIDLE_POKEAPI_CACHE_DIR/nature"
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/pokemon-species/zigzagoon.json" <<'EOF'
{"evolution_chain":{"url":"https://x/evolution-chain/64/"},"base_happiness":70}
EOF
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/evolution-chain/64.json" <<'EOF'
{"chain":{"species":{"name":"zigzagoon"},"evolution_details":[],
  "evolves_to":[{"species":{"name":"linoone"},"evolution_details":[
    {"min_level":20,"trigger":{"name":"level-up"}}],"evolves_to":[]}]}}
EOF
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/pokemon/linoone.json" <<'EOF'
{"id":264,"sprites":{"front_default":"lin.png","front_shiny":""},
  "stats":[
    {"base_stat":78,"stat":{"name":"hp"}},
    {"base_stat":70,"stat":{"name":"attack"}},
    {"base_stat":61,"stat":{"name":"defense"}},
    {"base_stat":50,"stat":{"name":"special-attack"}},
    {"base_stat":61,"stat":{"name":"special-defense"}},
    {"base_stat":100,"stat":{"name":"speed"}}]}
EOF
    cat > "$POKIDLE_POKEAPI_CACHE_DIR/nature/hardy.json" <<'EOF'
{"increased_stat":null,"decreased_stat":null}
EOF

    local i hit=0 out
    for i in {1..50}; do
        out="$("$REPO_ROOT/pokidle" tick evolve --dry-run --no-notify --json 2>/dev/null)"
        local n="$(jq '.evolved | length' <<< "$out")"
        if (( n > 0 )); then
            hit=1
            [ "$(jq -r '.evolved[0].from' <<< "$out")" = "zigzagoon-galar" ]
            [ "$(jq -r '.evolved[0].to'   <<< "$out")" = "linoone" ]
            break
        fi
    done
    [ "$hit" = "1" ]
}

@test "evolution_apply: reconciles ability and moves for the new species" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    load_lib encounter
    load_lib showdown
    seed_showdown
    db_init
    # Stale ability (pickup) and a stale move (tackle) illegal for corviknight;
    # peck is legal and must be kept.
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'rookidee', 821, 20, 'hardy', 'pickup', 0, 'M', 0,
                '[\"tackle\",\"peck\"]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);"

    pokeapi_get() {
        case "$1" in
            pokemon/corviknight)
                printf '%s' '{"id":823,"sprites":{"front_default":"corv.png","front_shiny":""},
                  "stats":[
                    {"base_stat":98,"stat":{"name":"hp"}},
                    {"base_stat":87,"stat":{"name":"attack"}},
                    {"base_stat":105,"stat":{"name":"defense"}},
                    {"base_stat":53,"stat":{"name":"special-attack"}},
                    {"base_stat":85,"stat":{"name":"special-defense"}},
                    {"base_stat":67,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"corviknight","kind":"synthetic","evo":{"min_level":38}}'
    run evolution_apply 1 "$path"
    [ "$status" -eq 0 ]
    local ability moves
    ability="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT ability FROM encounters WHERE id=1;")"
    moves="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT moves_json FROM encounters WHERE id=1;")"
    # Ability re-rolled into corviknight's legal pool.
    [[ "$ability" == "pressure" || "$ability" == "unnerve" || "$ability" == "mirror-armor" ]]
    # peck kept; tackle dropped; every move legal for corviknight.
    [ "$(jq -r 'index("peck") != null' <<< "$moves")" = "true" ]
    [ "$(jq -r 'index("tackle") == null' <<< "$moves")" = "true" ]
    local legal='["brave-bird","double-edge","peck"]'
    [ "$(jq --argjson L "$legal" 'all(.[]; . as $m | $L | index($m) != null)' <<< "$moves")" = "true" ]
}

@test "evolution_apply: item path consumes one item_drops row" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    load_lib encounter
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('orchard', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, moves_json, friendship,
            iv_hp, iv_atk, iv_def, iv_spa, iv_spd, iv_spe,
            ev_hp, ev_atk, ev_def, ev_spa, ev_spd, ev_spe)
            VALUES (1, 1700000000, 'eevee', 133, 20, 'hardy', 'run-away', 0, 'M', 0, '[]',
                70, 10,10,10,10,10,10, 0,0,0,0,0,0);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 1, 'water-stone'),
            (1, 2, 'water-stone');"

    pokeapi_get() {
        case "$1" in
            pokemon/vaporeon)
                printf '%s' '{"id":134,"sprites":{"front_default":"vap.png","front_shiny":""},
                  "stats":[
                    {"base_stat":130,"stat":{"name":"hp"}},
                    {"base_stat":65,"stat":{"name":"attack"}},
                    {"base_stat":60,"stat":{"name":"defense"}},
                    {"base_stat":110,"stat":{"name":"special-attack"}},
                    {"base_stat":95,"stat":{"name":"special-defense"}},
                    {"base_stat":65,"stat":{"name":"speed"}}]}'
                ;;
            nature/hardy) printf '{"increased_stat":null,"decreased_stat":null}' ;;
            *) return 1 ;;
        esac
    }
    export -f pokeapi_get

    local path='{"species":"vaporeon","kind":"item","item":"water-stone","evo":{}}'
    evolution_apply 1 "$path"
    local total consumed
    total="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops WHERE item='water-stone';")"
    consumed="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops WHERE item='water-stone' AND consumed_at IS NOT NULL;")"
    [ "$total" = "2" ]
    [ "$consumed" = "1" ]
}

@test "evolution_enumerate_viable_paths: branching evos with multiple stones in DB" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 1, 'water-stone'),
            (1, 2, 'thunder-stone'),
            (1, 3, 'fire-stone');"
    local enc='{"gender":"M","level":20,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    # Three eevee stone-evos all viable since all stones present.
    local stages='[
      {"species":"vaporeon","evolution_details":[
        {"item":{"name":"water-stone"},"trigger":{"name":"use-item"}}]},
      {"species":"jolteon","evolution_details":[
        {"item":{"name":"thunder-stone"},"trigger":{"name":"use-item"}}]},
      {"species":"flareon","evolution_details":[
        {"item":{"name":"fire-stone"},"trigger":{"name":"use-item"}}]}
    ]'
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "3" ]
    # Each tier path is item kind, with the right item name attached.
    [ "$(jq -r '.[] | select(.species=="vaporeon") | .item' <<< "$output")" = "water-stone" ]
    [ "$(jq -r '.[] | select(.species=="jolteon") | .item' <<< "$output")" = "thunder-stone" ]
    [ "$(jq -r '.[] | select(.species=="flareon") | .item' <<< "$output")" = "fire-stone" ]
    [ "$(jq -r '[.[] | .kind] | unique[]' <<< "$output")" = "item" ]
}

@test "evolution_enumerate_viable_paths: missing stones reduce viable list" {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    load_lib db
    db_init
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 1, 'fire-stone');"
    local enc='{"gender":"M","level":20,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local stages='[
      {"species":"vaporeon","evolution_details":[
        {"item":{"name":"water-stone"},"trigger":{"name":"use-item"}}]},
      {"species":"flareon","evolution_details":[
        {"item":{"name":"fire-stone"},"trigger":{"name":"use-item"}}]}
    ]'
    run evolution_enumerate_viable_paths "$enc" "$stages"
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" = "1" ]
    [ "$(jq -r '.[0].species' <<< "$output")" = "flareon" ]
}

@test "evolution_check_hard_filters: location requirement -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"location":{"name":"mount-lanakila"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: trade_species requirement -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"trade_species":{"name":"karrablast"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: min_affection requirement -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"min_affection":2}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: turn_upside_down requirement -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"turn_upside_down":true}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: no unmodeled fields -> still pass" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"min_level":30,"turn_upside_down":false,"needs_overworld_rain":false}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_check_hard_filters: trade trigger without item -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"trigger":{"name":"trade"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: trade trigger with held_item -> pass" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"trigger":{"name":"trade"},"held_item":{"name":"metal-coat"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_check_hard_filters: shed trigger -> fail" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"trigger":{"name":"shed"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -ne 0 ]
}

@test "evolution_check_hard_filters: use-item trigger -> pass" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"trigger":{"name":"use-item"},"item":{"name":"ice-stone"}}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_check_hard_filters: no trigger field -> pass" {
    local enc='{"gender":"M","level":40,"friendship":70,"stats":[20,30,30,20,20,20],"moves":[]}'
    local evo='{"min_level":30}'
    run evolution_check_hard_filters "$enc" "$evo"
    [ "$status" -eq 0 ]
}

@test "evolution_reconcile_ability: legal ability is kept" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    run evolution_reconcile_ability "corviknight" "pressure"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<< "$output")" = "pressure" ]
    [ "$(jq -r '.is_hidden' <<< "$output")" = "false" ]
}

@test "evolution_reconcile_ability: kept ability recomputes is_hidden from new species" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    # mirror-armor is the hidden ability of corviknight; stored flag said 0.
    run evolution_reconcile_ability "corviknight" "mirror-armor"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<< "$output")" = "mirror-armor" ]
    [ "$(jq -r '.is_hidden' <<< "$output")" = "true" ]
}

@test "evolution_reconcile_ability: illegal ability is re-rolled from new species pool" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    run evolution_reconcile_ability "corviknight" "overgrow"
    [ "$status" -eq 0 ]
    local name
    name="$(jq -r '.name' <<< "$output")"
    [[ "$name" == "pressure" || "$name" == "unnerve" || "$name" == "mirror-armor" ]]
}

@test "evolution_reconcile_ability: showdown unavailable -> re-rolls via legal roller" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    showdown_legal_abilities() { return 1; }
    encounter_roll_ability_legal() { printf '{"name":"sentinel","is_hidden":false}'; }
    export -f showdown_legal_abilities encounter_roll_ability_legal
    run evolution_reconcile_ability "corviknight" "pressure"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<< "$output")" = "sentinel" ]
}

@test "evolution_reconcile_moves: keeps legal moves, drops illegal, refills to pool cap" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    # corviknight legal pool: brave-bird, double-edge, peck.
    local old='["peck","tackle","growl","brave-bird"]'
    run evolution_reconcile_moves "corviknight" 50 "$old" "corviknight"
    [ "$status" -eq 0 ]
    # peck + brave-bird kept; tackle/growl dropped; double-edge refills. Pool of 3
    # caps the result at 3.
    [ "$(jq 'length' <<< "$output")" = "3" ]
    [ "$(jq -r 'index("peck")     != null' <<< "$output")" = "true" ]
    [ "$(jq -r 'index("brave-bird")!= null' <<< "$output")" = "true" ]
    [ "$(jq -r 'index("double-edge")!=null' <<< "$output")" = "true" ]
    [ "$(jq -r 'index("tackle")   == null' <<< "$output")" = "true" ]
    # kept moves come first, in original order.
    [ "$(jq -r '.[0]' <<< "$output")" = "peck" ]
    [ "$(jq -r '.[1]' <<< "$output")" = "brave-bird" ]
}

@test "evolution_reconcile_moves: no duplicate moves when refilling" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    local old='["peck"]'
    run evolution_reconcile_moves "corviknight" 50 "$old" "corviknight"
    [ "$status" -eq 0 ]
    [ "$(jq 'length == (unique | length)' <<< "$output")" = "true" ]
    [ "$(jq -r 'index("peck") != null' <<< "$output")" = "true" ]
}

@test "evolution_reconcile_moves: showdown unavailable -> re-rolls via legal roller" {
    load_lib encounter
    load_lib showdown
    seed_showdown
    showdown_legal_moves() { return 1; }
    encounter_roll_moves_legal() { printf '["sentinel-move"]'; }
    export -f showdown_legal_moves encounter_roll_moves_legal
    run evolution_reconcile_moves "corviknight" 50 '["peck"]' "corviknight"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0]' <<< "$output")" = "sentinel-move" ]
}

@test "evolution_stage_tier: 3-stage line classifies base/mid/final" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-3.json")"
    [ "$(evolution_stage_tier "$chain" caterpie)" = "3" ]
    [ "$(evolution_stage_tier "$chain" metapod)" = "2" ]
    [ "$(evolution_stage_tier "$chain" butterfree)" = "1" ]
}

@test "evolution_stage_tier: 2-stage branch — both final forms are tier 1, base is tier 3" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-67.json")"
    [ "$(evolution_stage_tier "$chain" eevee)" = "3" ]
    [ "$(evolution_stage_tier "$chain" vaporeon)" = "1" ]
    [ "$(evolution_stage_tier "$chain" jolteon)" = "1" ]
}

@test "evolution_stage_tier: species absent from chain -> tier 3" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-3.json")"
    [ "$(evolution_stage_tier "$chain" pidgey)" = "3" ]
}

@test "evolution_stage_tier: malformed chain JSON -> tier 3, exits 0" {
    run evolution_stage_tier 'not json' foo
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}
