#!/usr/bin/env bash
# Pokémon Showdown data source: disk-cached JSON used to make encounters
# born legal (legal abilities/moves) at encounter time.

: "${POKIDLE_SHOWDOWN_BASE_URL:=https://play.pokemonshowdown.com/data}"
: "${POKIDLE_SHOWDOWN_CACHE_DIR:=${POKIDLE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/pokidle}/showdown}"
: "${POKIDLE_SHOWDOWN_TTL:=604800}" # 7 days; Showdown data updates ~weekly.

# showdown_id <name>
# Showdown id for a PokeAPI slug OR a Showdown display name: lowercase, then
# drop every non-alphanumeric char. thundurus-therian->thundurustherian,
# ho-oh->hooh, "Mr. Mime"->mrmime.
function showdown_id {
    local s="${1,,}"
    printf '%s' "${s//[^a-z0-9]/}"
}

# _showdown_fetch <file>
# Print the raw JSON for a Showdown data file from the network. Returns 1 on
# failure. Split out so tests can stub it.
function _showdown_fetch {
    local file="$1"
    curl --silent --show-error --location --fail \
        --user-agent "${POKEAPI_USER_AGENT:-pokidle-bash/0.1}" \
        -- "${POKIDLE_SHOWDOWN_BASE_URL}/${file}.json"
}

# showdown_get <file>
# Print cached JSON for <file> (pokedex|learnsets|moves). Serve a fresh cache
# directly; otherwise refetch and cache; on fetch failure fall back to a stale
# cache if present. Returns 1 only when there is no data at all.
function showdown_get {
    local file="$1"
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/${file}.json"
    if [[ -f "${path}" ]]; then
        local now mtime
        now="$(date +%s)"
        mtime="$(stat -c %Y -- "${path}" 2>/dev/null || date -r "${path}" +%s)"
        if (( now - mtime < POKIDLE_SHOWDOWN_TTL )); then
            cat -- "${path}"
            return 0
        fi
    fi
    local body
    if body="$(_showdown_fetch "${file}")"; then
        printf '%s' "${body}" | atomic_write "${path}"
        printf '%s' "${body}"
        return 0
    fi
    if [[ -f "${path}" ]]; then
        cat -- "${path}"
        return 0
    fi
    return 1
}

# showdown_legal_abilities <variety-slug>
# Print "<ability-slug>\t<hidden>" per legal ability of the forme. hidden=1 for
# the "H" key. Abilities are forme-specific. Returns 1 if the id is unknown.
function showdown_legal_abilities {
    local id
    id="$(showdown_id "$1")"
    local pokedex
    if ! pokedex="$(showdown_get pokedex)"; then
        return 1
    fi
    local out
    out="$(jq -r --arg id "${id}" '
        (.[$id].abilities // empty) | to_entries[]
        | "\(.value | ascii_downcase | gsub("[^a-z0-9]+";"-"))\t\(if .key=="H" then "1" else "0" end)"
    ' <<<"${pokedex}")"
    if [[ -z "${out}" ]]; then
        return 1
    fi
    printf '%s\n' "${out}"
}

# showdown_legal_moves <variety-slug>
# Print one hyphenated move slug per legal move. Moves live under the base
# species (formes carry no learnset); union the base learnset up the prevo
# chain. Returns 1 if nothing resolves.
function showdown_legal_moves {
    local id
    id="$(showdown_id "$1")"
    local pokedex learn moves
    if ! pokedex="$(showdown_get pokedex)"; then return 1; fi
    if ! learn="$(showdown_get learnsets)"; then return 1; fi
    if ! moves="$(showdown_get moves)"; then return 1; fi

    local base
    base="$(jq -r --arg id "${id}" '.[$id].baseSpecies // empty' <<<"${pokedex}")"
    if [[ -n "${base}" ]]; then
        base="$(showdown_id "${base}")"
    else
        base="${id}"
    fi

    local cur="${base}"
    local -a ids=()
    local -A seen=()
    local -i guard=0
    while [[ -n "${cur}" ]] && ((guard++ < 20)); do
        local keys
        keys="$(jq -r --arg c "${cur}" '(.[$c].learnset // {}) | keys[]' <<<"${learn}")"
        local k
        while IFS= read -r k; do
            if [[ -n "${k}" && -z "${seen[$k]:-}" ]]; then
                seen[$k]=1
                ids+=("${k}")
            fi
        done <<<"${keys}"
        local prevo
        prevo="$(jq -r --arg c "${cur}" '.[$c].prevo // empty' <<<"${pokedex}")"
        if [[ -z "${prevo}" ]]; then
            break
        fi
        cur="$(showdown_id "${prevo}")"
    done

    if ((${#ids[@]} == 0)); then
        return 1
    fi
    local idsj
    idsj="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)"
    jq -r --argjson ids "${idsj}" '
        . as $m | $ids[] | ($m[.].name // empty)
        | select(. != "") | ascii_downcase | gsub("[^a-z0-9]+";"-")
    ' <<<"${moves}"
}

# _showdown_items_meta_transform
# Read Showdown items.js on stdin; print TSV rows <slug>\t<type|"">\t<isberry 0|1>
# for each "universally holdable" item. Holdable = no itemUser field, not
# isPokeball:true, and isNonstandard not in {CAP,Custom,Future,LGPE}. items.js is
# a JS object literal (not JSON); item strings contain no braces and no escaped
# quotes, so a brace-depth + quote-state scanner splits items unambiguously.
function _showdown_items_meta_transform {
    # Strip the `exports.BattleItems = {` prefix and the trailing `};`.
    sed -E 's/^[^{]*\{//; s/\};?[[:space:]]*$//' \
        | awk '
        {
            n = length($0); depth = 0; inq = 0; buf = "";
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1);
                if (inq)        { buf = buf c; if (c == "\"") inq = 0; continue }
                if (c == "\"")  { inq = 1; buf = buf c; continue }
                if (c == "{")   { depth++; buf = buf c; continue }
                if (c == "}")   { depth--; buf = buf c; continue }
                if (c == "," && depth == 0) { emit(buf); buf = ""; continue }
                buf = buf c;
            }
            emit(buf);
        }
        function emit(rec,   nm, s, ty, berry, w, m) {
            if (rec == "") return;
            if (rec ~ /itemUser:/) return;
            if (rec ~ /isPokeball:true/) return;
            if (rec ~ /isNonstandard:"(CAP|Custom|Future|LGPE)"/) return;
            if (!match(rec, /name:"[^"]*"/)) return;
            nm = substr(rec, RSTART + 6, RLENGTH - 7);
            s = tolower(nm); gsub(/[^a-z0-9]+/, "-", s); sub(/^-/, "", s); sub(/-$/, "", s);
            if (s == "") return;
            berry = (rec ~ /isBerry:true/) ? 1 : 0;
            ty = "";
            if (berry) {
                if (match(rec, /type:"[^"]*"/)) ty = tolower(substr(rec, RSTART + 6, RLENGTH - 7));
            } else if (match(rec, /onPlate:"[^"]*"/)) {
                ty = tolower(substr(rec, RSTART + 9, RLENGTH - 10));   # strip onPlate:" and trailing "
            } else if (rec ~ /isGem:true/) {
                split(nm, w, " "); ty = tolower(w[1]);
            } else if (match(rec, /[A-Z][a-z]+-type (attacks|moves) have 1\./)) {
                m = substr(rec, RSTART, RLENGTH); sub(/-type.*/, "", m); ty = tolower(m);
            }
            printf "%s\t%s\t%d\n", s, ty, berry;
        }'
}

# _showdown_fetch_items
# Print Showdown items.js (a JS module) from the network. Returns 1 on failure.
# Split out so tests can stub it.
function _showdown_fetch_items {
    curl --silent --show-error --location --fail \
        --user-agent "${POKEAPI_USER_AGENT:-pokidle-bash/0.1}" \
        -- "${POKIDLE_SHOWDOWN_BASE_URL}/items.js"
}

# _showdown_excluded_item_categories
# Print one PokeAPI item slug per line for every item that is never a legal
# competitive HELD item: evolution items, mega stones, and Z-crystals. PokeAPI's
# "--held" suffix is stripped so slugs match our Showdown-derived holdable slugs.
# Best-effort: a category whose fetch fails contributes nothing (the holdable
# list stays legal, just broader).
function _showdown_excluded_item_categories {
    local c body
    for c in evolution mega-stones z-crystals; do
        if body="$(pokeapi_get "item-category/${c}")"; then
            jq -r '.items[].name' <<<"${body}"
        fi
    done | sed 's/--held$//' | sort -u
}

# _showdown_build_holdable_meta
# Force-build the holdable item metadata artifact: fetch items.js, transform to
# TSV (slug<TAB>type<TAB>isberry), drop rows whose slug is in the excluded
# PokeAPI categories, write items-holdable.tsv (atomic), and print it. Returns 1
# (writing nothing) when there is no item data.
function _showdown_build_holdable_meta {
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/items-holdable.tsv"
    local meta
    meta="$(_showdown_fetch_items | _showdown_items_meta_transform)"
    if [[ -z "${meta}" ]]; then
        return 1
    fi
    local excl
    excl="$(_showdown_excluded_item_categories)"
    meta="$(awk -F'\t' 'NR==FNR{x[$0]=1;next} !($1 in x)' <(printf '%s\n' "${excl}") - <<<"${meta}")"
    printf '%s\n' "${meta}" | atomic_write "${path}"
    printf '%s\n' "${meta}"
}

# showdown_holdable_meta
# Print the holdable item metadata (TSV). Read the shipped/built artifact if
# present (no TTL); build it once if missing. Returns 1 only when no data exists.
function showdown_holdable_meta {
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/items-holdable.tsv"
    if [[ -f "${path}" ]]; then
        cat -- "${path}"
        return 0
    fi
    _showdown_build_holdable_meta
}

# showdown_holdable_items
# Print one holdable item slug per line (field 1 of the metadata). Returns 1 when
# there is no data.
function showdown_holdable_items {
    local meta
    if ! meta="$(showdown_holdable_meta)"; then
        return 1
    fi
    cut -f1 <<<"${meta}"
}

# showdown_typed_holdable_items
# Print "<slug>\t<type>" for every holdable item that carries a type.
function showdown_typed_holdable_items {
    local meta
    if ! meta="$(showdown_holdable_meta)"; then
        return 1
    fi
    awk -F'\t' '$2 != "" && $3 == "0" {print $1 "\t" $2}' <<<"${meta}"
}

# showdown_typeless_holdable_items
# Print the slug of every holdable item with no type and that is not a berry.
function showdown_typeless_holdable_items {
    local meta
    if ! meta="$(showdown_holdable_meta)"; then
        return 1
    fi
    awk -F'\t' '$2 == "" && $3 == "0" {print $1}' <<<"${meta}"
}

# showdown_item_is_holdable <slug>
# Exit 0 if <slug> is a universally-holdable item, else exit 1 (deny). Denies
# when item data is unavailable.
function showdown_item_is_holdable {
    local slug="$1"
    local list
    if ! list="$(showdown_holdable_items)"; then
        return 1
    fi
    grep -qxF -- "${slug}" <<<"${list}"
}
