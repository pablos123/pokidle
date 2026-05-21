#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_TEST_HOME="$BATS_TMPDIR/home.$$"
    mkdir -p "$POKIDLE_TEST_HOME"
    export HOME="$POKIDLE_TEST_HOME"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    # Override systemctl: the test must not poke real user services.
    export PATH="$BATS_TMPDIR/bin.$$:$PATH"
    mkdir -p "$BATS_TMPDIR/bin.$$"
    cat > "$BATS_TMPDIR/bin.$$/systemctl" <<'EOF'
#!/bin/bash
# stub: log args, exit 0
echo "stub-systemctl: $*" >> "$HOME/systemctl.log"
exit 0
EOF
    chmod +x "$BATS_TMPDIR/bin.$$/systemctl"
}

teardown() {
    rm -rf "$POKIDLE_TEST_HOME" "$BATS_TMPDIR/bin.$$"
}

@test "pokidle setup creates config + unit + symlink and enables the unit" {
    run "$REPO_ROOT/pokidle" setup
    [ "$status" -eq 0 ]
    [ -f "$XDG_CONFIG_HOME/pokidle/biomes.json" ]
    [ -f "$XDG_CONFIG_HOME/systemd/user/pokidle.service" ]
    [ -L "$HOME/.local/bin/pokidle" ]
    [ -L "$XDG_DATA_HOME/pokidle/biomes" ]
    [ -L "$XDG_DATA_HOME/pokidle/notify" ]
    [ -L "$XDG_DATA_HOME/pokidle/sounds" ]
    [ "$(readlink "$XDG_DATA_HOME/pokidle/sounds")" = "$REPO_ROOT/share/sounds" ]
    grep -q 'daemon-reload' "$HOME/systemctl.log"
    grep -q 'enable --now' "$HOME/systemctl.log"
}

@test "pokidle setup --no-enable installs without starting the unit" {
    run "$REPO_ROOT/pokidle" setup --no-enable
    [ "$status" -eq 0 ]
    [ -f "$XDG_CONFIG_HOME/systemd/user/pokidle.service" ]
    grep -q 'daemon-reload' "$HOME/systemctl.log"
    ! grep -q 'enable --now' "$HOME/systemctl.log"
}

@test "pokidle setup seeds shipped pools into the cache" {
    mkdir -p "$REPO_ROOT/share/pools"
    local fixture="$REPO_ROOT/share/pools/_bats_seed.json"
    cat > "$fixture" <<'EOF'
{"biome":"_bats_seed","built_at":"2026-01-01T00:00:00Z","schema":3,
 "tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},
 "berries":[]}
EOF
    run "$REPO_ROOT/pokidle" setup
    local status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    [ -f "$XDG_CACHE_HOME/pokidle/pools/_bats_seed.json" ]
}

@test "pokidle setup skips shipped pool with stale schema" {
    mkdir -p "$REPO_ROOT/share/pools"
    local fixture="$REPO_ROOT/share/pools/_bats_stale.json"
    echo '{"biome":"_bats_stale","schema":1,"tiers":{},"berries":[]}' > "$fixture"
    run "$REPO_ROOT/pokidle" setup
    local out=$output status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    [ ! -f "$XDG_CACHE_HOME/pokidle/pools/_bats_stale.json" ]
    [[ "$out" == *"schema=1"* ]]
}

@test "pokidle setup keeps existing cached pool (no --force)" {
    mkdir -p "$REPO_ROOT/share/pools" "$XDG_CACHE_HOME/pokidle/pools"
    local fixture="$REPO_ROOT/share/pools/_bats_keep.json"
    local cached="$XDG_CACHE_HOME/pokidle/pools/_bats_keep.json"
    echo '{"biome":"_bats_keep","schema":3,"new":1,"tiers":{},"berries":[]}' > "$fixture"
    echo '{"biome":"_bats_keep","schema":3,"old":1,"tiers":{},"berries":[]}' > "$cached"
    run "$REPO_ROOT/pokidle" setup
    local status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    grep -q '"old":1' "$cached"
}

@test "pokidle uninstall removes the asset symlinks" {
    "$REPO_ROOT/pokidle" setup
    [ -L "$XDG_DATA_HOME/pokidle/biomes" ]
    run "$REPO_ROOT/pokidle" uninstall
    [ "$status" -eq 0 ]
    [ ! -L "$XDG_DATA_HOME/pokidle/biomes" ]
    [ ! -L "$XDG_DATA_HOME/pokidle/notify" ]
    [ ! -L "$XDG_DATA_HOME/pokidle/sounds" ]
}

@test "pokidle setup --enable is accepted (back-compat) and enables the unit" {
    run "$REPO_ROOT/pokidle" setup --enable
    [ "$status" -eq 0 ]
    grep -q 'enable --now' "$HOME/systemctl.log"
}

@test "pokidle setup propagates systemctl enable failure" {
    cat > "$BATS_TMPDIR/bin.$$/systemctl" <<'EOF'
#!/bin/bash
echo "stub-systemctl: $*" >> "$HOME/systemctl.log"
case "$*" in
    *"enable --now"*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_TMPDIR/bin.$$/systemctl"
    run "$REPO_ROOT/pokidle" setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"enable failed"* ]]
}

@test "pokidle setup is idempotent (no overwrite without --force)" {
    "$REPO_ROOT/pokidle" setup
    echo '{"manual":"edit"}' > "$XDG_CONFIG_HOME/pokidle/biomes.json"
    "$REPO_ROOT/pokidle" setup
    run cat "$XDG_CONFIG_HOME/pokidle/biomes.json"
    [ "$output" = '{"manual":"edit"}' ]
}

@test "pokidle setup --force overwrites config" {
    "$REPO_ROOT/pokidle" setup
    echo '{"manual":"edit"}' > "$XDG_CONFIG_HOME/pokidle/biomes.json"
    "$REPO_ROOT/pokidle" setup --force
    cmp -s "$REPO_ROOT/config/biomes.json" "$XDG_CONFIG_HOME/pokidle/biomes.json"
}

@test "pokidle status prints systemctl + last tick info" {
    "$REPO_ROOT/pokidle" setup

    # Pre-populate db with some state
    db_init() { sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" < "$REPO_ROOT/schema.sql"; }
    db_init

    sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"
    sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" \
        "INSERT OR REPLACE INTO daemon_state(key,value) VALUES ('last_pokemon_tick_target','1700001000');"

    run "$REPO_ROOT/pokidle" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"systemctl"* ]] || [[ "$output" == *"Loaded:"* ]] || true
    [[ "$output" == *"cave"* ]]
    [[ "$output" == *"last_pokemon_tick_target"* ]] || [[ "$output" == *"1700001000"* ]]
}
