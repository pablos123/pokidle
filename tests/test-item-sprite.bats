#!/usr/bin/env bats

load helpers

# item_sprite downloads the item art blob (a separate GitHub-raw request from the
# item metadata fetch), which can fail transiently. These tests pin the retry
# behaviour that keeps a single blip from dropping the sprite.

setup() {
    load_lib api
    # Deterministic slug -> url -> cache path, so only the download varies.
    item_sprite_url() { printf 'http://stub.local/%s.png' "$1"; }
    cache_blob_path() { printf '%s' "${BATS_TMPDIR}/sprite.${BATS_TEST_NUMBER}.png"; }
    export -f item_sprite_url cache_blob_path
    DLCOUNT="${BATS_TMPDIR}/dlcount.${BATS_TEST_NUMBER}"
    printf '0' >"${DLCOUNT}"
    export DLCOUNT
    rm -f "${BATS_TMPDIR}/sprite.${BATS_TEST_NUMBER}.png"
}

# Stub http_download_url to fail its first ($1) attempts, then succeed. The call
# count is tracked in DLCOUNT so tests can assert how many attempts were made.
stub_download_fail_first() {
    local fail_until="$1"
    eval '
    http_download_url() {
        local n; n="$(cat "${DLCOUNT}")"; n=$((n + 1)); printf "%s" "$n" >"${DLCOUNT}"
        if ((n <= '"${fail_until}"')); then return 1; fi
        printf "" >"$2"
        return 0
    }'
    export -f http_download_url
}

@test "item_sprite retries a transient download failure and succeeds" {
    stub_download_fail_first 2   # fail attempts 1 and 2, succeed on 3
    run item_sprite pinap-berry
    [ "$status" -eq 0 ]
    [ "$output" = "${BATS_TMPDIR}/sprite.${BATS_TEST_NUMBER}.png" ]
    [ "$(cat "${DLCOUNT}")" -eq 3 ]
}

@test "item_sprite gives up after exhausting the default 3 attempts" {
    stub_download_fail_first 99  # always fail
    run item_sprite pinap-berry
    [ "$status" -eq 1 ]
    [ "$(cat "${DLCOUNT}")" -eq 3 ]
}

@test "item_sprite attempt count is configurable via POKIDLE_SPRITE_DOWNLOAD_TRIES" {
    stub_download_fail_first 99
    POKIDLE_SPRITE_DOWNLOAD_TRIES=5 run item_sprite pinap-berry
    [ "$status" -eq 1 ]
    [ "$(cat "${DLCOUNT}")" -eq 5 ]
}

@test "item_sprite does not download when the blob is already cached" {
    printf 'cached' >"${BATS_TMPDIR}/sprite.${BATS_TEST_NUMBER}.png"
    stub_download_fail_first 99  # would fail if ever called
    run item_sprite pinap-berry
    [ "$status" -eq 0 ]
    [ "$output" = "${BATS_TMPDIR}/sprite.${BATS_TEST_NUMBER}.png" ]
    [ "$(cat "${DLCOUNT}")" -eq 0 ]
}
