# pokidle

A passive Pokemon encounter daemon for the Linux desktop.

Non intruvise notifications that, on a slow cadence, _encounters_ wild Pokemon, drops items, levels/befriends/evolves your current-week catches, and rarely spawns a legendary. Shinies included!

A CLI inspects, filters, and exports your catches for battling in Showdown.

The world has 36 type-themed biomes that rotate every few hours and decide which species, items, and berries appear.

## Dependencies

Required:

- `bash` 4+, `jq`, `curl`, `sqlite3`, `awk`
- `notify-send` (libnotify)
- `systemd` (user instance) — the daemon runs as a user service

Optional:

- `paplay` or `aplay` — notification sounds
- `chafa` — inline sprite previews in `list` / `items` (auto-uses kitty/sixel for pixel-perfect output where supported)

## Quickstart

Ensure `~/.local/bin` is on your `PATH`.

```
git clone https://github.com/pablos123/pokidle.git && cd pokidle && ./pokidle setup
```

Install is symlink-based. **Keep the repo where it is**, moving or deleting it breaks the install.

To relocate: `uninstall`, move the clone, then `setup` again.

## Usage

```
pokidle help
```

`pokeapi` is a standalone cache-aware PokeAPI client, independent of the daemon:

```
pokeapi help
```

## Configuration

See [docs/configuration.md](docs/configuration.md).

## Notes

- Data is rolled against the live [PokeAPI](https://pokeapi.co) (cached on disk)
  and stored in a local SQLite database at `$POKIDLE_DB_PATH`.
- Shipped pools skip the cold rebuild, but the first `tick` of each kind still
  fetches species/nature/move data from PokeAPI (cached after), so the daemon
  needs network on first run.
