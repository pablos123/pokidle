# Export `--force-legendary` / `--force-evolved` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two force flags to `pokidle export` — `--force-legendary` (pull legendary/mythical species first) and `--force-evolved` (order the fill by how evolved the stored mon already is).

**Architecture:** `--force-legendary` reuses the existing pull-first `forced_species` mechanism (like `--force-mega`/`--force-z`), with legendary status resolved per species from PokeAPI. `--force-evolved` replaces the uniform shuffle of the fill list with a tier-bucketed shuffle, classifying each species by its position in its PokeAPI evolution chain. Classification logic lives in a pure, unit-tested helper; a thin wrapper does the PokeAPI fetches.

**Tech Stack:** Bash (`#!/usr/bin/env bash`), `jq`, `bats` tests, PokeAPI (cached via `pokeapi_get`).

## Global Constraints

- All bash follows `docs/bash-coding-standards.md`: `function` keyword (no parens), typed `local`s (`local -i`, `local -a`, `local -n`), explicit `if/then/fi` control flow (no `&&`/`||` branching), braced+quoted expansions, one doc comment per function with a signature line.
- Must pass `shellcheck --enable=all` (project disables SC2312/SC1091/SC2310) and `shfmt -i 4 -ci --diff` with no changes. Lint via `scripts/lint.bash`.
- Tests run with `bats tests/<file>.bats`.
- PokeAPI lookups go through `pokeapi_get` (never raw `curl`); tests stub it via `stub_pokeapi` from `tests/helpers.bash`.
- New per-species PokeAPI lookups must be gated behind the flags — plain `export` performs none.
- Flags are boolean, parsed in the same `while/case` block as `--force-mega`; both appear in `pokidle_export_help`.
- Evolution stage is classified from the **bare species** (`.species`), not the variety. Unresolvable stage → Tier 3.

---

### Task 1: Pure evolution-stage classifier

Add `evolution_stage_tier`, a pure function that classifies a species' position in an evolution chain into tier 1 (fully evolved), 2 (mid), or 3 (base/unknown). No I/O — takes the chain JSON as an argument, so it is unit-testable against fixtures.

**Files:**
- Modify: `lib/evolution.bash` (add function after `evolution_next_stages`, ~line 50)
- Test: `tests/test-evolution.bats`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `evolution_stage_tier <chain_json> <species>` — prints `1`, `2`, or `3` to stdout. `1` = chain node is terminal (empty `evolves_to`); `2` = node found, non-terminal, depth ≥ 1; `3` = node found, non-terminal, depth 0, OR species not found in the chain. Always exits 0.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-evolution.bats` (after the existing tests):

```bash
@test "evolution_stage_tier: 3-stage line classifies base/mid/final" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-3.json")"
    [ "$(evolution_stage_tier "$chain" caterpie)" = "3" ]
    [ "$(evolution_stage_tier "$chain" metapod)" = "2" ]
    [ "$(evolution_stage_tier "$chain" butterfree)" = "1" ]
}

@test "evolution_stage_tier: 2-stage branch — both final forms are tier 1, base is tier 3" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-67.json")"
    [ "$(evolution_stage_tier "$chain" eevee)" = "3" ]
    [ "$(evolution_stage_tier "$chain" vaporeon)" = "1" ]
    [ "$(evolution_stage_tier "$chain" jolteon)" = "1" ]
}

@test "evolution_stage_tier: species absent from chain -> tier 3" {
    local chain
    chain="$(cat "$FIXTURE_DIR/evolution-chain-3.json")"
    [ "$(evolution_stage_tier "$chain" pidgey)" = "3" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test-evolution.bats -f "evolution_stage_tier"`
Expected: FAIL — `evolution_stage_tier: command not found`.

- [ ] **Step 3: Implement `evolution_stage_tier`**

Add to `lib/evolution.bash` immediately after `evolution_next_stages` (the closing `}` near line 50):

```bash
# evolution_stage_tier <chain_json> <species>
# Classify <species>'s position in <chain_json>. Prints:
#   1 = fully evolved (chain node is terminal — no evolves_to)
#   2 = mid-stage     (node found, still evolves, depth >= 1)
#   3 = base/unknown  (node found, still evolves, depth 0; or not in chain)
# Depth is the number of evolution steps from the chain root.
function evolution_stage_tier {
    local chain_json="$1"
    local species="$2"
    jq -r --arg sp "${species}" '
        def find($node; $d):
            if $node.species.name == $sp then
                {terminal: (($node.evolves_to | length) == 0), depth: $d}
            else
                ($node.evolves_to[]? | find(.; $d + 1))
            end;
        [ find(.chain; 0) ] | (.[0] // null) as $r
        | if $r == null then 3
          elif $r.terminal then 1
          elif $r.depth == 0 then 3
          else 2 end
    ' <<<"${chain_json}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test-evolution.bats -f "evolution_stage_tier"`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint**

Run: `bash scripts/lint.bash`
Expected: no `shfmt`/`shellcheck` output for `lib/evolution.bash`.

- [ ] **Step 6: Commit**

```bash
git add lib/evolution.bash tests/test-evolution.bats
git commit -m "evolution-stage-tier"
```

---

### Task 2: Evolution-tier fetch wrapper

Add `evolution_species_tier`, the thin wrapper that fetches a species' evolution chain from PokeAPI and delegates to `evolution_stage_tier`. Any fetch failure prints `3`.

**Files:**
- Modify: `lib/evolution.bash` (add function directly after `evolution_stage_tier`)
- Test: `tests/test-evolution.bats`

**Interfaces:**
- Consumes: `evolution_stage_tier <chain_json> <species>` (Task 1).
- Produces: `evolution_species_tier <species>` — prints `1`, `2`, or `3`. Fetches `pokemon-species/<species>` then `evolution-chain/<id>` via `pokeapi_get`; prints `3` if either fetch fails or the species has no `evolution_chain.url`. Always exits 0.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-evolution.bats`. These use `stub_pokeapi` (fixtures `pokemon-species-caterpie.json`, `pokemon-species-metapod.json`, `pokemon-species-butterfree.json` all point at `evolution-chain-3.json`, which is present):

```bash
@test "evolution_species_tier: fetches chain and classifies base/mid/final" {
    stub_pokeapi
    [ "$(evolution_species_tier caterpie)" = "3" ]
    [ "$(evolution_species_tier metapod)" = "2" ]
    [ "$(evolution_species_tier butterfree)" = "1" ]
}

@test "evolution_species_tier: missing species fixture -> tier 3" {
    stub_pokeapi
    [ "$(evolution_species_tier nosuchmon 2>/dev/null)" = "3" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test-evolution.bats -f "evolution_species_tier"`
Expected: FAIL — `evolution_species_tier: command not found`.

- [ ] **Step 3: Implement `evolution_species_tier`**

Add to `lib/evolution.bash` immediately after `evolution_stage_tier`. Note `pokeapi_get` is already available (evolution.bash sources `encounter.bash`, which provides it; in tests it is stubbed):

```bash
# evolution_species_tier <species>
# Resolve <species>'s evolution chain from PokeAPI and classify its stage via
# evolution_stage_tier. Prints 1/2/3; prints 3 when the species or its chain
# cannot be fetched (so an unconfirmed mon never outranks a confirmed one).
function evolution_species_tier {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}" 2>/dev/null)"; then
        printf '3'
        return
    fi
    local chain_url
    chain_url="$(jq -r '.evolution_chain.url // ""' <<<"${spec}")"
    if [[ -z "${chain_url}" || "${chain_url}" == "null" ]]; then
        printf '3'
        return
    fi
    local chain_id="${chain_url%/}"
    chain_id="${chain_id##*/}"
    local chain
    if ! chain="$(pokeapi_get "evolution-chain/${chain_id}" 2>/dev/null)"; then
        printf '3'
        return
    fi
    evolution_stage_tier "${chain}" "${species}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test-evolution.bats -f "evolution_species_tier"`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint**

Run: `bash scripts/lint.bash`
Expected: no output for `lib/evolution.bash`.

- [ ] **Step 6: Commit**

```bash
git add lib/evolution.bash tests/test-evolution.bats
git commit -m "evolution-species-tier-wrapper"
```

---

### Task 3: Legendary species predicate

Add `legendary_species_is`, a predicate that returns success when a species is legendary or mythical per PokeAPI.

**Files:**
- Modify: `lib/legendary.bash` (add function at end of file)
- Test: `tests/test-legendary.bats`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `legendary_species_is <species>` — exit 0 when `pokemon-species/<species>` reports `.is_legendary or .is_mythical`; non-zero on fetch failure or a non-legendary species. Prints nothing.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-legendary.bats` (fixtures `pokemon-species-articuno.json` has `is_legendary: true`; `pokemon-species-caterpie.json` has both false):

```bash
@test "legendary_species_is: true for a legendary species" {
    stub_pokeapi
    run legendary_species_is articuno
    [ "$status" -eq 0 ]
}

@test "legendary_species_is: false for a non-legendary species" {
    stub_pokeapi
    run legendary_species_is caterpie
    [ "$status" -ne 0 ]
}

@test "legendary_species_is: false when the species fetch fails" {
    stub_pokeapi
    run legendary_species_is nosuchmon
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test-legendary.bats -f "legendary_species_is"`
Expected: FAIL — `legendary_species_is: command not found`.

- [ ] **Step 3: Implement `legendary_species_is`**

Add at the end of `lib/legendary.bash`:

```bash
# legendary_species_is <species>
# True (exit 0) when PokeAPI marks <species> is_legendary or is_mythical.
# Non-zero on a fetch failure or an ordinary species.
function legendary_species_is {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}" 2>/dev/null)"; then
        return 1
    fi
    jq -e '(.is_legendary // false) or (.is_mythical // false)' <<<"${spec}" >/dev/null
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test-legendary.bats -f "legendary_species_is"`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint**

Run: `bash scripts/lint.bash`
Expected: no output for `lib/legendary.bash`.

- [ ] **Step 6: Commit**

```bash
git add lib/legendary.bash tests/test-legendary.bats
git commit -m "legendary-species-predicate"
```

---

### Task 4: Wire flags into `pokidle export`

Parse `--force-legendary` and `--force-evolved`, document them in help, and apply them: legendary species join the pull-first `forced_species` set; `--force-evolved` orders the fill by evolution tier.

**Files:**
- Modify: `commands/export.bash`
  - Help text: `pokidle_export_help` (~lines 16-20)
  - Flag vars + parsing: `pokidle_export` (~lines 56-81)
  - `forced_species` assembly (~lines 192-199)
  - `rest` ordering (~lines 200-211)
- Test: covered by Tasks 1-3 unit tests + a manual smoke check (below). No new bats file — the full selection flow needs a live DB + network and is intentionally not integration-tested (matches existing `test-export.bats` scope).

**Interfaces:**
- Consumes: `legendary_species_is <species>` (Task 3), `evolution_species_tier <species>` (Task 2). Both are already sourced: `commands/export.bash` runs inside the `pokidle` entrypoint which sources all libs.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add help text**

In `pokidle_export_help`, add two lines to the `Options:` block after the `--force-z` line (line 19):

```
  --force-legendary Pull legendary/mythical mons first
  --force-evolved   Prefer mons you hold in a more-evolved form
```

- [ ] **Step 2: Declare the flag variables**

In `pokidle_export`, after `local -i force_z=0` (line 59), add:

```bash
    local -i force_legendary=0
    local -i force_evolved=0
```

- [ ] **Step 3: Parse the flags**

In the `while/case` block, after the `--force-z)` arm (lines 78-81), add:

```bash
            --force-legendary)
                force_legendary=1
                shift
                ;;
            --force-evolved)
                force_evolved=1
                shift
                ;;
```

- [ ] **Step 4: Add legendary species to the pull-first set**

The current block (lines 192-199) is:

```bash
    # Selection: forced-eligible species first (shuffled), then random fill to 6.
    local -a forced_species=()
    if [[ "${wanted_el}" != "[]" ]]; then
        mapfile -t forced_species < <(jq -r --argjson el "${wanted_el}" \
            '[.[] | select(((.species) as $s | $el | index($s)) or ((.variety) as $v | $v != null and ($el | index($v)))) | .species] | unique | .[]' <<<"${rows}")
    fi
    _pokidle_shuffle forced_species
```

Replace it with (adds a legendary pass that unions into `forced_species`, deduped):

```bash
    # Selection: forced-eligible species first (shuffled), then fill to 6.
    local -a forced_species=()
    if [[ "${wanted_el}" != "[]" ]]; then
        mapfile -t forced_species < <(jq -r --argjson el "${wanted_el}" \
            '[.[] | select(((.species) as $s | $el | index($s)) or ((.variety) as $v | $v != null and ($el | index($v)))) | .species] | unique | .[]' <<<"${rows}")
    fi
    # --force-legendary: pull legendary/mythical species first, alongside any
    # held-item eligibles. Union (deduped) into the same pull-first set.
    if ((force_legendary)); then
        local leg_sp
        for leg_sp in "${all_species[@]}"; do
            if [[ " ${forced_species[*]} " == *" ${leg_sp} "* ]]; then
                continue
            fi
            if legendary_species_is "${leg_sp}"; then
                forced_species+=("${leg_sp}")
            fi
        done
    fi
    _pokidle_shuffle forced_species
```

- [ ] **Step 5: Order the fill by evolution tier**

The current block (lines 200-211) is:

```bash
    local -a species=("${forced_species[@]:0:6}")
    local -a rest=()
    local s
    for s in "${all_species[@]}"; do
        if [[ " ${species[*]} " != *" ${s} "* ]]; then
            rest+=("${s}")
        fi
    done
    _pokidle_shuffle rest
    local -i need=$((6 - ${#species[@]}))
    if ((need > 0 && ${#rest[@]} > 0)); then
        species+=("${rest[@]:0:need}")
    fi
```

Replace the `_pokidle_shuffle rest` line with a tier-bucketed order when `--force-evolved` is set (everything else in the block is unchanged):

```bash
    local -a species=("${forced_species[@]:0:6}")
    local -a rest=()
    local s
    for s in "${all_species[@]}"; do
        if [[ " ${species[*]} " != *" ${s} "* ]]; then
            rest+=("${s}")
        fi
    done
    if ((force_evolved)); then
        # Prefer more-evolved mons in the fill: bucket by stage tier (1=final,
        # 2=mid, 3=base/unknown), shuffle within each, then concatenate.
        local -a evo_t1=() evo_t2=() evo_t3=()
        local rs tier
        for rs in "${rest[@]}"; do
            tier="$(evolution_species_tier "${rs}")"
            case "${tier}" in
                1) evo_t1+=("${rs}") ;;
                2) evo_t2+=("${rs}") ;;
                *) evo_t3+=("${rs}") ;;
            esac
        done
        _pokidle_shuffle evo_t1
        _pokidle_shuffle evo_t2
        _pokidle_shuffle evo_t3
        rest=("${evo_t1[@]}" "${evo_t2[@]}" "${evo_t3[@]}")
    else
        _pokidle_shuffle rest
    fi
    local -i need=$((6 - ${#species[@]}))
    if ((need > 0 && ${#rest[@]} > 0)); then
        species+=("${rest[@]:0:need}")
    fi
```

- [ ] **Step 6: Lint**

Run: `bash scripts/lint.bash`
Expected: no output for `commands/export.bash`.

- [ ] **Step 7: Verify help renders both flags**

Run: `./pokidle export --help`
Expected output contains:
```
  --force-legendary Pull legendary/mythical mons first
  --force-evolved   Prefer mons you hold in a more-evolved form
```

- [ ] **Step 8: Smoke-test against the real DB (warm cache)**

Run (window widened so there is data to select from):
```bash
./pokidle export --force-evolved --since "60 days ago"
./pokidle export --force-legendary --since "60 days ago"
./pokidle export --force-legendary --force-evolved --since "60 days ago"
```
Expected: each prints an importable Showdown team (up to 6 sets) with no error. `--force-evolved` should visibly bias toward final-evolution mons when the window holds a mix; `--force-legendary` should surface any legendaries in the window first. (If the window has no encounters, widen `--since` further.)

- [ ] **Step 9: Run the full test suite**

Run: `bats tests/`
Expected: all tests pass (no regressions in `test-export.bats`, `test-evolution.bats`, `test-legendary.bats`).

- [ ] **Step 10: Commit**

```bash
git add commands/export.bash
git commit -m "export-force-legendary-evolved"
```

---

## Self-Review

**Spec coverage:**
- `--force-legendary` pull-first via PokeAPI legendary/mythical → Task 3 (predicate) + Task 4 Step 4 (union into `forced_species`). ✓
- `--force-evolved` tier ordering (T1 terminal / T2 mid / T3 base+unknown), classified from bare species, no auto-evolution → Task 1 (pure classifier) + Task 2 (fetch wrapper) + Task 4 Step 5 (bucketed fill). ✓
- Unresolvable chain → Tier 3 → Task 1 (`null`/absent → 3) and Task 2 (fetch failure → 3). ✓
- Composition: pull-first leads, evolved orders the rest → Task 4 keeps `forced_species[@]:0:6` first, only reorders `rest`. ✓
- Lookups gated behind flags → Task 4 guards both passes with `((force_legendary))` / `((force_evolved))`. ✓
- Help text updated → Task 4 Step 1. ✓
- Tests against existing fixtures → Tasks 1-3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type/name consistency:** `evolution_stage_tier` (Task 1) called by `evolution_species_tier` (Task 2); `evolution_species_tier` and `legendary_species_is` called in Task 4 Steps 4-5 with matching names and single-species-string argument. Flag vars `force_legendary`/`force_evolved` declared (Step 2), parsed (Step 3), and consumed (Steps 4-5) consistently. ✓
