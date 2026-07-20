# ext-platform spikes

Companion to `docs/ext-survey-platform.md`.

| File | Extension | Requires |
|------|-----------|----------|
| `01_duck_diff.sql` | duck_diff | DuckDB **≥ 1.5.4** |
| `02_ggsql.sql` | ggsql | DuckDB ≥ 1.5.3; set `GGSQL_NO_OPEN_BROWSER=1` |

```bash
# example with a local 1.5.4 CLI
GGSQL_NO_OPEN_BROWSER=1 /path/to/duckdb-1.5.4 -unsigned -markdown < 01_duck_diff.sql
GGSQL_NO_OPEN_BROWSER=1 /path/to/duckdb-1.5.4 -unsigned -markdown < 02_ggsql.sql
```

Captured runs: `01_duck_diff.out`, `02_ggsql.out`.
