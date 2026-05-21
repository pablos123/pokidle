# Configuration

Every knob is an environment variable. The daemon reads them from its
environment, and the supported way to set them is a **systemd drop-in
override**:

```
systemctl --user edit pokidle.service
```

This opens `~/.config/systemd/user/pokidle.service.d/override.conf`. Add an
`Environment=` line per variable:

```ini
[Service]
Environment=POKIDLE_SHINY_RATE=8
Environment=POKIDLE_BIOME_HOURS=2
```

Then reload and restart:

```
systemctl --user daemon-reload && systemctl --user restart pokidle.service
```

For one-off CLI runs you can also prefix the command:
`POKIDLE_SHINY_RATE=8 pokidle tick pokemon`.

## Paths

All paths follow the XDG Base Directory spec.

| Variable | Default | Purpose |
|----------|---------|---------|
| `POKIDLE_CONFIG_DIR` | `$XDG_CONFIG_HOME/pokidle` (`~/.config/pokidle`) | Holds `biomes.json`. |
| `POKIDLE_DATA_DIR` | `$XDG_DATA_HOME/pokidle` (`~/.local/share/pokidle`) | Holds the SQLite DB and the asset symlinks (`biomes/`, `notify/`, `sounds/`). |
| `POKIDLE_CACHE_DIR` | `$XDG_CACHE_HOME/pokidle` (`~/.cache/pokidle`) | Encounter pools (`pools/`). Sprites live under `POKEAPI_CACHE_DIR` instead. |
| `POKIDLE_DB_PATH` | `$POKIDLE_DATA_DIR/pokidle.db` | SQLite database file. |

PokeAPI client (shared with the standalone `pokeapi` CLI):

| Variable | Default | Purpose |
|----------|---------|---------|
| `POKEAPI_CACHE_DIR` | `$XDG_CACHE_HOME/pokeapi` | On-disk cache of raw PokeAPI JSON responses. |
| `POKEAPI_BASE_URL` | `https://pokeapi.co/api/v2` | API base URL. Point at a mirror or local cache if desired. |
| `POKEAPI_USER_AGENT` | `pokeapi-bash/0.1` | `User-Agent` header sent with every request. |
| `POKEAPI_RATE_LIMIT_SLEEP` | `0.5` | Seconds to sleep after each live fetch (cache misses only). |

## Tick cadence

Each event kind has its own interval in **seconds**. The daemon fires a kind
when its timer elapses; intervals get a small random jitter within the next
clock hour.

| Variable | Default | Event |
|----------|---------|-------|
| `POKIDLE_POKEMON_INTERVAL` | `3600` (1 h) | Wild Pokemon encounter. |
| `POKIDLE_ITEM_INTERVAL` | `3600` (1 h) | Held-item drop. |
| `POKIDLE_LEVEL_INTERVAL` | `3600` (1 h) | Level-up pass over current-week catches. |
| `POKIDLE_FRIENDSHIP_INTERVAL` | `1800` (30 min) | Friendship pass over current-week catches. |
| `POKIDLE_EVOLVE_INTERVAL` | `10800` (3 h) | Evolution pass over current-week catches. |
| `POKIDLE_LEGENDARY_INTERVAL` | `86400` (24 h) | Legendary spawn roll. |
| `POKIDLE_BIOME_HOURS` | `3` | Hours before the active biome rotates to a new one. |

## Enable / disable event kinds

Each kind has an `*_ENABLED` toggle (default `1`). Set to `0` to skip that
tick in the daemon loop; the timer still advances, so it simply does nothing
on fire.

| Variable | Default | Kind |
|----------|---------|------|
| `POKIDLE_POKEMON_ENABLED` | `1` | Wild encounters. |
| `POKIDLE_ITEM_ENABLED` | `1` | Item drops. |
| `POKIDLE_LEVEL_ENABLED` | `1` | Level-up pass. |
| `POKIDLE_FRIENDSHIP_ENABLED` | `1` | Friendship pass. |
| `POKIDLE_EVOLVE_ENABLED` | `1` | Evolution pass. |
| `POKIDLE_LEGENDARY_ENABLED` | `1` | Legendary spawn roll. |

## Odds and rolls

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_SHINY_RATE` | `1024` | Shiny odds are `1 / N`. Lower = more shinies. |
| `POKIDLE_BERRY_RATE` | `15` | Percent chance an encounter holds a berry (`0`–`100`). |
| `POKIDLE_HIDDEN_ABILITY_RATE` | `5` | Percent chance an encounter rolls its hidden ability. |
| `POKIDLE_ENCOUNTER_LEVEL_MIN` | `5` | Lower bound of a root (unevolved) species' spawn level. Evolved stages derive their range from evolution data. |
| `POKIDLE_ENCOUNTER_LEVEL_MAX` | `15` | Upper bound of a root species' spawn level. |
| `POKIDLE_LEVEL_CHANCE` | `25` | Percent chance each eligible current-week catch gains `+1` level per level tick. |
| `POKIDLE_LEVEL_GAIN` | `1` | Levels added on a successful roll (capped at 100). |
| `POKIDLE_FRIENDSHIP_CHANCE` | `50` | Percent chance each eligible catch gains friendship per friendship tick. |
| `POKIDLE_FRIENDSHIP_GAIN` | `5` | Friendship points added on a successful roll (capped at 255). |

## Evolution

Per-tick evolution chance is tier-derived. Each eligible catch with a viable
evolution path rolls against its tier's percent chance.

| Variable | Default | Tier |
|----------|---------|------|
| `POKIDLE_EVOLVE_CHANCE_COMMON` | `25` | common (also the fallback for unknown tiers) |
| `POKIDLE_EVOLVE_CHANCE_UNCOMMON` | `15` | uncommon |
| `POKIDLE_EVOLVE_CHANCE_RARE` | `8` | rare |
| `POKIDLE_EVOLVE_CHANCE_VERY_RARE` | `3` | very_rare |

Item-based evolutions require a matching item in `item_drops`, which is
consumed on use. Enable/disable the whole tick with `POKIDLE_EVOLVE_ENABLED`
(see [Enable / disable event kinds](#enable--disable-event-kinds)).

## Legendaries

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_LEGENDARY_CHANCE` | `3` | Percent chance per legendary tick (daily) that one spawns. `0` = never, `100` = guaranteed (testing). |
| `POKIDLE_LEGENDARY_LEVEL_MIN` | `50` | Lower bound of legendary spawn level. |
| `POKIDLE_LEGENDARY_LEVEL_MAX` | `70` | Upper bound of legendary spawn level. |

The species is chosen at random among legendaries whose types intersect the
active biome's types (roster: `LEGENDARY_TYPES` in `lib/legendary.bash`).
Enable/disable the tick with `POKIDLE_LEGENDARY_ENABLED`.

## Display

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_IMG_WIDTH` | `16` | Sprite width (terminal cells) for `chafa` previews in `list` / `items`. chafa auto-selects kitty/sixel/iterm for pixel-perfect output, or symbol cells as fallback. No-op if `chafa` is not installed. |

## Notifications and sound

All desktop notifications go through `notify-send` (`lib/notify.bash`). Each
event has a `POKIDLE_NOTIFY_*` toggle (`0` = silent, `1` = notify). The daemon
and `pokidle tick ...` both honor them; the `--no-notify` CLI flag overrides to
off.

| Event | Trigger | Notify default | Notify var | Urgency | Sound (file) | Sound default |
|-------|---------|----------------|------------|---------|--------------|---------------|
| pokemon | wild encounter (`tick pokemon`) | on | `POKIDLE_NOTIFY_POKEMON` | normal | encounter.ogg | off |
| shiny | shiny encounter (subset of pokemon) | on | `POKIDLE_NOTIFY_POKEMON` | critical\* | shiny.ogg | on |
| legendary | legendary encounter (`tick legendary`) | on | `POKIDLE_NOTIFY_POKEMON` | critical\*\* | legendary.ogg\*\*\* | on |
| item | held-item drop (`tick item`) | on | `POKIDLE_NOTIFY_ITEM` | low | item.ogg | off |
| biome | biome rotation (daemon) | on | `POKIDLE_NOTIFY_BIOME` | low | biome.ogg | off |
| evolve | evolution (`tick evolve`, per mon) | on | `POKIDLE_NOTIFY_EVOLVE` | normal | encounter.ogg | off |
| level | +1 level on current-week mon (per mon) | off | `POKIDLE_NOTIFY_LEVEL` | low | level.ogg | off |
| friendship | +5 friendship on current-week mon (per mon) | off | `POKIDLE_NOTIFY_FRIENDSHIP` | low | friendship.ogg | off |

\* Shiny urgency override: `POKIDLE_NOTIFY_URGENCY_SHINY` (default `critical`).
\*\* Legendary urgency override: `POKIDLE_NOTIFY_URGENCY_LEGENDARY` (default `critical`).
\*\*\* Legendary sound falls back `POKIDLE_SOUND_LEGENDARY` → `POKIDLE_SOUND_SHINY` → encounter sound if the file is missing.

`level` and `friendship` only iterate the **current-week** encounters; older
catches are never touched and never notify.

### Global toggles

| Variable | Default | Effect |
|----------|---------|--------|
| `POKIDLE_NO_NOTIFY` | `0` | `1` = print title/body to stdout instead of `notify-send`. |
| `POKIDLE_NOTIFY_TIMEOUT_MS` | `10000` | Display duration in ms (`notify-send -t`). Empty = daemon default. Critical-urgency events (shiny/legendary) may persist regardless, depending on the notification daemon. |

### Sound toggles

Each sound kind has its own enable toggle, mirroring `POKIDLE_NOTIFY_<KIND>`.
There is no global sound switch — to mute everything set every toggle to `0`;
to hear everything set them all to `1`.

| Variable | Default | Kind |
|----------|---------|------|
| `POKIDLE_SOUND_SHINY_ENABLED` | `1` | shiny encounter |
| `POKIDLE_SOUND_LEGENDARY_ENABLED` | `1` | legendary encounter |
| `POKIDLE_SOUND_ENCOUNTER_ENABLED` | `0` | normal encounter (also used by the evolve event) |
| `POKIDLE_SOUND_ITEM_ENABLED` | `0` | item drop |
| `POKIDLE_SOUND_BIOME_ENABLED` | `0` | biome rotation |
| `POKIDLE_SOUND_LEVEL_ENABLED` | `0` | level-up tick |
| `POKIDLE_SOUND_FRIENDSHIP_ENABLED` | `0` | friendship tick |

### Sprites

Sprite art goes through the pokeapi lib (`pokemon_sprite` / `item_sprite`),
which resolves the URL from the cached API JSON and caches the image under
`$POKEAPI_CACHE_DIR/sprites/` (pokemon: `<name>-<variant>.<ext>`, items:
`sprites/items/<name>.<ext>`). Encounters/items fetch at tick time and lazily
when listing (if the cached file is gone).

| Variable | Default | Effect |
|----------|---------|--------|
| `POKIDLE_FETCH_SPRITES` | `1` | `0` = never download sprites (tick or list); only show already-cached files. |

### Sound file paths

For an enabled kind, the clip resolves to `$POKIDLE_SOUND_<KIND>` if set, else
`$POKIDLE_SOUND_DIR/<kind>.ogg`. A missing file is a silent skip. Playback uses
`paplay` (PulseAudio) if available, else `aplay` (ALSA).

| Variable | Default |
|----------|---------|
| `POKIDLE_SOUND_DIR` | `$POKIDLE_DATA_DIR/sounds` |
| `POKIDLE_SOUND_ENCOUNTER` | `$POKIDLE_SOUND_DIR/encounter.ogg` |
| `POKIDLE_SOUND_SHINY` | `$POKIDLE_SOUND_DIR/shiny.ogg` |
| `POKIDLE_SOUND_LEGENDARY` | `$POKIDLE_SOUND_DIR/legendary.ogg` |
| `POKIDLE_SOUND_ITEM` | `$POKIDLE_SOUND_DIR/item.ogg` |
| `POKIDLE_SOUND_BIOME` | `$POKIDLE_SOUND_DIR/biome.ogg` |
| `POKIDLE_SOUND_LEVEL` | `$POKIDLE_SOUND_DIR/level.ogg` |
| `POKIDLE_SOUND_FRIENDSHIP` | `$POKIDLE_SOUND_DIR/friendship.ogg` |

## Internal / test-only

Not for normal use; set by the script or the test harness.

| Variable | Purpose |
|----------|---------|
| `POKIDLE_REPO_ROOT` | Repo root, derived from the script path at startup. |
| `POKIDLE_TICK_FAST` | `1` = cadence-based scheduler (next target in `[now, now + interval)`) for smoke tests like `timeout 200 ./pokidle daemon`. Unset in normal use. |
| `POKIDLE_TEST_SOURCE_ONLY` | When `1`, sourcing `pokidle` defines functions without dispatching a command. |
| `POKIDLE_TEST_SKIP_DISPATCH` | When `1`, skips the bottom-of-file command dispatch. |
