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

@test "pokidle setup refreshes a stale unit file without --force" {
    local unit="$XDG_CONFIG_HOME/systemd/user/pokidle.service"
    mkdir -p "${unit%/*}"
    # Simulate an old install whose ExecStart predates `daemon run`.
    printf '[Service]\nExecStart=%%h/.local/bin/pokidle daemon\n' > "$unit"
    run "$REPO_ROOT/pokidle" setup --no-enable
    [ "$status" -eq 0 ]
    # setup must overwrite the app-owned unit with the current repo copy.
    diff "$unit" "$REPO_ROOT/systemd/pokidle.service"
    grep -qF -- 'daemon run' "$unit"
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
{"biome":"_bats_seed","built_at":"2026-01-01T00:00:00Z",
 "tiers":{"common":[],"uncommon":[],"rare":[],"very_rare":[]},
 "berries":[]}
EOF
    run "$REPO_ROOT/pokidle" setup
    local status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    [ -f "$XDG_CACHE_HOME/pokidle/pools/_bats_seed.json" ]
}

@test "pokidle setup keeps a cached pool that is newer than the shipped copy" {
    mkdir -p "$REPO_ROOT/share/pools" "$XDG_CACHE_HOME/pokidle/pools"
    local fixture="$REPO_ROOT/share/pools/_bats_keep.json"
    local cached="$XDG_CACHE_HOME/pokidle/pools/_bats_keep.json"
    echo '{"biome":"_bats_keep","shipped":1,"tiers":{},"berries":[]}' > "$fixture"
    echo '{"biome":"_bats_keep","cached":1,"tiers":{},"berries":[]}' > "$cached"
    # Cached copy is newer (e.g. user ran rebuild-pool) -> must be kept.
    touch -d '2020-01-01' "$fixture"
    touch -d '2030-01-01' "$cached"
    run "$REPO_ROOT/pokidle" setup
    local status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    grep -q '"cached":1' "$cached"
}

@test "pokidle setup overwrites a cached pool when the shipped copy is newer" {
    mkdir -p "$REPO_ROOT/share/pools" "$XDG_CACHE_HOME/pokidle/pools"
    local fixture="$REPO_ROOT/share/pools/_bats_fresh.json"
    local cached="$XDG_CACHE_HOME/pokidle/pools/_bats_fresh.json"
    echo '{"biome":"_bats_fresh","shipped":1,"tiers":{},"berries":[]}' > "$fixture"
    echo '{"biome":"_bats_fresh","cached":1,"tiers":{},"berries":[]}' > "$cached"
    # Shipped copy is newer (e.g. after git pull) -> must overwrite the cache.
    touch -d '2020-01-01' "$cached"
    touch -d '2030-01-01' "$fixture"
    run "$REPO_ROOT/pokidle" setup
    local status_ok=$status
    rm -f "$fixture"
    [ "$status_ok" -eq 0 ]
    grep -q '"shipped":1' "$cached"
}

@test "pokidle setup rejects the removed --force flag" {
    run "$REPO_ROOT/pokidle" setup --force
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown flag"* ]]
}

@test "pokidle setup re-points a stale asset symlink" {
    local link="$XDG_DATA_HOME/pokidle/biomes"
    mkdir -p "${link%/*}"
    # Valid but wrong target (e.g. repo was moved): must still be refreshed.
    ln -sfn "$BATS_TMPDIR" "$link"
    run "$REPO_ROOT/pokidle" setup --no-enable
    [ "$status" -eq 0 ]
    [ "$(readlink "$link")" = "$REPO_ROOT/share/biomes" ]
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

