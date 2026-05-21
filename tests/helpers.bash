# Sourced by every .bats file via `load helpers`.
# Provides: REPO_ROOT, LIB_DIR, mktemp DB, fixture loader, pokeapi_get stub.

# Never hit the network for sprite art during tests.
export POKIDLE_FETCH_SPRITES=0

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/lib"
FIXTURE_DIR="${BATS_TEST_DIRNAME}/fixtures"

# Per-test temp dirs cleaned up by bats automatically when BATS_TMPDIR.
make_tmp_db() {
    local f
    f="$(mktemp "${BATS_TMPDIR}/pokidle.XXXXXX.db")"
    printf '%s' "$f"
}

load_lib() {
    local name="$1"
    # shellcheck disable=SC1090
    source "${LIB_DIR}/${name}.bash"
}

# Replace pokeapi_get with a fixture-backed stub.
# Fixtures live at tests/fixtures/<endpoint-with-slash-as-dash>.json
stub_pokeapi() {
    pokeapi_get() {
        local endpoint="$1"
        local key="${endpoint//\//-}"
        key="${key//\?/-}"
        key="${key//=/-}"
        local f="${FIXTURE_DIR}/${key}.json"
        if [[ ! -f "$f" ]]; then
            printf 'stub_pokeapi: missing fixture %s\n' "$f" >&2
            return 1
        fi
        cat "$f"
    }
    export -f pokeapi_get
}
