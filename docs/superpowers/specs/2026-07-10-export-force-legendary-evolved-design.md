# `pokidle export` — `--force-legendary` and `--force-evolved`

## Goal

Add two force flags to `pokidle export`, in the spirit of the existing
`--force-mega`/`--force-z`: bias which of the window's species land on the
6-slot team.

- `--force-legendary` — pull legendary/mythical species first, then random fill.
- `--force-evolved` — prefer mons that are, **as you actually have them**,
  further along their evolution line. It never evolves anything; it only orders
  the fill by how evolved the stored form already is.

## Background: how selection works today

`commands/export.bash` (`pokidle_export`) builds a team from stored encounters
in a window:

1. Roll the item pool and any held form-items (mega stones, Z-crystals).
2. `--force-mega`/`--force-z` compute `wanted_el` — the set of species/varieties
   a held form-item makes eligible — and from it a `forced_species` list.
3. `forced_species` is shuffled and takes the first slots; the rest of the
   species (`rest`) are shuffled uniformly and fill up to 6.
4. One random stored encounter is picked per chosen species; items are assigned.

The two new flags plug into that same shape:

- `--force-legendary` is **pull-first**, exactly like mega/z: it adds species to
  the same `forced_species` set.
- `--force-evolved` changes only how `rest` is ordered during fill: instead of a
  uniform shuffle, `rest` is bucketed by evolution tier and shuffled within each
  bucket. Pull-first picks (legendary/mega/z) still lead.

The encounters table has **no** stored legendary flag or evolution stage
(`schema.sql`), so both classifications are resolved per distinct species from
PokeAPI at export time. The lookups are gated behind the flags (plain `export`
pays nothing) and the PokeAPI cache is warm.

## Behavior

### `--force-legendary`

A window species is legendary when PokeAPI `pokemon-species/<species>` reports
`.is_legendary or .is_mythical` (matches how `lib/encounter.bash` classifies
legendaries). Every such species is appended to `forced_species` (union with any
mega/z eligibles), then the existing shuffle-and-cap-to-6 applies. If more than
6 forced species exist, the shuffle picks a random 6 (unchanged behavior).

### `--force-evolved`

Each species is classified by the position of the **stored bare species** in its
PokeAPI evolution chain (bare species is the chain-node key, same lookup `tick`
uses; `variety` is display-only and does not change the stage):

- **Tier 1 — fully evolved**: the species' chain node is terminal (empty
  `evolves_to`). Covers no-evolution mons (depth-0 terminal, e.g. Tauros),
  2-stage finals (depth-1 terminal, e.g. Vaporeon), and 3-stage finals
  (depth-2 terminal, e.g. Butterfree).
- **Tier 2 — mid**: depth-1 node that still evolves (middle of a 3-stage line,
  e.g. Metapod).
- **Tier 3 — base**: depth-0 node that still evolves (unevolved base that has an
  evolution, e.g. Caterpie / Eevee).
- **Unresolvable** (species not found in chain, or a PokeAPI fetch fails) →
  **Tier 3**. We only rank a mon as evolved when we can confirm it; when in
  doubt it sorts last.

During fill, `rest` is split into the three tiers, each tier is shuffled
independently (preserving today's randomness), and the buckets are concatenated
`t1 → t2 → t3` before taking the slots needed to reach 6.

### Composition

Pull-first wins; evolved orders the remainder:

```
Slots 1..k : legendary / mega / z holders   (forced_species, shuffled)
Slots k+1..6 : fill from rest, ordered by tier
               Tier 1 (final) shuffled, then
               Tier 2 (mid)   shuffled, then
               Tier 3 (base)  shuffled
```

Flags are independent and combine freely; passing none preserves current
behavior exactly.

## Code changes

### `lib/evolution.bash`

Two new functions, split so the classification logic is pure and unit-testable
(mirrors the existing `evolution_next_stages` split):

- `evolution_stage_tier <chain_json> <species>` — pure. One `jq` pass walks the
  chain, finds the node whose `.species.name == <species>`, and prints `1`
  (terminal), `2` (non-terminal, depth ≥ 1), or `3` (non-terminal, depth 0, or
  species not found). No I/O.
- `evolution_species_tier <species>` — thin wrapper. Fetches
  `pokemon-species/<species>` → `.evolution_chain.url` → `evolution-chain/<id>`
  (same pattern as `commands/tick.bash`), then delegates to
  `evolution_stage_tier`. Any fetch failure prints `3`.

### `lib/legendary.bash`

- `legendary_species_is <species>` — predicate. True (exit 0) when
  `pokemon-species/<species>` reports `.is_legendary or .is_mythical`; non-zero
  on a fetch failure or a non-legendary species.

### `commands/export.bash`

- Parse `--force-legendary` and `--force-evolved` (boolean flags, same shape as
  `--force-mega`); add both to `pokidle_export_help`.
- `--force-legendary`: after `forced_species` is populated from `wanted_el`,
  append every `all_species` entry for which `legendary_species_is` is true,
  before the shuffle/cap. Dedup so a species already forced by mega/z isn't
  double-added.
- `--force-evolved`: replace the single `_pokidle_shuffle rest` with a
  tier-bucketed order — classify each `rest` species via
  `evolution_species_tier`, shuffle each of the three buckets, concatenate
  `t1 t2 t3`. When the flag is off, keep the uniform `_pokidle_shuffle rest`.

All new bash follows `docs/bash-coding-standards.md` (typed `local`s, `function`
keyword, explicit conditionals, per-function doc comment, passes
`shellcheck --enable=all` and `shfmt`).

## Testing

- `tests/test-evolution.bats` — unit-test `evolution_stage_tier` against the
  existing chain fixtures (no network):
  - `evolution-chain-3.json` (caterpie→metapod→butterfree): caterpie → `3`,
    metapod → `2`, butterfree → `1`.
  - `evolution-chain-67.json` (eevee→vaporeon/jolteon): eevee → `3`,
    vaporeon → `1` (2-stage final), jolteon → `1`.
  - A species absent from the chain → `3`.
- `tests/test-legendary.bats` — `legendary_species_is` returns 0 for a legendary
  species fixture (`pokemon-species-articuno.json`) and non-zero for a
  non-legendary one (`pokemon-species-caterpie.json`), stubbing `pokeapi_get`
  the way the existing legendary tests do.

The full `pokidle_export` selection flow stays unit-tested at the helper level
(as today); the new ordering is covered through the pure `evolution_stage_tier`
and `legendary_species_is` functions rather than a DB+network integration test.

## Out of scope

- No auto-evolution during export (explicitly: classify the mon as held).
- No new stored column for legendary status or evolution stage.
- No change to plain `export`, mega/z behavior, or the item-assignment logic.
