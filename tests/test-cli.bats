#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_DB_PATH="$(make_tmp_db)"
    export POKIDLE_DB_PATH
    POKIDLE_CONFIG_DIR="$BATS_TMPDIR/cfg.$$"
    mkdir -p "$POKIDLE_CONFIG_DIR"
    POKIDLE_CACHE_DIR="$BATS_TMPDIR/cache.$$"
    mkdir -p "$POKIDLE_CACHE_DIR"
    POKIDLE_DATA_DIR="$BATS_TMPDIR/data.$$"
    mkdir -p "$POKIDLE_DATA_DIR"
    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    mkdir -p "$POKEAPI_CACHE_DIR"
    export POKIDLE_CONFIG_DIR POKIDLE_CACHE_DIR POKIDLE_DATA_DIR POKEAPI_CACHE_DIR
    export POKIDLE_NO_NOTIFY=1 POKIDLE_SOUND_DIR="$BATS_TMPDIR/nosound.$$"
    # Seed the Showdown holdable-items cache so export's showdown_item_is_holdable
    # gate works without network access. Must come after env vars are exported.
    seed_showdown
}

teardown() {
    rm -f  "$POKIDLE_DB_PATH"
    rm -rf "$POKIDLE_CONFIG_DIR" "$POKIDLE_CACHE_DIR" "$POKIDLE_DATA_DIR" "$POKEAPI_CACHE_DIR" "$POKIDLE_SHOWDOWN_CACHE_DIR"
}

_seed_schema() { sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"; }

_mk_session() { # $1 biome (default cave), $2 started_at (default now)
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('${1:-cave}', ${2:-$(date +%s)});
         SELECT last_insert_rowid();"
}

_ins_enc() { # $1 sid  $2 species  $3 ts  [$4 shiny=0]  [$5 held_berry|empty=NULL]
    local berry="NULL"; [[ -n "${5:-}" ]] && berry="'$5'"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level, nature,
            ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
            ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
            moves_json, sprite_path)
        VALUES ($1, $3, '$2', 1, 50, 'adamant', 'overgrow', 0, 'M', ${4:-0}, $berry,
            31,31,31,31,31,31, 0,0,0,0,0,0, 100,100,100,100,100,100,
            '[\"tackle\"]', NULL);"
}

_ins_item() { # $1 sid  $2 item  $3 ts
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO item_drops(session_id, encountered_at, item, sprite_path)
         VALUES ($1, $3, '$2', NULL);"
}

@test "export caps team at 6 distinct species" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    local sp
    for sp in bulbasaur charmander squirtle pidgey rattata ekans sandshrew nidoran; do
        _ins_enc "$sid" "$sp" "$now"
    done
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    local n; n="$(grep -c 'Nature' <<< "$output")"
    [ "$n" -eq 6 ]
}

@test "export yields distinct species" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    local i
    for i in 1 2 3 4 5; do _ins_enc "$sid" pidgey "$now"; done
    _ins_enc "$sid" zubat "$now"
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    local n; n="$(grep -c 'Nature' <<< "$output")"
    [ "$n" -eq 2 ]
}

@test "export assigns distinct window items" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" snorlax "$now"
    _ins_enc "$sid" gengar "$now"
    _ins_item "$sid" leftovers "$now"
    _ins_item "$sid" choice-band "$now"
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    [[ "$output" == *"@ Leftovers"* ]]
    [[ "$output" == *"@ Choice Band"* ]]
}

@test "export leaves bare set when items run out" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" snorlax "$now"
    _ins_enc "$sid" gengar "$now"
    _ins_item "$sid" leftovers "$now"
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    local n; n="$(grep -c '@ ' <<< "$output")"
    [ "$n" -eq 1 ]
}

@test "export honors --since/--until window" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now old; now="$(date +%s)"; old=$((now - 60*86400))
    _ins_enc "$sid" snorlax "$now"
    _ins_enc "$sid" gengar "$old"
    local s u
    s="$(date -d "@$((old - 86400))" +%F)"
    u="$(date -d "@$((old + 86400))" +%F)"
    run "$REPO_ROOT/pokidle" export --since "$s" --until "$u"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gengar"* ]]
    [[ "$output" != *"Snorlax"* ]]
}

@test "export honors --min-level/--max-level bounds" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc_lvl() { # $1 sid  $2 species  $3 level  $4 ts
        sqlite3 "$POKIDLE_DB_PATH" "
            INSERT INTO encounters(session_id, encountered_at, species, dex_id, level, nature,
                ability, is_hidden_ability, gender, shiny, held_berry,
                iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
                ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
                stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
                moves_json, sprite_path)
            VALUES ($1, $4, '$2', 1, $3, 'adamant', 'overgrow', 0, 'M', 0, NULL,
                31,31,31,31,31,31, 0,0,0,0,0,0, 100,100,100,100,100,100,
                '[\"tackle\"]', NULL);"
    }
    _ins_enc_lvl "$sid" gengar 60 "$now"
    _ins_enc_lvl "$sid" snorlax 10 "$now"

    run "$REPO_ROOT/pokidle" export --min-level 50
    [ "$status" -eq 0 ]
    [[ "$output" == *Gengar* ]]
    [[ "$output" != *Snorlax* ]]

    run "$REPO_ROOT/pokidle" export --max-level 20
    [ "$status" -eq 0 ]
    [[ "$output" == *Snorlax* ]]
    [[ "$output" != *Gengar* ]]

    run "$REPO_ROOT/pokidle" export --min-level 5 --max-level 100
    [ "$status" -eq 0 ]
    [[ "$output" == *Gengar* ]]
    [[ "$output" == *Snorlax* ]]
}

@test "export rejects non-integer --min-level/--max-level" {
    _seed_schema
    run "$REPO_ROOT/pokidle" export --min-level abc
    [ "$status" -ne 0 ]
}

@test "export honors --shiny filter" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" gengar "$now" 1
    _ins_enc "$sid" pidgey "$now" 0
    run "$REPO_ROOT/pokidle" export --shiny
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gengar"* ]]
    [[ "$output" != *"Pidgey"* ]]
}

@test "pokidle encounters lists the regional form, not the bare species" {
    _seed_schema
    local sid; sid="$(_mk_session crystal-cavern)"
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe, ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe, moves_json, sprite_path)
        VALUES ($sid, $now, 'meowth', 'meowth-galar', 10161, 12, 'adamant', 'pickup', 0, 'M', 0, NULL,
            31,31,31,31,31,31, 0,0,0,0,0,0, 50,50,50,50,50,50, '[\"scratch\"]', NULL);"
    run "$REPO_ROOT/pokidle" encounters --no-images
    [ "$status" -eq 0 ]
    [[ "$output" == *"Lv.12 meowth-galar"* ]]
}

@test "pokidle encounters falls back to species when variety is NULL (legacy rows)" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" zubat "$now"
    run "$REPO_ROOT/pokidle" encounters --no-images
    [ "$status" -eq 0 ]
    [[ "$output" == *"Lv.50 zubat"* ]]
}

@test "export renders the regional form as a Showdown species name" {
    _seed_schema
    local sid; sid="$(_mk_session crystal-cavern)"
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe, ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe, moves_json, sprite_path)
        VALUES ($sid, $now, 'meowth', 'meowth-galar', 10161, 12, 'adamant', 'pickup', 0, 'M', 0, NULL,
            31,31,31,31,31,31, 0,0,0,0,0,0, 50,50,50,50,50,50, '[\"fake-out\"]', NULL);"
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    [[ "$output" == *"Meowth-Galar"* ]]
    [[ "$output" != *"Meowth Galar"* ]]
}

@test "pokidle help exits 0" {
    run "$REPO_ROOT/pokidle" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "pokidle current with no session prints 'no active biome'" {
    run "$REPO_ROOT/pokidle" current
    [ "$status" -eq 0 ]
    [[ "$output" == *"no active biome"* ]]
}

@test "pokidle current bare shows possible counts on the second line + this-session counts" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" pidgey "$now"
    _ins_enc "$sid" zubat "$now"
    _ins_item "$sid" leftovers "$now"
    # Provide a pool file so "Possible encounters" is non-zero.
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<'EOF'
{"biome":"cave","built_at":"2026-05-28T00:00:00Z",
 "tiers":{"common":[{"species":"zubat","min":5,"max":10}],
          "uncommon":[{"species":"machop","min":8,"max":15}],
          "rare":[],"very_rare":[]},
 "items":["rock-incense","bright-powder","covert-cloak","houndoominite"],
 "berries":[]}
EOF
    run "$REPO_ROOT/pokidle" current
    [ "$status" -eq 0 ]
    # Cave bucket: rock-incense bright-powder covert-cloak houndoominite = 4 items,
    # no berries. Pool: 1 common + 1 uncommon = 2 species.
    [[ "$output" == *"Possible encounters: 2   Possible items: 4   Berries: 0"* ]]
    [[ "$output" == *"Encounters: 2   Items: 1"* ]]
    # Types line (cave = rock dark) is line 2, possible-line is line 3.
    line2="$(printf '%s\n' "$output" | sed -n '2p')"
    [[ "$line2" == "Types: rock, dark" ]]
    line3="$(printf '%s\n' "$output" | sed -n '3p')"
    [[ "$line3" == "Possible encounters: 2   Possible items: 4   Berries: 0" ]]
}

@test "pokidle current items lists biome item drop pool alphabetically, berries excluded" {
    _seed_schema
    _mk_session glacier > /dev/null
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/glacier.json" <<'EOF'
{"biome":"glacier","built_at":"2026-05-28T00:00:00Z",
 "tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},
 "items":["never-melt-ice","icicle-plate","icy-rock","icium-z","glalitite","ice-stone"],
 "berries":["yache-berry","aspear-berry"]}
EOF
    run "$REPO_ROOT/pokidle" current items
    [ "$status" -eq 0 ]
    # glacier bucket: showdown items + ice-stone (evo).
    [[ "$output" == *"ice-stone"* ]]
    [[ "$output" == *"never-melt-ice"* ]]
    [[ "$output" == *"glalitite"* ]]
    # Berries are listed by --berries, not here.
    [[ "$output" != *"yache-berry"* ]]
    [[ "$output" != *"aspear-berry"* ]]
    # Items now live in exactly one biome — must not bleed across.
    [[ "$output" != *"charcoal"* ]]             # volcano
    [[ "$output" != *"moon-stone"* ]]           # cathedral
    [[ "$output" != *"pixie-plate"* ]]          # cathedral
    # Alphabetical sort: glalitite precedes never-melt-ice.
    local g n
    g="$(printf '%s\n' "$output" | grep -n '^glalitite$'       | cut -d: -f1)"
    n="$(printf '%s\n' "$output" | grep -n '^never-melt-ice$'  | cut -d: -f1)"
    [ -n "$g" ] && [ -n "$n" ] && [ "$g" -lt "$n" ]
}

@test "pokidle current berries lists only the biome's berry drops alphabetically" {
    _seed_schema
    _mk_session glacier > /dev/null
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/glacier.json" <<'EOF'
{"biome":"glacier","built_at":"2026-05-28T00:00:00Z",
 "tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},
 "items":["never-melt-ice","icicle-plate","icy-rock","icium-z","glalitite","ice-stone"],
 "berries":["yache-berry","aspear-berry"]}
EOF
    run "$REPO_ROOT/pokidle" current berries
    [ "$status" -eq 0 ]
    # glacier berries: aspear-berry, yache-berry.
    [[ "$output" == *"aspear-berry"* ]]
    [[ "$output" == *"yache-berry"* ]]
    # Non-berry items are not listed here.
    [[ "$output" != *"never-melt-ice"* ]]
    [[ "$output" != *"ice-stone"* ]]
    [[ "$output" != *"glalitite"* ]]
    # Alphabetical sort: aspear-berry precedes yache-berry.
    local a y
    a="$(printf '%s\n' "$output" | grep -n '^aspear-berry$' | cut -d: -f1)"
    y="$(printf '%s\n' "$output" | grep -n '^yache-berry$'  | cut -d: -f1)"
    [ -n "$a" ] && [ -n "$y" ] && [ "$a" -lt "$y" ]
}

@test "pokidle current berries on a berry-less biome prints nothing" {
    _seed_schema
    _mk_session cave > /dev/null
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<'EOF'
{"biome":"cave","built_at":"2026-05-28T00:00:00Z",
 "tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},
 "items":["rock-incense","bright-powder","covert-cloak","houndoominite"],
 "berries":[]}
EOF
    run "$REPO_ROOT/pokidle" current berries
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pokidle current encounters lists pool grouped by tier" {
    _seed_schema
    _mk_session cave > /dev/null
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/cave.json" <<'EOF'
{
  "biome": "cave",
  "built_at": "2026-05-28T00:00:00Z",
  "tiers": {
    "common":    [{"species":"zubat","varieties":["zubat"],"min":5,"max":10},{"species":"geodude","varieties":["geodude"],"min":5,"max":12}],
    "uncommon":  [{"species":"machop","varieties":["machop"],"min":8,"max":15}],
    "rare":      [],
    "very_rare": [{"species":"mewtwo","varieties":["mewtwo"],"min":50,"max":60}]
  },
  "berries": []
}
EOF
    run "$REPO_ROOT/pokidle" current encounters
    [ "$status" -eq 0 ]
    [[ "$output" == *"common:"* ]]
    [[ "$output" == *"uncommon:"* ]]
    [[ "$output" == *"very_rare:"* ]]
    ! grep -qx 'rare:' <<< "$output"               # empty tier is skipped
    [[ "$output" == *"geodude (L5-12)"* ]]
    [[ "$output" == *"mewtwo (L50-60)"* ]]
    # Alphabetical within tier: geodude before zubat.
    local g z
    g="$(printf '%s\n' "$output" | grep -n 'geodude' | head -1 | cut -d: -f1)"
    z="$(printf '%s\n' "$output" | grep -n 'zubat'   | head -1 | cut -d: -f1)"
    [ "$g" -lt "$z" ]
}

@test "pokidle current --no-images prints the bare summary unchanged" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    run "$REPO_ROOT/pokidle" current --no-images
    [ "$status" -eq 0 ]
    [[ "$output" == *"Active biome: cave"* ]]
    # No image rendered: summary occupies exactly 6 lines (incl. the Types line).
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
    # Types line is line 2, possible-line is line 3.
    line2="$(printf '%s\n' "$output" | sed -n '2p')"
    [[ "$line2" == Types:* ]]
    line3="$(printf '%s\n' "$output" | sed -n '3p')"
    [[ "$line3" == Possible\ encounters:* ]]
}

@test "pokidle current encounters shows the qualifying form name" {
    _seed_schema
    _mk_session crystal-cavern > /dev/null
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    cat > "$POKIDLE_CACHE_DIR/pools/crystal-cavern.json" <<'EOF'
{
  "biome": "crystal-cavern",
  "built_at": "2026-05-28T00:00:00Z",
  "tiers": {
    "common":    [{"species":"meowth","varieties":["meowth-galar"],"min":5,"max":15}],
    "uncommon":  [{"species":"geodude","varieties":["geodude"],"min":5,"max":12}],
    "rare":      [], "very_rare": []
  },
  "berries": []
}
EOF
    run "$REPO_ROOT/pokidle" current encounters
    [ "$status" -eq 0 ]
    # The steel form is shown, not the bare (Normal-type) species name.
    [[ "$output" == *"meowth-galar (L5-15)"* ]]
    [[ "$output" != *"  meowth (L5-15)"* ]]
    # Bare-form species still render as their plain name.
    [[ "$output" == *"geodude (L5-12)"* ]]
}

@test "pokidle current rejects two kinds at once" {
    run "$REPO_ROOT/pokidle" current items encounters
    [ "$status" -eq 2 ]
    [[ "$output" == *"only one"* ]]
}

@test "pokidle current rejects an unknown kind" {
    run "$REPO_ROOT/pokidle" current bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "pokidle current rejects the removed --items flag" {
    run "$REPO_ROOT/pokidle" current --items
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown flag"* ]]
}

@test "pokidle current rejects the removed --no-image alias" {
    run "$REPO_ROOT/pokidle" current --no-image
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown flag"* ]]
}

@test "pokidle current rejects unknown flag" {
    run "$REPO_ROOT/pokidle" current --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown flag"* ]]
}

@test "pokidle clean pools --yes purges pools dir" {
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    touch "$POKIDLE_CACHE_DIR/pools/cave.json"
    run "$REPO_ROOT/pokidle" clean pools --yes
    [ "$status" -eq 0 ]
    [ ! -f "$POKIDLE_CACHE_DIR/pools/cave.json" ]
}

@test "clean pools: removes the pool cache directory" {
    local tmpcache
    tmpcache="$(mktemp -d)"
    mkdir -p "$tmpcache/pools"
    : > "$tmpcache/pools/forest.json"
    POKIDLE_CACHE_DIR="$tmpcache"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_CACHE_DIR POKIDLE_REPO_ROOT
    run "$REPO_ROOT/pokidle" clean pools --yes
    [ "$status" -eq 0 ]
    [ ! -d "$tmpcache/pools" ]
}

@test "pokidle clean db --yes removes the sqlite db file" {
    local tmpdb
    tmpdb="$(mktemp "$BATS_TMPDIR/pokidle.XXXXXX.db")"
    POKIDLE_DB_PATH="$tmpdb"
    export POKIDLE_DB_PATH
    sqlite3 "$tmpdb" "CREATE TABLE x(a INTEGER);"
    [ -f "$tmpdb" ]
    run "$REPO_ROOT/pokidle" clean db --yes
    [ "$status" -eq 0 ]
    [ ! -f "$tmpdb" ]
}

@test "pokidle clean all --yes wipes pools + db" {
    local tmpcache tmpdb
    tmpcache="$(mktemp -d)"
    tmpdb="$(mktemp "$BATS_TMPDIR/pokidle.XXXXXX.db")"
    mkdir -p "$tmpcache/pools"
    : > "$tmpcache/pools/forest.json"
    sqlite3 "$tmpdb" "CREATE TABLE x(a INTEGER);"
    POKIDLE_CACHE_DIR="$tmpcache"
    POKIDLE_DB_PATH="$tmpdb"
    POKIDLE_REPO_ROOT="$REPO_ROOT"
    export POKIDLE_CACHE_DIR POKIDLE_DB_PATH POKIDLE_REPO_ROOT
    run "$REPO_ROOT/pokidle" clean all --yes
    [ "$status" -eq 0 ]
    [ ! -d "$tmpcache/pools" ]
    [ ! -f "$tmpdb" ]
}

@test "pokidle clean without target prints usage and fails" {
    run "$REPO_ROOT/pokidle" clean
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage:"* ]]
}

# Helper for tick tests: seed POKEAPI_CACHE_DIR with proper layout
# (cache_path = $dir/$endpoint.json, slashes preserved as subdirs).
_seed_pokeapi_cache() {
    local d="$1"
    mkdir -p "$d/pokemon" "$d/pokemon-species" "$d/evolution-chain" "$d/nature" "$d/item" "$d/location-area"
    cp "$FIXTURE_DIR/pokemon-treecko.json"          "$d/pokemon/treecko.json"
    cp "$FIXTURE_DIR/pokemon-species-treecko.json"  "$d/pokemon-species/treecko.json"
    cp "$FIXTURE_DIR/evolution-chain-142.json"      "$d/evolution-chain/142.json"
    # nature?limit=100 → file with literal ?  in name
    cp "$FIXTURE_DIR/nature-limit-100.json"         "$d/nature?limit=100.json"
    local n
    for n in "$FIXTURE_DIR"/nature-*.json; do
        local base="${n##*/}"
        base="${base#nature-}"
        base="${base%.json}"
        [[ "$base" == "limit-100" ]] && continue
        cp "$n" "$d/nature/$base.json"
    done
    local i
    for i in "$FIXTURE_DIR"/item-*.json; do
        local base="${i##*/}"
        base="${base#item-}"
        cp "$i" "$d/item/$base"
    done
}

@test "pokidle encounters emits json with --json" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local sid
    sid="$(sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));
         SELECT last_insert_rowid();")"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level, nature,
            ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
            ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
            moves_json, sprite_path)
        VALUES ($sid, $(date +%s), 'zubat', 41, 7, 'adamant', 'inner-focus', 0, 'M', 0, NULL,
            10,20,30,15,5,25,
            0,0,0,0,0,0,
            22,18,15,12,15,30,
            '[\"bite\"]', NULL);"

    run "$REPO_ROOT/pokidle" encounters --json --limit 5
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "1" ]
    [[ "$output" == *"zubat"* ]]
}

@test "pokidle export emits showdown set text" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local sid
    sid="$(sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));
         SELECT last_insert_rowid();")"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level, nature,
            ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
            ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
            moves_json, sprite_path)
        VALUES ($sid, $(date +%s), 'sceptile', 254, 42, 'adamant', 'overgrow', 0, 'M', 1, 'sitrus',
            31,28,19,31,24,30,
            252,0,0,6,0,252,
            142,198,95,129,95,152,
            '[\"leaf-blade\",\"dragon-claw\",\"earthquake\",\"x-scissor\"]', NULL);"

    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sceptile @ Sitrus Berry"* ]]
    [[ "$output" == *"Adamant Nature"* ]]
}

@test "pokidle items --json" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    local sid
    sid="$(sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));
         SELECT last_insert_rowid();")"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO item_drops(session_id, encountered_at, item, sprite_path)
         VALUES ($sid, $(date +%s), 'everstone', NULL);"
    run "$REPO_ROOT/pokidle" items --json --limit 5
    [ "$status" -eq 0 ]
    local n
    n="$(jq 'length' <<< "$output")"
    [ "$n" = "1" ]
}

@test "pokidle stats prints totals" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"
    run "$REPO_ROOT/pokidle" stats
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total encounters"* ]]
}

@test "pokidle tick encounter --dry-run --no-notify --json: emits encounter without writing db" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"

    local pool='{"biome":"cave","built_at":"2026-05-08T00:00:00Z","tiers":{"common":[{"species":"treecko","varieties":["treecko"],"min":5,"max":7}],"uncommon":[],"rare":[],"very_rare":[]}}'
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    printf '%s' "$pool" > "$POKIDLE_CACHE_DIR/pools/cave.json"

    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKEAPI_CACHE_DIR
    _seed_pokeapi_cache "$POKEAPI_CACHE_DIR"

    run "$REPO_ROOT/pokidle" tick encounter --dry-run --no-notify --json
    [ "$status" -eq 0 ]
    local sp
    sp="$(jq -r '.species' <<< "$output")"
    [ "$sp" = "treecko" ]

    local n
    n="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM encounters;")"
    [ "$n" = "0" ]
}

@test "pokidle tick encounter (non-json): stdout includes ability and moves like the notification" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"

    local pool='{"biome":"cave","built_at":"2026-05-08T00:00:00Z","tiers":{"common":[{"species":"treecko","varieties":["treecko"],"min":5,"max":7}],"uncommon":[],"rare":[],"very_rare":[]}}'
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    printf '%s' "$pool" > "$POKIDLE_CACHE_DIR/pools/cave.json"

    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKEAPI_CACHE_DIR
    _seed_pokeapi_cache "$POKEAPI_CACHE_DIR"

    run "$REPO_ROOT/pokidle" tick encounter --dry-run --no-notify --no-images
    [ "$status" -eq 0 ]
    [[ "$output" == *"treecko"* ]]
    [[ "$output" =~ (overgrow|unburden) ]]
    [[ "$output" == *"moves:"* ]]
    [[ "$output" == *"ivs:"* ]]
    [[ "$output" == *"evs:"* ]]
}

@test "pokidle tick encounter --no-output: succeeds and prints nothing" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"

    local pool='{"biome":"cave","built_at":"2026-05-08T00:00:00Z","tiers":{"common":[{"species":"treecko","varieties":["treecko"],"min":5,"max":7}],"uncommon":[],"rare":[],"very_rare":[]}}'
    mkdir -p "$POKIDLE_CACHE_DIR/pools"
    printf '%s' "$pool" > "$POKIDLE_CACHE_DIR/pools/cave.json"

    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKEAPI_CACHE_DIR
    _seed_pokeapi_cache "$POKEAPI_CACHE_DIR"

    run "$REPO_ROOT/pokidle" tick encounter --dry-run --no-notify --no-output
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pokidle tick pokemon: rejected as an unknown kind" {
    run "$REPO_ROOT/pokidle" tick pokemon --dry-run --no-notify
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown kind: pokemon"* ]]
}

@test "pokidle tick (bare): a kind is required, prints usage, exits 2" {
    run "$REPO_ROOT/pokidle" tick
    [ "$status" -eq 2 ]
    [[ "$output" == *"a kind is required"* ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "pokidle tick pickup --dry-run: emits item json with item and sprite_url" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"

    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKEAPI_CACHE_DIR
    _seed_pokeapi_cache "$POKEAPI_CACHE_DIR"

    run "$REPO_ROOT/pokidle" tick pickup --dry-run --no-notify --json
    [ "$status" -eq 0 ]
    local item
    item="$(jq -r '.item' <<< "$output")"
    [ -n "$item" ]
    [ "$item" != "null" ]
    # No db write in dry-run
    local n
    n="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops;")"
    [ "$n" = "0" ]
}

@test "pokidle tick pickup --no-dry-run: writes to item_drops" {
    sqlite3 "$POKIDLE_DB_PATH" < "$REPO_ROOT/schema.sql"
    sqlite3 "$POKIDLE_DB_PATH" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"

    POKEAPI_CACHE_DIR="$BATS_TMPDIR/papi.$$"
    export POKEAPI_CACHE_DIR
    _seed_pokeapi_cache "$POKEAPI_CACHE_DIR"

    run "$REPO_ROOT/pokidle" tick pickup --no-dry-run --no-notify --no-output
    [ "$status" -eq 0 ]
    local n
    n="$(sqlite3 "$POKIDLE_DB_PATH" "SELECT COUNT(*) FROM item_drops;")"
    [ "$n" = "1" ]
}

@test "export omits evolution-stone drops as held items" {
    _seed_schema
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('glacier', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry, friendship,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
            ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
            moves_json, sprite_path)
        VALUES (1, 1700000100, 'sneasel', 215, 40, 'hardy', 'inner-focus', 0, 'male', 0, NULL, 70,
            31,31,31,31,31,31, 0,0,0,0,0,0, 120,100,100,80,80,110, '[\"ice-punch\"]', NULL);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 1700000100, 'ice-stone');"
    # Explicit window covers the seeded epoch so the encounter + drop are
    # in-scope. ice-stone is the ONLY drop, so without the Showdown-legal gate
    # it would be the sole held-item candidate and get assigned.
    run "$REPO_ROOT/pokidle" export --since @1700000000 --until @1700000200
    [ "$status" -eq 0 ]
    # Non-vacuous: the team actually exported the species.
    grep -qi "sneasel" <<< "$output"
    # The evolution stone must not appear as a held item.
    ! grep -qi "ice-stone" <<< "$output"
}

@test "export omits Showdown-illegal junk drops as held items" {
    _seed_schema
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('glacier', 1700000000);
        INSERT INTO encounters(session_id, encountered_at, species, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry, friendship,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe,
            ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe,
            moves_json, sprite_path)
        VALUES (1, 1700000100, 'sneasel', 215, 40, 'hardy', 'inner-focus', 0, 'male', 0, NULL, 70,
            31,31,31,31,31,31, 0,0,0,0,0,0, 120,100,100,80,80,110, '[\"ice-punch\"]', NULL);
        INSERT INTO item_drops(session_id, encountered_at, item) VALUES
            (1, 1700000100, 'exp-share');"
    # exp-share is a legacy/junk drop Showdown rejects. It is the ONLY drop, so
    # the only way it stays out of the team is the Showdown-legal gate.
    run "$REPO_ROOT/pokidle" export --since @1700000000 --until @1700000200
    [ "$status" -eq 0 ]
    grep -qi "sneasel" <<< "$output"
    ! grep -qi "exp" <<< "$output"
}


@test "items hides consumed by default, --all shows them marked (used)" {
    _seed_schema
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('glacier', 1700000000);
        INSERT INTO item_drops(session_id, encountered_at, item, consumed_at) VALUES
            (1, 1700000100, 'leftovers', NULL),
            (1, 1700000200, 'ice-stone', 1700000300);"
    run "$REPO_ROOT/pokidle" items --since @1700000000 --until @1700000300
    [ "$status" -eq 0 ]
    grep -qi "leftovers" <<< "$output"
    ! grep -qi "ice-stone" <<< "$output"
    run "$REPO_ROOT/pokidle" items --all --since @1700000000 --until @1700000300
    [ "$status" -eq 0 ]
    grep -qi "ice-stone" <<< "$output"
    grep -qi "(used)" <<< "$output"
}

@test "encounters renders the full multi-line record per encounter" {
    _seed_schema
    local sid; sid="$(_mk_session crystal-cavern)"
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe, ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe, moves_json, sprite_path)
        VALUES ($sid, $now, 'meowth', 'meowth-galar', 10161, 12, 'adamant', 'pickup', 0, 'M', 0, NULL,
            31,31,31,31,31,31, 1,2,3,4,5,6, 50,51,52,53,54,55, '[\"scratch\",\"bite\"]', NULL);"
    run "$REPO_ROOT/pokidle" encounters --no-images
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(printf '%s   crystal-cavern   Lv.12 meowth-galar' "$(date -d "@$now" '+%F %H:%M')")" ]
    [ "${lines[1]}" = "   adamant · pickup · M" ]
    [ "${lines[2]}" = "   Stats: 50/51/52/53/54/55" ]
    [ "${lines[3]}" = "   IVs:   31/31/31/31/31/31" ]
    [ "${lines[4]}" = "   EVs:   1/2/3/4/5/6" ]
    [ "${lines[5]}" = "   Moves: scratch, bite" ]
}

@test "encounters marks shiny rows with a sparkle" {
    _seed_schema
    local sid; sid="$(_mk_session cave)"
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO encounters(session_id, encountered_at, species, variety, dex_id, level,
            nature, ability, is_hidden_ability, gender, shiny, held_berry,
            iv_hp,iv_atk,iv_def,iv_spa,iv_spd,iv_spe, ev_hp,ev_atk,ev_def,ev_spa,ev_spd,ev_spe,
            stat_hp,stat_atk,stat_def,stat_spa,stat_spd,stat_spe, moves_json, sprite_path)
        VALUES ($sid, $now, 'zubat', 'zubat', 41, 7, 'jolly', 'inner-focus', 0, 'F', 1, NULL,
            10,10,10,10,10,10, 0,0,0,0,0,0, 20,20,20,20,20,20, '[\"bite\"]', NULL);"
    run "$REPO_ROOT/pokidle" encounters --no-images
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"Lv.7 zubat ✨" ]]
}

@test "items renders date, biome and item per row, oldest first" {
    _seed_schema
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $now);
        INSERT INTO item_drops(session_id, encountered_at, item, sprite_path, consumed_at) VALUES
            (1, $((now - 200)), 'everstone', NULL, NULL),
            (1, $((now - 100)), 'leftovers', NULL, $((now - 50)));"
    run "$REPO_ROOT/pokidle" items --all --no-images
    [ "$status" -eq 0 ]
    local l1 l2
    l1="$(printf '%s   %s   %s' "$(date -d "@$((now - 200))" '+%F %H:%M')" 'cave' 'everstone')"
    l2="$(printf '%s   %s   %s%s' "$(date -d "@$((now - 100))" '+%F %H:%M')" 'cave' 'leftovers' '   (used)')"
    [ "${lines[0]}" = "$l1" ]
    [[ "${output}" == *"$l2"* ]]
}

@test "biomes lists all 36 biomes with labels and types" {
    run "$REPO_ROOT/pokidle" biomes
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 36 ]
    grep -q "^Forest .* grass / bug$" <<< "$output"
    grep -q "Dragon's Nest .* dragon / psychic$" <<< "$output"
    grep -q "Cathedral .* steel / fairy$" <<< "$output"
}

@test "biomes --json emits 36 well-formed objects" {
    run "$REPO_ROOT/pokidle" biomes --json
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<< "$output")" -eq 36 ]
    [ "$(jq -r '.[0].id' <<< "$output")" = "forest" ]
    [ "$(jq -r '.[0].label' <<< "$output")" = "Forest" ]
    [ "$(jq -rc '.[0].types' <<< "$output")" = '["grass","bug"]' ]
    [ "$(jq '[.[] | select(.types | length != 2)] | length' <<< "$output")" -eq 0 ]
}

@test "biomes rejects an unknown flag" {
    run "$REPO_ROOT/pokidle" biomes --bogus
    [ "$status" -eq 2 ]
    grep -qi "unknown flag" <<< "$output"
}

@test "log renders one formatted line per event, oldest first" {
    _seed_schema
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO event_log(ts, kind, summary) VALUES
            ($((now - 200)), 'encounter', 'zubat Lv.5 M [cave]'),
            ($((now - 100)), 'item', 'found oran-berry [cave]');"
    run "$REPO_ROOT/pokidle" log
    [ "$status" -eq 0 ]
    local l1 l2
    l1="$(printf '%s   %-10s %s' "$(date -d "@$((now - 200))" '+%F %H:%M')" 'encounter' 'zubat Lv.5 M [cave]')"
    l2="$(printf '%s   %-10s %s' "$(date -d "@$((now - 100))" '+%F %H:%M')" 'item' 'found oran-berry [cave]')"
    [ "${lines[0]}" = "$l1" ]
    [ "${lines[1]}" = "$l2" ]
}

@test "log --reverse renders newest first" {
    _seed_schema
    local now; now="$(date +%s)"
    sqlite3 "$POKIDLE_DB_PATH" "
        INSERT INTO event_log(ts, kind, summary) VALUES
            ($((now - 200)), 'encounter', 'older'),
            ($((now - 100)), 'encounter', 'newer');"
    run "$REPO_ROOT/pokidle" log --reverse
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"newer"* ]]
    [[ "${lines[1]}" == *"older"* ]]
}

@test "rebuild-pool --items writes items-holdable.tsv and no pool files" {
    # Stubs: make _showdown_build_holdable_meta produce a minimal TSV without network.
    local sd_dir
    sd_dir="$(mktemp -d "${BATS_TMPDIR}/sd_items.XXXXXX")"

    run env \
        POKIDLE_TEST_SOURCE_ONLY=1 \
        POKIDLE_SHOWDOWN_CACHE_DIR="${sd_dir}" \
        POKIDLE_CACHE_DIR="${POKIDLE_CACHE_DIR}" \
        bash -c '
            source "'"${REPO_ROOT}"'/pokidle"
            # Override _showdown_build_holdable_meta with a stub.
            _showdown_build_holdable_meta() {
                printf "leftovers\t\t0\nchoice-band\t\t0\n" > "'"${sd_dir}"'/items-holdable.tsv"
            }
            pokidle_rebuild_pool --items
        '
    [ "$status" -eq 0 ]
    [ -f "${sd_dir}/items-holdable.tsv" ]
    # No pool files should have been written.
    local n
    n="$(find "${POKIDLE_CACHE_DIR}/pools" -name '*.json' 2>/dev/null | wc -l)"
    [ "$n" -eq 0 ]
    rm -rf "${sd_dir}"
}

@test "rebuild-pool --no-items <biome> writes pool, leaves .tsv untouched" {
    local sd_dir
    sd_dir="$(mktemp -d "${BATS_TMPDIR}/sd_noitems.XXXXXX")"

    run env \
        POKIDLE_TEST_SOURCE_ONLY=1 \
        POKIDLE_SHOWDOWN_CACHE_DIR="${sd_dir}" \
        POKIDLE_CACHE_DIR="${POKIDLE_CACHE_DIR}" \
        bash -c '
            source "'"${REPO_ROOT}"'/pokidle"
            # Stub encounter_build_pool to produce a minimal pool JSON.
            encounter_build_pool() {
                printf "{\"biome\":\"%s\",\"built_at\":\"2026-01-01T00:00:00Z\",\"tiers\":{\"common\":[],\"uncommon\":[],\"rare\":[],\"very_rare\":[]},\"items\":[],\"berries\":[]}" "$1"
            }
            encounter_pool_save() {
                local b="$1" pool="$2"
                mkdir -p "'"${POKIDLE_CACHE_DIR}"'/pools"
                printf '"'"'%s'"'"' "${pool}" > "'"${POKIDLE_CACHE_DIR}"'/pools/${b}.json"
            }
            pokidle_rebuild_pool --no-items cave --yes
        '
    [ "$status" -eq 0 ]
    [ -f "${POKIDLE_CACHE_DIR}/pools/cave.json" ]
    # .tsv should NOT have been created by this call.
    [ ! -f "${sd_dir}/items-holdable.tsv" ]
    rm -rf "${sd_dir}"
}

@test "export gates non-holdable items: abomasite never assigned, leftovers passes" {
    # Verifies showdown_item_is_holdable is the live gate in pokidle_export.
    # seed_showdown (called in setup) seeds items-holdable.txt with leftovers
    # but NOT abomasite (a Mega Stone, species-locked). The export must keep
    # leftovers and silently drop abomasite.
    _seed_schema
    local sid; sid="$(_mk_session tundra)"
    local now; now="$(date +%s)"
    _ins_enc "$sid" snorlax "$now"
    _ins_item "$sid" leftovers "$now"
    _ins_item "$sid" abomasite "$now"
    run "$REPO_ROOT/pokidle" export
    [ "$status" -eq 0 ]
    [[ "$output" == *"@ Leftovers"* ]]
    ! grep -qi 'abomasite' <<<"$output"
}

@test "_pokidle_print_encounter: shows the encountered variety, not bare species" {
    run env POKIDLE_TEST_SOURCE_ONLY=1 bash -c '
        source "'"${REPO_ROOT}"'/pokidle"
        enc='"'"'{"species":"meowth","variety":"meowth-galar","level":12,"nature":"jolly","ability":"pickup","gender":"M","shiny":0,"held_berry":null,"biome_label":"City","ivs":[1,2,3,4,5,6],"evs":[0,0,0,0,0,0],"moves":["scratch"]}'"'"'
        _pokidle_print_encounter encounter "$enc"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"meowth-galar"* ]]
}
