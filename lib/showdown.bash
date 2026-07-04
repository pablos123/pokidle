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
        --user-agent "${POKIDLE_POKEAPI_USER_AGENT:-pokidle-bash/0.1}" \
        -- "${POKIDLE_SHOWDOWN_BASE_URL}/${file}.json"
}

# _showdown_cached_fetch <path> <fetch-cmd...>
# TTL-cache helper: serve a fresh cache at <path>; otherwise run <fetch-cmd>,
# cache its stdout, and print it; on fetch failure fall back to a stale cache if
# present. Returns 1 only when there is no data at all.
function _showdown_cached_fetch {
    local path="$1"
    shift
    if [[ -f "${path}" ]]; then
        local now mtime
        now="$(date +%s)"
        mtime="$(stat -c %Y -- "${path}" 2>/dev/null || date -r "${path}" +%s)"
        if ((now - mtime < POKIDLE_SHOWDOWN_TTL)); then
            cat -- "${path}"
            return 0
        fi
    fi
    local body
    if body="$("$@")"; then
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

# showdown_get <file>
# Print cached JSON for <file> (pokedex|learnsets|moves). Serve a fresh cache
# directly; otherwise refetch and cache; on fetch failure fall back to a stale
# cache if present. Returns 1 only when there is no data at all.
function showdown_get {
    local file="$1"
    _showdown_cached_fetch "${POKIDLE_SHOWDOWN_CACHE_DIR}/${file}.json" _showdown_fetch "${file}"
}

# showdown_items_raw
# Print Showdown's raw items.js (a JS module), TTL-cached on disk exactly like
# the JSON data files, so rebuilding the holdable artifact reuses the cache
# instead of hitting the network. Returns 1 only when there is no data at all.
function showdown_items_raw {
    _showdown_cached_fetch "${POKIDLE_SHOWDOWN_CACHE_DIR}/items.js" _showdown_fetch_items
}

# _showdown_resolve_id <name> <pokedex-json>
# Showdown id that actually exists in the pokedex for <name>: the full id when
# present, else the bare species (first hyphen segment). PokeAPI default-forme
# names (shaymin-land, giratina-altered, deoxys-normal, tornadus-incarnate, …)
# fold to the base Showdown key, while genuine alternate formes (shaymin-sky,
# thundurus-therian) keep their own key. Prints the full id unchanged when
# neither resolves, so the caller's own "unknown id" path returns 1.
function _showdown_resolve_id {
    local id
    id="$(showdown_id "$1")"
    local pokedex="$2"
    if jq -e --arg i "${id}" 'has($i)' <<<"${pokedex}" >/dev/null; then
        printf '%s' "${id}"
        return
    fi
    local bid
    bid="$(showdown_id "${1%%-*}")"
    if jq -e --arg i "${bid}" 'has($i)' <<<"${pokedex}" >/dev/null; then
        printf '%s' "${bid}"
        return
    fi
    printf '%s' "${id}"
}

# showdown_species_name <variety-slug>
# Print the canonical Pokémon Showdown display name for a PokeAPI species/variety
# slug (Great Tusk, Mr. Mime, Meowth-Galar, …). Default-forme slugs fold to the
# base key. Returns 1 when Showdown data is unavailable or the slug is unknown.
function showdown_species_name {
    local pokedex
    if ! pokedex="$(showdown_get pokedex)"; then
        return 1
    fi
    local id
    id="$(_showdown_resolve_id "$1" "${pokedex}")"
    local name
    name="$(jq -r --arg i "${id}" '.[$i].name // empty' <<<"${pokedex}")"
    if [[ -z "${name}" ]]; then
        return 1
    fi
    printf '%s' "${name}"
}

# showdown_legal_abilities <variety-slug>
# Print "<ability-slug>\t<hidden>" per legal ability of the forme. hidden=1 for
# the "H" key. Abilities are forme-specific. Returns 1 if the id is unknown.
function showdown_legal_abilities {
    local pokedex
    if ! pokedex="$(showdown_get pokedex)"; then
        return 1
    fi
    local id
    id="$(_showdown_resolve_id "$1" "${pokedex}")"
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
    local pokedex learn moves
    if ! pokedex="$(showdown_get pokedex)"; then return 1; fi
    if ! learn="$(showdown_get learnsets)"; then return 1; fi
    if ! moves="$(showdown_get moves)"; then return 1; fi
    local id
    id="$(_showdown_resolve_id "$1" "${pokedex}")"

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
            if [[ -n "${k}" && -z "${seen[${k}]:-}" ]]; then
                seen[${k}]=1
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
# isPokeball:true, and no isNonstandard key at all (any value — Past/Future/CAP/
# Unobtainable — marks a non-current-gen item: megas, Z-crystals, gems, fossils,
# drives, old berries, fan-made). items.js is a JS object literal (not JSON);
# item strings contain no braces and no escaped quotes, so a brace-depth +
# quote-state scanner splits items unambiguously.
function _showdown_items_meta_transform {
    # Strip the `exports.BattleItems = {` prefix and the trailing `};`.
    sed -E 's/^[^{]*\{//; s/\};?[[:space:]]*$//' |
        awk '
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
            # Any isNonstandard value (Past/Future/CAP/Unobtainable/…) means the
            # item is not a current-gen legal held item: megas, Z-crystals, gems,
            # fossils, drives, old berries, fan-made items all carry it.
            if (rec ~ /isNonstandard:/) return;
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
        --user-agent "${POKIDLE_POKEAPI_USER_AGENT:-pokidle-bash/0.1}" \
        -- "${POKIDLE_SHOWDOWN_BASE_URL}/items.js"
}

# _showdown_excluded_item_categories
# Print one PokeAPI item slug per line for items that survive the isNonstandard
# filter (no key) but are still never a team held item:
#   - evolution: Fire Stone etc. are standard yet inert when held (evolution
#     mechanic / item_drops).
#   - all-machines: TMs/TRs. Today's TRs are isNonstandard:Past (already dropped),
#     so this is a safety net against a future standard machine item.
# Mega stones and Z-crystals are isNonstandard:Past and dropped by the transform,
# so no category is needed for them. PokeAPI's "--held" suffix is stripped so
# slugs match our Showdown-derived holdable slugs. Best-effort: a fetch failure
# contributes nothing (the holdable list stays legal, just broader).
function _showdown_excluded_item_categories {
    local c body
    for c in evolution all-machines; do
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
    meta="$(showdown_items_raw | _showdown_items_meta_transform)"
    if [[ -z "${meta}" ]]; then
        return 1
    fi
    local excl
    excl="$(_showdown_excluded_item_categories)"
    meta="$(awk -F'\t' 'NR==FNR{x[$0]=1;next} !($1 in x)' <(printf '%s\n' "${excl}") - <<<"${meta}")"
    # Annotate rows whose Showdown slug differs from the PokeAPI item slug with a
    # 4th column (the PokeAPI slug) so sprite/world-data fetches resolve. Identity
    # rows keep 3 columns. Best-effort: no name index -> resolver returns identity
    # -> no annotations.
    local annotated="" line slug pokeapi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        slug="${line%%$'\t'*}"
        pokeapi="$(_showdown_resolve_pokeapi_slug "${slug}")"
        if [[ "${pokeapi}" != "${slug}" ]]; then
            annotated+="${line}"$'\t'"${pokeapi}"$'\n'
        else
            annotated+="${line}"$'\n'
        fi
    done <<<"${meta}"
    meta="${annotated%$'\n'}"
    printf '%s\n' "${meta}" | atomic_write "${path}"
    printf '%s\n' "${meta}"
}

# _showdown_form_items_transform
# Read Showdown items.js on stdin; print TSV rows
# <item-slug>\t<eligible-slug>\t<class> for species-specific FORM items only: an
# item with itemUser AND one of megaStone / isPrimalOrb:true / zMove. class is
# mega|primal|z. One row per itemUser entry. Generic type Z-crystals (no
# itemUser) and plain items are skipped; Future/CAP/etc excluded (only none or
# Past). Same brace-depth/quote scanner as the holdable transform.
function _showdown_form_items_transform {
    sed -E 's/^[^{]*\{//; s/\};?[[:space:]]*$//' |
        awk '
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
        function slug(x,   s) { s = tolower(x); gsub(/[^a-z0-9]+/, "-", s); sub(/^-/, "", s); sub(/-$/, "", s); return s }
        function emit(rec,   nm, it, users, j, u, cls) {
            if (rec == "") return;
            if (rec !~ /itemUser:/) return;
            if (rec !~ /megaStone:/ && rec !~ /isPrimalOrb:true/ && rec !~ /zMove:/) return;
            # Only real items: no isNonstandard, or isNonstandard:"Past" (mega/Z/
            # primal are past-gen but real). Future/CAP/Unobtainable are not.
            if (rec ~ /isNonstandard:/ && rec !~ /isNonstandard:"Past"/) return;
            if (!match(rec, /name:"[^"]*"/)) return;
            nm = slug(substr(rec, RSTART + 6, RLENGTH - 7));
            if (nm == "") return;
            cls = (rec ~ /megaStone:/) ? "mega" : (rec ~ /isPrimalOrb:true/) ? "primal" : "z";
            if (!match(rec, /itemUser:\[[^]]*\]/)) return;
            it = substr(rec, RSTART + 9, RLENGTH - 10);   # inside the [ ]
            j = split(it, users, ",");
            for (u = 1; u <= j; u++) {
                gsub(/[" ]/, "", users[u]);
                if (users[u] != "") printf "%s\t%s\t%s\n", nm, slug(users[u]), cls;
            }
        }'
}

# _showdown_build_form_items_meta
# Force-build the form-item registry artifact from the cached items.js, write
# form-items.tsv (atomic), and print it. Returns 1 (writing nothing) when there
# is no data.
function _showdown_build_form_items_meta {
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
    local meta
    meta="$(showdown_items_raw | _showdown_form_items_transform)"
    if [[ -z "${meta}" ]]; then
        return 1
    fi
    printf '%s\n' "${meta}" | atomic_write "${path}"
    printf '%s\n' "${meta}"
}

# showdown_form_items_meta
# Print the form-item registry (TSV item-slug<TAB>eligible-slug). Read the
# shipped/built artifact if present (no TTL); build it once if missing.
function showdown_form_items_meta {
    local path="${POKIDLE_SHOWDOWN_CACHE_DIR}/form-items.tsv"
    if [[ -f "${path}" ]]; then
        cat -- "${path}"
        return 0
    fi
    _showdown_build_form_items_meta
}

# showdown_form_item_slugs
# Print each distinct form-item slug (field 1), the pool of droppable form-items.
# Returns 1 when there is no registry data.
function showdown_form_item_slugs {
    local meta
    if ! meta="$(showdown_form_items_meta)"; then
        return 1
    fi
    cut -f1 <<<"${meta}" | sort -u
}

# showdown_form_items_for_species <species> <variety>
# Print each form-item slug eligible for the mon (its eligible-slug equals the
# bare species OR the variety). Returns non-zero when none match.
function showdown_form_items_for_species {
    local species="$1"
    local variety="$2"
    local meta
    if ! meta="$(showdown_form_items_meta)"; then
        return 1
    fi
    local out
    out="$(awk -F'\t' -v sp="${species}" -v va="${variety}" \
        '$2 == sp || $2 == va {print $1}' <<<"${meta}")"
    if [[ -z "${out}" ]]; then
        return 1
    fi
    printf '%s\n' "${out}"
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

# showdown_item_name_index_query
# The GraphQL query behind showdown_item_name_index: every PokeAPI item slug
# with its English display name. Split out so it can be stubbed in tests.
function showdown_item_name_index_query {
    printf '%s' 'query { item { name itemnames(where:{language:{name:{_eq:"en"}}}) { name } } }'
}

# showdown_item_name_index
# Print "<pokeapi_slug>\t<name-key>" for every PokeAPI item, where <name-key> is
# the item's English display name normalized like a Showdown slug (lowercase,
# non-alnum runs -> '-', trimmed). PokeAPI stores the Showdown display name as
# its English item name, so this key lets a Showdown-derived slug join to the
# PokeAPI slug even when the two slugs differ. Cached via pokeapi_graphql.
# Returns 1 when the query yields nothing.
function showdown_item_name_index {
    local json
    if ! json="$(pokeapi_graphql item-names "$(showdown_item_name_index_query)")"; then
        return 1
    fi
    jq -r '
        .data.item[]
        | select((.itemnames | length) > 0)
        | (.itemnames[0].name
           | ascii_downcase | gsub("[^a-z0-9]+"; "-")
           | sub("^-+"; "") | sub("-+$"; "")) as $key
        | select($key != "")
        | "\(.name)\t\($key)"
    ' <<<"${json}"
}

# _showdown_resolve_pokeapi_slug <showdown_slug>
# Map a Showdown-derived item slug to the PokeAPI item slug used for world-data
# (sprite) fetches, using the name index (PokeAPI slug<TAB>normalized-English-name
# key). Showdown identity is authoritative; this only bridges to PokeAPI's slug
# when Showdown's differs (apostrophes -> "king-s-rock" vs "kings-rock", or genuine
# renames -> "pretty-feather" vs "pretty-wing"). Rules, in order:
#   1. Slug is already a valid PokeAPI slug   -> itself.
#   2. Slug matches exactly one name key      -> that PokeAPI slug.
#   3. Otherwise (unknown, or ambiguous key)  -> itself (graceful; never guess a
#      wrong sprite). Prints the input slug unchanged when the index is missing.
function _showdown_resolve_pokeapi_slug {
    local slug="$1"
    local idx
    if ! idx="$(showdown_item_name_index)" || [[ -z "${idx}" ]]; then
        printf '%s\n' "${slug}"
        return 0
    fi
    # Rule 1: already a PokeAPI slug (field 1).
    if awk -F'\t' -v s="${slug}" '$1 == s {f = 1} END {exit !f}' <<<"${idx}"; then
        printf '%s\n' "${slug}"
        return 0
    fi
    # Rules 2/3: unique name-key match (field 2) -> its slug, else identity.
    local matches
    matches="$(awk -F'\t' -v s="${slug}" '$2 == s {print $1}' <<<"${idx}")"
    if [[ -n "${matches}" && "$(wc -l <<<"${matches}")" -eq 1 ]]; then
        printf '%s\n' "${matches}"
    else
        printf '%s\n' "${slug}"
    fi
    return 0
}

# showdown_item_pokeapi_slug <slug>
# Print the PokeAPI item slug for a Showdown item slug: column 4 of the holdable
# metadata when present (a renamed item), else the slug unchanged. Unknown slugs
# (e.g. evolution-item drops not in the holdable table) pass through. This is the
# one PokeAPI-boundary translation: pool/db/export keep the Showdown slug; only
# world-data (sprite) fetches go through here.
function showdown_item_pokeapi_slug {
    local slug="$1"
    local meta out
    if ! meta="$(showdown_holdable_meta 2>/dev/null)"; then
        printf '%s\n' "${slug}"
        return 0
    fi
    out="$(awk -F'\t' -v s="${slug}" \
        '$1 == s { print ($4 != "" ? $4 : $1); exit }' <<<"${meta}")"
    printf '%s\n' "${out:-${slug}}"
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
