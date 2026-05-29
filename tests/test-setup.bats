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
    [ -d "$XDG_CONFIG_HOME/pokidle" ]
    [ -f "$XDG_CONFIG_HOME/systemd/user/pokidle.service" ]
    [ -L "$HOME/.local/bin/pokidle" ]
    [ -L "$XDG_DATA_HOME/pokidle/biomes" ]
    [ -L "$XDG_DATA_HOME/pokidle/notify" ]
    [ -L "$XDG_DATA_HOME/pokidle/sounds" ]
    [ "$(readlink "$XDG_DATA_HOME/pokidle/sounds")" = "$REPO_ROOT/share/sounds" ]
    grep -q 'daemon-reload' "$HOME/systemctl.log"
    grep -q 'enable --now' "$HOME/systemctl.log"
    # enable --now starts a fresh box; the follow-up restart reloads a daemon
    # that was already running on stale code.
    grep -qF -- 'restart pokidle.service' "$HOME/systemctl.log"
}

@test "pokidle setup --no-enable installs without starting or restarting the unit" {
    run "$REPO_ROOT/pokidle" setup --no-enable
    [ "$status" -eq 0 ]
    [ -f "$XDG_CONFIG_HOME/systemd/user/pokidle.service" ]
    grep -q 'daemon-reload' "$HOME/systemctl.log"
    ! grep -q 'enable --now' "$HOME/systemctl.log"
    ! grep -qF -- 'restart pokidle.service' "$HOME/systemctl.log"
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

@test "pokidle setup installs bash completion symlinks (no root)" {
    run "$REPO_ROOT/pokidle" setup
    [ "$status" -eq 0 ]
    local compdir="$XDG_DATA_HOME/bash-completion/completions"
    [ -L "$compdir/pokidle" ]
    [ -L "$compdir/pokeapi" ]
    [ "$(readlink "$compdir/pokidle")" = "$REPO_ROOT/share/completions/pokidle.bash" ]
}

@test "pokidle uninstall removes the bash completion symlinks" {
    "$REPO_ROOT/pokidle" setup
    local compdir="$XDG_DATA_HOME/bash-completion/completions"
    [ -L "$compdir/pokidle" ]
    run "$REPO_ROOT/pokidle" uninstall
    [ "$status" -eq 0 ]
    [ ! -L "$compdir/pokidle" ]
    [ ! -L "$compdir/pokeapi" ]
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

@test "pokidle uninstall kills the orphan daemon when disable fails" {
    "$REPO_ROOT/pokidle" setup
    # Stand-in for a running daemon that systemd lost track of.
    sleep 300 &
    local fake_pid=$!
    # systemctl stub: report the orphan as MainPID, fail on disable --now.
    cat > "$BATS_TMPDIR/bin.$$/systemctl" <<EOF
#!/bin/bash
echo "stub-systemctl: \$*" >> "$HOME/systemctl.log"
case "\$*" in
    *"show"*"MainPID"*) echo "$fake_pid"; exit 0 ;;
    *"disable --now"*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_TMPDIR/bin.$$/systemctl"
    run "$REPO_ROOT/pokidle" uninstall
    [ "$status" -eq 0 ]
    # No trace: the orphan must be dead.
    run kill -0 "$fake_pid"
    kill "$fake_pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
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

