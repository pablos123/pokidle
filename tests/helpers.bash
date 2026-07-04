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
    # helpers.bash is the shared base every lib may call into; always present.
    # shellcheck disable=SC1090
    source "${LIB_DIR}/helpers.bash"
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

# Stub the GraphQL berry index (name<TAB>gift-type) so encounter_build_pool needs
# no network. Call after load_lib encounter (re-sourcing the lib restores the real
# function). chesto=water and cheri=fire cover the natural_gift filter tests.
stub_gql_berries() {
    encounter_gql_berries() {
        printf '%s\n' $'cheri\tfire' $'chesto\twater' $'pecha\telectric'
    }
    export -f encounter_gql_berries
}

# Stub the GraphQL pool seams (type->species rows + chain stage map) with a
# forest-representative dataset, so encounter_build_pool needs no network.
# Type-agnostic: returns the same rows for any type (the union dedups). Covers
# the tiers/varieties/min-max/legendary assertions in the build_pool tests.
stub_gql_pool() {
    encounter_gql_type_species() {
        cat <<'JSON'
{"variety":"caterpie","species":"caterpie","cr":255,"leg":false}
{"variety":"metapod","species":"metapod","cr":255,"leg":false}
{"variety":"butterfree","species":"butterfree","cr":45,"leg":false}
{"variety":"treecko","species":"treecko","cr":45,"leg":false}
{"variety":"grovyle","species":"grovyle","cr":45,"leg":false}
{"variety":"sceptile","species":"sceptile","cr":45,"leg":false}
{"variety":"wormadam-plant","species":"wormadam","cr":45,"leg":false}
{"variety":"wormadam-sandy","species":"wormadam","cr":45,"leg":false}
{"variety":"wormadam-trash","species":"wormadam","cr":45,"leg":false}
{"variety":"shaymin-land","species":"shaymin","cr":45,"leg":true}
{"variety":"shaymin-sky","species":"shaymin","cr":45,"leg":true}
JSON
    }
    encounter_gql_chain_stages() {
        printf '%s' '{"caterpie":{"stage":0,"ml":null},"metapod":{"stage":1,"ml":7},"butterfree":{"stage":2,"ml":10},"treecko":{"stage":0,"ml":null},"grovyle":{"stage":1,"ml":16},"sceptile":{"stage":2,"ml":36},"wormadam":{"stage":1,"ml":20},"shaymin":{"stage":0,"ml":null}}'
    }
    export -f encounter_gql_type_species encounter_gql_chain_stages
}

# Seed the Showdown data cache from fixtures and block network fetches.
# Call after load_lib so showdown functions exist.
seed_showdown() {
    POKIDLE_SHOWDOWN_CACHE_DIR="$(mktemp -d "${BATS_TMPDIR}/sd.XXXXXX")"
    export POKIDLE_SHOWDOWN_CACHE_DIR
    cp "${FIXTURE_DIR}/showdown-pokedex.json"        "${POKIDLE_SHOWDOWN_CACHE_DIR}/pokedex.json"
    cp "${FIXTURE_DIR}/showdown-learnsets.json"      "${POKIDLE_SHOWDOWN_CACHE_DIR}/learnsets.json"
    cp "${FIXTURE_DIR}/showdown-moves.json"          "${POKIDLE_SHOWDOWN_CACHE_DIR}/moves.json"
    cp "${FIXTURE_DIR}/showdown-items-holdable.tsv"  "${POKIDLE_SHOWDOWN_CACHE_DIR}/items-holdable.tsv"
    _showdown_fetch() { return 1; }
    _showdown_fetch_items() { return 1; }
    export -f _showdown_fetch _showdown_fetch_items
}
