# Tests

Run all:

```
bats tests/
```

Run one file:

```
bats tests/test-db.bats
```

Tests use ephemeral SQLite files via mktemp and stub `pokeapi_get` against
JSON fixtures under `tests/fixtures/`. Each test cleans up after itself.

`pokidle rebuild-pool` is excluded from automated tests because it makes
~1000 live API calls (~2 h wall clock at the 0.5 s rate limit). Tests seed
pool fixtures directly instead.
