# Closure PDF stress harness

Pure DuckDB + community `pdf` extension. No Python, no typst.

## Quick start

```bash
cd /path/to/closure
mkdir -p samples/stress /tmp/closure_spill
duckdb -unsigned 2>samples/stress/run.err <<'SQL'
.read tests/stress/run.sql
SQL
```

Or: `duckdb -unsigned -c ".read server/stress.sql"`

## Layout

| File | Role |
|------|------|
| `00_setup.sql` | Load `pdf`, set 512MB + spill dir, metrics table |
| `01_generate.sql` | `COPY … (FORMAT pdf)` → `samples/stress/monster.pdf` (≥5k pages) |
| `01b_generate_huge.sql` | Optional ~100k+ pages / hundreds of MB |
| `02_extract.sql` | `read_pdf_words` CTAS under 512MB |
| `03_page_vs_all.sql` | Page-scoped list vs full-doc intent |
| `04_break.sql` | PNG / text / page-range / huge info probes |
| `break_b1_all_list.sql` | Isolated full-doc `list(struct)` OOM probe |
| `05_export_metrics.sql` | CSV + JSON metrics under `samples/stress/` |
| `run.sql` | Full primary suite |

Report: [`docs/stress-test.md`](../../docs/stress-test.md).
