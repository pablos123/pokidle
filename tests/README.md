# Tests

Run all (parallel, one job per CPU — needs GNU `parallel` for `bats --jobs`;
falls back to serial without it):

```
scripts/test.bash
```

Run one file, or pass any bats flag:

```
scripts/test.bash tests/test-db.bats
scripts/test.bash --filter 'export' --timing
```

Tests use ephemeral SQLite files via mktemp and stub `pokeapi_get` against
JSON fixtures under `tests/fixtures/`. Each test cleans up after itself.

The suite never touches the network: `tests/bin/curl` shadows the real curl
and fails fast. A `run "$REPO_ROOT/pokidle" …` subprocess re-sources the libs,
so a function stub doesn't reach it — `stub_pokeapi` also lays the fixtures out
in the test's throwaway pokeapi cache dir (`seed_pokeapi_cache`), which is
what the subprocess reads. A missing fixture shows up as a blocked-URL error
in the test output instead of a slow pass against the live API.

`pokidle rebuild-pool` is excluded from automated tests because it makes
~1000 live API calls (~2 h wall clock at the 0.5 s rate limit). Tests seed
pool fixtures directly instead.
