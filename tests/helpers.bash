# Sourced by every .bats file via `load helpers`.
# Provides: REPO_ROOT, LIB_DIR, mktemp DB, fixture loader, pokeapi_get stub.

# Never hit the network for sprite art during tests.
export POKIDLE_FETCH_SPRITES=0

REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/.." && pwd)"
LIB_DIR="${REPO_ROOT}/lib"
FIXTURE_DIR="${BATS_TEST_DIRNAME}/fixtures"

# No test may reach the network: tests/bin/curl shadows the real curl and fails
# fast (see the shim). Without this a `run "$REPO_ROOT/pokidle" …` test whose
# fixture is missing silently passes against the live API — slowly, and only
# while the network is up. The rate-limit pause is pointless offline.
export PATH="${REPO_ROOT}/tests/bin:${PATH}"
export POKIDLE_POKEAPI_RATE_LIMIT_SLEEP=0

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
#
# The function stub only covers in-process calls: a `run "$REPO_ROOT/pokidle"`
# subprocess re-sources lib/api.bash and gets the real pokeapi_get back. So when
# the test owns a throwaway pokeapi cache dir (under BATS_TMPDIR), the fixtures
# are also laid out there in the on-disk cache layout the real pokeapi_get reads
# first — same fixtures, both paths, no network.
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
    # Same derivation as lib/cache.bash, so the subprocess reads what we seed.
    local cache_dir="${POKIDLE_POKEAPI_CACHE_DIR:-${POKIDLE_CACHE_DIR:-}/pokeapi}"
    if [[ "${cache_dir}" == "${BATS_TMPDIR}/"* ]]; then
        seed_pokeapi_cache "${cache_dir}"
    fi
}

# seed_pokeapi_cache <cache-dir>
# Copy every fixture whose name starts with a PokeAPI endpoint prefix into
# <cache-dir> under the path cache_path() derives for that endpoint:
#   pokemon-species-butterfree.json -> pokemon-species/butterfree.json
#   nature-limit-100.json           -> nature?limit=100.json
# Fixtures with no endpoint prefix (showdown-*, items.js, …) are skipped.
seed_pokeapi_cache() {
    local dir="$1"
    mkdir -p -- "${dir}"
    local -a prefixes=(pokemon-species pokemon-form evolution-chain item-category
        location-area pokemon item nature type berry)
    local f name prefix rest
    for f in "${FIXTURE_DIR}"/*.json; do
        name="${f##*/}"
        name="${name%.json}"
        for prefix in "${prefixes[@]}"; do
            [[ "${name}" == "${prefix}-"* ]] || continue
            rest="${name#"${prefix}"-}"
            if [[ "${rest}" == limit-* ]]; then
                # List endpoint: nature-limit-100 -> nature?limit=100
                cp -- "$f" "${dir}/${prefix}?limit=${rest#limit-}.json"
            else
                mkdir -p -- "${dir}/${prefix}"
                cp -- "$f" "${dir}/${prefix}/${rest}.json"
            fi
            break
        done
    done
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
    # The shipped form-item registry, exactly as `pokidle setup` installs it.
    # Without it every export rebuilds the registry from Showdown's items.js —
    # a network fetch per run. Tests that need a specific registry overwrite it.
    cp "${REPO_ROOT}/share/form-items.tsv"            "${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
    _showdown_fetch() { return 1; }
    _showdown_fetch_items() { return 1; }
    export -f _showdown_fetch _showdown_fetch_items
}
