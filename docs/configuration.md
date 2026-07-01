# Configuration

Every knob is an environment variable. The daemon reads them from its environment, and the supported way to set them is a **systemd drop-in override**:

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
`POKIDLE_SHINY_RATE=8 pokidle tick encounter`.

## Tick cadence

Each event kind has its own interval in **seconds**. The daemon fires a kind when its timer elapses; intervals get a small random jitter within the next clock hour.

| Variable | Default | Event |
|----------|---------|-------|
| `POKIDLE_POKEMON_INTERVAL` | `3600` (1 h) | Wild Pokemon encounter. |
| `POKIDLE_ITEM_INTERVAL` | `7200` (2 h) | Biome held-item drop. |
| `POKIDLE_PICKUP_INTERVAL` | `7200` (2 h) | Biome-agnostic pickup drop (evolution/form/typeless items). |
| `POKIDLE_LEVEL_INTERVAL` | `3600` (1 h) | Level-up pass over current-week catches. |
| `POKIDLE_FRIENDSHIP_INTERVAL` | `1800` (30 min) | Friendship pass over current-week catches. |
| `POKIDLE_EVOLVE_INTERVAL` | `10800` (3 h) | Evolution pass over current-week catches. |
| `POKIDLE_LEGENDARY_INTERVAL` | `86400` (24 h) | Legendary spawn roll. |
| `POKIDLE_BIOME_HOURS` | `3` | Hours before the active biome rotates to a new one. |

## Enable / disable event kinds

Set to `0` to skip that tick in the daemon loop; the timer still advances, so it simply does nothing on fire.

| Variable | Default | Kind |
|----------|---------|------|
| `POKIDLE_POKEMON_ENABLED` | `1` | Wild encounters. |
| `POKIDLE_ITEM_ENABLED` | `1` | Biome item drops. |
| `POKIDLE_PICKUP_ENABLED` | `1` | Pickup drops. |
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
| `POKIDLE_ENCOUNTER_LEVEL_MIN` | `5` | Lower bound of a root (unevolved) species' spawn level. |
| `POKIDLE_ENCOUNTER_LEVEL_MAX` | `15` | Upper bound of a root species' spawn level. |
| `POKIDLE_LEVEL_CHANCE` | `30` | Base level-up chance per tick, applied at low level. |
| `POKIDLE_LEVEL_CHANCE_MIN` | `5` | Floor level-up chance, approached near level 100. |
| `POKIDLE_LEVEL_GAIN` | `1` | Levels added on a successful roll (capped at 100). |
| `POKIDLE_FRIENDSHIP_CHANCE` | `50` | Percent chance each eligible catch gains friendship per friendship tick. |
| `POKIDLE_FRIENDSHIP_GAIN` | `5` | Friendship points added on a successful roll (capped at 255). |

## Evolution

Per-tick evolution chance is tier-derived. Each eligible catch with a viable evolution path rolls against its tier's percent chance.

| Variable | Default | Tier |
|----------|---------|------|
| `POKIDLE_EVOLVE_CHANCE_COMMON` | `25` | Common (capture_rate ≥ 150; also the fallback for unknown tiers) |
| `POKIDLE_EVOLVE_CHANCE_UNCOMMON` | `15` | Uncommon (capture_rate ≥ 75) |
| `POKIDLE_EVOLVE_CHANCE_RARE` | `8` | Rare (capture_rate ≥ 25) |
| `POKIDLE_EVOLVE_CHANCE_VERY_RARE` | `3` | Very rare (capture_rate < 25) |

Item-based evolutions require a matching item in `item_drops`, which is consumed on use. Enable/disable the whole tick with `POKIDLE_EVOLVE_ENABLED`.

## Legendaries

The species is chosen at random among legendaries whose types intersect the active biome's types.

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_LEGENDARY_CHANCE` | `3` | Percent chance per legendary tick (daily) that one spawns. `0` = never, `100` = guaranteed. |
| `POKIDLE_LEGENDARY_LEVEL_MIN` | `50` | Lower bound of legendary spawn level. |
| `POKIDLE_LEGENDARY_LEVEL_MAX` | `70` | Upper bound of legendary spawn level. |

## Display

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_IMG_WIDTH` | `16` | Sprite width (terminal cells) for previews in `encounters` / `items`. Requires `chafa`. |
| `POKIDLE_SEPARATOR` | `-` | Character repeated to draw the row separator between `encounters` and `items` entries. |

## Event log

The daemon records one row per real tick event (encounter, item, pickup, level,
friendship, evolve, legendary) in the `event_log` table; `pokidle log` prints
them one line each. Rows older than the retention window are pruned by the
daemon on each loop, and `pokidle log` never displays rows beyond the window.

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_LOG_RETENTION_DAYS` | `7` | Days of event-log history to keep and display. |

## Notifications and sound

| Variable | Default | Meaning |
|----------|---------|---------|
| `POKIDLE_NOTIFY_POKEMON` | `1` | Wild, shiny, and legendary encounter notifications. |
| `POKIDLE_NOTIFY_ITEM` | `1` | Biome held-item drop notifications. |
| `POKIDLE_NOTIFY_PICKUP` | `1` | Pickup drop notifications. |
| `POKIDLE_NOTIFY_BIOME` | `1` | Biome rotation notifications. |
| `POKIDLE_NOTIFY_EVOLVE` | `1` | Evolution notifications. |
| `POKIDLE_NOTIFY_LEVEL` | `0` | Level-up tick notifications (per mon). |
| `POKIDLE_NOTIFY_FRIENDSHIP` | `0` | Friendship tick notifications (per mon). |
| `POKIDLE_NOTIFY_IVS_EVS` | `0` | `1` = include `IVs:`/`EVs:` lines in pokemon encounter notifications, before the moves. |

`level` and `friendship` only iterate the **current-week** encounters; older catches are never touched and never notify.

### Global toggles

| Variable | Default | Effect |
|----------|---------|--------|
| `POKIDLE_NO_NOTIFY` | `0` | `1` = print title/body to stdout instead of `notify-send`. |
| `POKIDLE_NOTIFY_TIMEOUT_MS` | `10000` | Display duration in ms. Empty = daemon default. |

### Sound toggles

| Variable | Default | Kind |
|----------|---------|------|
| `POKIDLE_SOUND_SHINY_ENABLED` | `1` | shiny encounter |
| `POKIDLE_SOUND_LEGENDARY_ENABLED` | `1` | legendary encounter |
| `POKIDLE_SOUND_ENCOUNTER_ENABLED` | `0` | normal encounter (also used by the evolve event) |
| `POKIDLE_SOUND_ITEM_ENABLED` | `0` | biome item drop |
| `POKIDLE_SOUND_PICKUP_ENABLED` | `0` | pickup drop |
| `POKIDLE_SOUND_BIOME_ENABLED` | `0` | biome rotation |
| `POKIDLE_SOUND_LEVEL_ENABLED` | `0` | level-up tick |
| `POKIDLE_SOUND_FRIENDSHIP_ENABLED` | `0` | friendship tick |

### Sprites

| Variable | Default | Effect |
|----------|---------|--------|
| `POKIDLE_FETCH_SPRITES` | `1` | `0` = never download sprites (any tick or display); only show already-cached files. |

### Sound file paths

A missing file is a silent skip. Playback uses `paplay` (PulseAudio) if available, else `aplay` (ALSA).

| Variable | Default |
|----------|---------|
| `POKIDLE_SOUND_DIR` | `$POKIDLE_DATA_DIR/sounds` |
| `POKIDLE_SOUND_ENCOUNTER` | `$POKIDLE_SOUND_DIR/encounter.ogg` |
| `POKIDLE_SOUND_SHINY` | `$POKIDLE_SOUND_DIR/shiny.ogg` |
| `POKIDLE_SOUND_LEGENDARY` | `$POKIDLE_SOUND_DIR/legendary.ogg` |
| `POKIDLE_SOUND_ITEM` | `$POKIDLE_SOUND_DIR/item.ogg` |
| `POKIDLE_SOUND_PICKUP` | `$POKIDLE_SOUND_DIR/item.ogg` |
| `POKIDLE_SOUND_BIOME` | `$POKIDLE_SOUND_DIR/biome.ogg` |
| `POKIDLE_SOUND_LEVEL` | `$POKIDLE_SOUND_DIR/level.ogg` |
| `POKIDLE_SOUND_FRIENDSHIP` | `$POKIDLE_SOUND_DIR/friendship.ogg` |

## Base directories

The XDG roots; sound, sprite, and DB paths all derive from these.

| Variable | Default | Purpose |
|----------|---------|---------|
| `POKIDLE_CONFIG_DIR` | `$XDG_CONFIG_HOME/pokidle` (`~/.config/pokidle`) | Holds `biomes.json`. |
| `POKIDLE_DATA_DIR` | `$XDG_DATA_HOME/pokidle` (`~/.local/share/pokidle`) | Holds the SQLite DB and the asset symlinks (`biomes/`, `notify/`, `sounds/`). |
| `POKIDLE_CACHE_DIR` | `$XDG_CACHE_HOME/pokidle` (`~/.cache/pokidle`) | Encounter pools (`pools/`). Sprites live under `POKEAPI_CACHE_DIR` instead. |

## Database

| Variable | Default | Purpose |
|----------|---------|---------|
| `POKIDLE_DB_PATH` | `$POKIDLE_DATA_DIR/pokidle.db` | SQLite database file. |

## PokeAPI client

Used by the daemon and the `pokidle pokeapi` subcommand.

| Variable | Default | Purpose |
|----------|---------|---------|
| `POKEAPI_CACHE_DIR` | `$POKIDLE_CACHE_DIR/pokeapi` (`~/.cache/pokidle/pokeapi`) | On-disk cache of raw PokeAPI JSON responses. |
| `POKEAPI_BASE_URL` | `https://pokeapi.co/api/v2` | API base URL. Point at a mirror or local cache if desired. |
| `POKEAPI_USER_AGENT` | `pokeapi-bash/0.1` | `User-Agent` header sent with every request. |
| `POKEAPI_RATE_LIMIT_SLEEP` | `0.5` | Seconds to sleep after each live fetch (cache misses only). |

