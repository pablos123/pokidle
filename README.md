# pokidle

A passive Pokémon encounter daemon for the Linux desktop.

Non-intrusive notifications on a slow cadence: it encounters wild Pokémon, drops items, levels/befriends/evolves your current-week catches, and rarely spawns a legendary. Shinies included!

A CLI inspects, filters, and exports your catches for battling in Showdown.

The world has 36 type-themed biomes that rotate every few hours and decide which species, items, and berries appear.

## Dependencies

Required:

- `bash`, `jq`, `curl`, `sqlite3`, `notify-send`, `systemd`

Optional:

- `paplay` or `aplay` - notification sounds.
- `chafa` - inline sprite previews.

## Install

```
git clone https://github.com/pablos123/pokidle.git && ./pokidle/pokidle setup
```

Ensure `~/.local/bin` is on your `PATH`.

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

