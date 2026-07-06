#!/usr/bin/env bats

load helpers

setup() {
    POKIDLE_TEST_HOME="$BATS_TMPDIR/home.$$"
    mkdir -p "$POKIDLE_TEST_HOME"
    export HOME="$POKIDLE_TEST_HOME"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    # Stub systemctl + journalctl: log args, never touch real services.
    export PATH="$BATS_TMPDIR/bin.$$:$PATH"
    mkdir -p "$BATS_TMPDIR/bin.$$"
    cat > "$BATS_TMPDIR/bin.$$/systemctl" <<'EOF'
#!/bin/bash
echo "stub-systemctl: $*" >> "$HOME/systemctl.log"
exit 0
EOF
    cat > "$BATS_TMPDIR/bin.$$/journalctl" <<'EOF'
#!/bin/bash
echo "stub-journalctl: $*" >> "$HOME/journalctl.log"
exit 0
EOF
    chmod +x "$BATS_TMPDIR/bin.$$/systemctl" "$BATS_TMPDIR/bin.$$/journalctl"
}

teardown() {
    rm -rf "$POKIDLE_TEST_HOME" "$BATS_TMPDIR/bin.$$"
}

@test "daemon start runs systemctl --user start pokidle.service" {
    run "$REPO_ROOT/pokidle" daemon start
    [ "$status" -eq 0 ]
    grep -qF -- 'start pokidle.service' "$HOME/systemctl.log"
    grep -qF -- '--user' "$HOME/systemctl.log"
}

@test "daemon stop runs systemctl --user stop pokidle.service" {
    run "$REPO_ROOT/pokidle" daemon stop
    [ "$status" -eq 0 ]
    grep -qF -- 'stop pokidle.service' "$HOME/systemctl.log"
}

@test "daemon restart runs systemctl --user restart pokidle.service" {
    run "$REPO_ROOT/pokidle" daemon restart
    [ "$status" -eq 0 ]
    grep -qF -- 'restart pokidle.service' "$HOME/systemctl.log"
}

@test "daemon enable runs systemctl --user enable pokidle.service" {
    run "$REPO_ROOT/pokidle" daemon enable
    [ "$status" -eq 0 ]
    grep -qF -- 'enable pokidle.service' "$HOME/systemctl.log"
}

@test "daemon disable runs systemctl --user disable pokidle.service" {
    run "$REPO_ROOT/pokidle" daemon disable
    [ "$status" -eq 0 ]
    grep -qF -- 'disable pokidle.service' "$HOME/systemctl.log"
}

@test "daemon logs runs journalctl --user -u pokidle.service and passes args through" {
    run "$REPO_ROOT/pokidle" daemon logs -n 50
    [ "$status" -eq 0 ]
    grep -qF -- '--user -u pokidle.service' "$HOME/journalctl.log"
    grep -qF -- '-n 50' "$HOME/journalctl.log"
}

@test "daemon status prints unit status, current biome, and daemon_state" {
    "$REPO_ROOT/pokidle" setup --no-enable >/dev/null 2>&1 || true
    db_init() { sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" < "$REPO_ROOT/schema.sql"; }
    db_init
    sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" \
        "INSERT INTO biome_sessions(biome_id, started_at) VALUES ('cave', $(date +%s));"
    sqlite3 "$XDG_DATA_HOME/pokidle/pokidle.db" \
        "INSERT OR REPLACE INTO daemon_state(key,value) VALUES ('last_pokemon_tick_target','1700001000');"
    run "$REPO_ROOT/pokidle" daemon status
    [ "$status" -eq 0 ]
    # Match case-insensitively: the current-biome line shows the pretty label
    # ("Cave" via biome_label), falling back to the raw "cave" id only when biome
    # data is absent.
    [[ "${output,,}" == *"cave"* ]]
    [[ "$output" == *"last_pokemon_tick_target"* ]] || [[ "$output" == *"1700001000"* ]]
}

@test "daemon with no verb prints usage and exits 2" {
    run "$REPO_ROOT/pokidle" daemon
    [ "$status" -eq 2 ]
    [ ! -f "$HOME/systemctl.log" ]   # never dispatched to systemctl
}

@test "daemon with unknown verb exits 2" {
    run "$REPO_ROOT/pokidle" daemon frobnicate
    [ "$status" -eq 2 ]
}

@test "top-level status is no longer a command" {
    run "$REPO_ROOT/pokidle" status
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown command"* ]]
}
