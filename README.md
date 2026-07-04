# pokidle

A passive Pokémon encounter daemon for the Linux desktop written in `bash`.

Non-intrusive notifications on a slow cadence: it encounters wild Pokémon, drops items, levels/befriends/evolves your current-week catches, and rarely spawns a legendary.

A CLI inspects, filters, and exports your catches for battling in Showdown.

The world has 36 type-themed biomes that rotate every few hours and decide which species, items, and berries appear.

## Dependencies

On Debian/Ubuntu, install the non-core tools pokidle needs:

```
sudo apt install jq curl sqlite3 libnotify-bin
```

Optional extras:

```
sudo apt install chafa pulseaudio-utils
```

- `chafa` — inline sprite previews.
- `pulseaudio-utils` (`paplay`) or `alsa-utils` (`aplay`) — notification sounds.

`bash`, `awk`, and `systemd` ship with a standard Debian desktop, so they need no install. The daemon runs as a systemd **user** service.

## Install

```
git clone https://github.com/pablos123/pokidle.git && ./pokidle/pokidle setup
```

Ensure `~/.local/bin` is on your `PATH`.

Install is symlink-based. **Keep the repo where it is**, moving or deleting it breaks the install.

To relocate: `uninstall`, move the clone, then `setup` again.

## Update

```
git -C <pokidle_repo_path> pull && pokidle setup
```

`setup` re-seeds any biome pool. A pool you rebuilt yourself stays newer than the shipped file and is kept. Your catches (the SQLite DB) are never touched.

## Usage

```
pokidle help
```

Every command carries its own help, e.g. `pokidle tick --help`.

pokidle reads its world data from PokeAPI's GraphQL endpoint (with the REST
helpers in `lib/api.bash` as a fallback) and Pokémon Showdown legality data. The
standalone cache-aware PokeAPI REST client that used to ship here as
`pokidle pokeapi` now lives as its own tool in a sibling `pokeapi/` project.

## Configuration

See [docs/configuration.md](docs/configuration.md).

## Adding a new generation

See [docs/add-generation.md](docs/add-generation.md).

