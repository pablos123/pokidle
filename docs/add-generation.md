# Adding a new generation

When Game Freak ships a new mainline generation (and PokeAPI publishes its
data), most of pokidle picks it up **for free**. Encounter pools are not
generation-gated — they are built from the live PokeAPI `/type/<t>` listings
with no National-Dex cap — so a fresh `rebuild-pool` simply includes every new
species and form.

A handful of curated, hand-maintained tables do **not** update themselves.
They are allowlists that *fail closed*: until you extend them, new-gen content
is silently dropped (never wrongly included). This document is the checklist.

## TL;DR checklist

1. Wild species & regional forms — **automatic** (`rebuild-pool`).
2. Legendaries — add to `LEGENDARY_TYPES` (`lib/legendary.bash`).
3. Export move legality — add the new version-group(s) to the `transferable`
   map in `encounter_legal_moves` (`lib/encounter.bash`).
4. New items — add to `ENCOUNTER_ITEMS_BY_BIOME` (held) or
   `ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME` (evo stones), and to
   `ENCOUNTER_SHOWDOWN_ITEMS` if Showdown lets any mon hold it
   (`lib/encounter.bash`).
5. Export edge cases — `ENCOUNTER_EVENT_ONLY_SPECIES` (`lib/encounter.bash`)
   and irregular Showdown names in `showdown_species_name`
   (`lib/showdown.bash`).
6. Rebuild and ship the pools: `scripts/build-shipped-pools.bash`.

---

## 1. Wild encounters — automatic

`encounter_build_pool` (`lib/encounter.bash`) unions the `/type/<t>` resource
lists for each biome's types, drops legendaries/mythicals, tiers the rest by
capture rate, and records the type-coherent regional form (e.g. `meowth-galar`
in a steel biome). There is **no generation or dex-id limit anywhere** — new
species and forms appear the moment PokeAPI serves them. Nothing to edit.

Biomes themselves are a fixed catalog keyed by PokeAPI type, not by generation
(`lib/biome.bash`). A new generation needs no new biome.

## 2. Legendaries

The legendary roster is a static, hand-curated table — `/type/<t>` listings
include legendaries, but the pool builder filters them out, so the legendary
spawn system carries its own list:

```bash
# lib/legendary.bash
declare -grA LEGENDARY_TYPES=(
    # ...
    # Gen N
    [new-legendary]="type1 type2"
)
```

Add each new legendary/mythical with its PokeAPI type(s), under a `# Gen N`
comment matching the existing layout (one per line).

## 3. The exporter

`pokidle export` builds a Pokémon Showdown team from stored catches. Three
hand-maintained pieces gate what reaches a team so it always imports cleanly.

### 3a. Transferable move map (required)

`encounter_legal_moves` (`lib/encounter.bash`) keeps a move only if it is
learnable in a **transferable** version group (one that can move up the
HOME/Bank chain into the Gen 9 National Dex). The set is an allowlist:

```bash
def transferable: {
    "ruby-sapphire":1, ...,
    "scarlet-violet":1
};
```

When Gen 10 lands, add its version-group name(s) **exactly as PokeAPI reports
them**. Until you do, moves exclusive to the new gen are wrongly stripped from
exports. Leave isolated side-games (Legends Arceus, Let's Go) out — their
movepools do not transfer.

### 3b. Event-only species (as needed)

`ENCOUNTER_EVENT_ONLY_SPECIES` (`lib/encounter.bash`) lists bare species that
Showdown's validator treats as event-locked, which the pool builder's
legendary/mythical filter does not catch (e.g. the Gen IX Paradox Pokémon are
not flagged `is_legendary`/`is_mythical` in PokeAPI). The export drops these so
a team is never bounced. Add new event-locked species as they surface.

### 3c. Irregular Showdown names (as needed)

`showdown_species_name` (`lib/showdown.bash`) titlecases each hyphen segment by
default (`meowth-galar` → `Meowth-Galar`). Species whose Showdown name has
punctuation, spaces, or a lowercase tail (Mr. Mime, Type: Null, Farfetch'd,
Tapu Koko, Kommo-o, …) are mapped directly in a `case`. Add a case for any
new-gen species whose Showdown name is not just titlecased segments.

## 4. Items

Items are **not** derived from PokeAPI — they are curated tables, so new-gen
items are *not* added automatically. Three tables, all in `lib/encounter.bash`:

| Table | Purpose | When to add |
|-------|---------|-------------|
| `ENCOUNTER_ITEMS_BY_BIOME` | Held items the pool can drop, partitioned by biome (each slug in exactly one biome). | Any new held item / battle berry you want droppable. |
| `ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME` | Evolution-trigger items (stones, etc.) consumed by `lib/evolution.bash`. | New evolution items. These never reach export. |
| `ENCOUNTER_SHOWDOWN_ITEMS` | Allowlist of items Showdown accepts on *any* mon; gates export. | New item only if Showdown lets an arbitrary mon hold it. |

Rules of thumb:

- A droppable held item belongs in `ENCOUNTER_ITEMS_BY_BIOME` **and**
  `ENCOUNTER_SHOWDOWN_ITEMS` (the comment there notes every biome entry is a
  subset of the Showdown set, so any drop is export-valid).
- **Do not** add species/form-locked items (Mega Stones, Z-crystals, Silvally
  Memories, signature orbs/masks, etc.) to `ENCOUNTER_SHOWDOWN_ITEMS`. The
  export assigns items randomly across the team, so a locked item lands on the
  wrong mon and Showdown rejects the whole team. Such items may still live in
  `ENCOUNTER_ITEMS_BY_BIOME` as flavour drops — they just never get exported.
- Evolution stones go in `ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME` only.

Note on keys: associative-array slugs are quoted (`["zap-plate"]=1`) so shfmt
does not misparse the hyphen as subtraction. Follow that convention.

## 5. Rebuild and ship

After editing the tables, regenerate the shipped pools against the live API:

```bash
scripts/build-shipped-pools.bash
```

This runs `rebuild-pool` (≈2 h due to PokeAPI rate-limit sleeps) and copies the
fresh JSON into `share/pools/`. End users get the new generation when they next
run `pokidle setup`, which seeds the shipped pools into their cache.
