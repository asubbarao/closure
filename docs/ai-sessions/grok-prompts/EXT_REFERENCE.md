# Extension call-shape reference (verified v1.5.4 signed, 2026-07-20)

Every grok/subagent uses THESE shapes — do not hand-roll string/NLP/geometry that these cover.

## rapidfuzz — fuzzy string similarity (0..100 ratio; 0..1 normalized)
`INSTALL rapidfuzz FROM community; LOAD rapidfuzz;`
- `rapidfuzz_ratio(a, b)` → 0..100 overall similarity. **Default for "is X a fuzzy match of Y".**
- `rapidfuzz_token_sort_ratio(a,b)` / `rapidfuzz_token_set_ratio(a,b)` → order-insensitive (good for names).
- `rapidfuzz_partial_ratio(a,b)` → best substring alignment.
- `rapidfuzz_jaro_winkler_similarity(a,b)` → 0..1, prefix-weighted (great for surnames/typos).
- Distances: `rapidfuzz_indel_distance`, `rapidfuzz_osa_distance`, `rapidfuzz_hamming_*`, `rapidfuzz_prefix_*`.
Use for: catching misspelled names ("Robyn Prce" vs "Robyn Price"), variant-form matches in search & remainder scan. Threshold e.g. `rapidfuzz_ratio(...) >= 88`.

## splink_udfs — phonetic + edit-distance + n-grams + address trie
`INSTALL splink_udfs FROM community; LOAD splink_udfs;`
- **`ngrams(LIST(any), BIGINT n) → LIST(ARRAY(any,n))`** — REPLACES the hand-rolled `v_grams` window-UNION. Feed a page's ordered word list, get n-token windows in one call.
- `unaccent(VARCHAR) → VARCHAR`, `strip_diacritics(VARCHAR)` — REPLACES the `qnorm` normalization macro (combine with `lower()`/`trim()` inline).
- `soundex(VARCHAR)`, `double_metaphone(VARCHAR) → LIST(VARCHAR)` — phonetic keys for entity/variant grouping.
- `levenshtein(a,b[,max])`, `damerau_levenshtein(a,b[,max])` → BIGINT edit distance (the `max` arg is a perf cap).
- Address trie: `build_suffix_trie(id, tokens)` (agg) + `find_address(tokens, trie[, opts...])` (scalar) — only if doing UK/UPRN-style address lookup; for US addresses prefer us_address_standardizer.
Use for: entity variant grouping (soundex/metaphone bucket + levenshtein confirm), n-gram generation, normalization.

## us_address_standardizer — parse/standardize US addresses
`INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;`
- **`addrust_parse(address VARCHAR) → STRUCT`** — no reference tables needed. Default. Returns structured fields (house number, street, city, state, zip, unit…).
- `parse_address(address)` / `standardize_address(...)` — PAGC path, needs `SELECT load_us_address_data();` once.
Use for: canonicalizing address entities (group variants under one standardized address) and address-shaped residual detection the regex misses. Call as `SELECT (addrust_parse(x)).* ` or keep the struct.

## finetype — PII/type taxonomy classifier
`INSTALL finetype FROM community; LOAD finetype;`
- `finetype(value) → VARCHAR` — dotted taxonomy, e.g. `'technology.internet.ip_v4'`, `'datetime.date.mdy_slash'`, PII types.
- `finetype_detail(value) → JSON` — `{type, confidence, broad_type}`.
- `finetype_cast(value)` — normalize for TRY_CAST; `finetype_unpack(json)` — recurse JSON.
Use for: typing detected spans (is this token an SSN/phone/date/email?) instead of ad-hoc regex classification; drives the "kind" of a residual/missed hit + confidence.

## scalarfs — read/write DuckDB variables & inline content as files
`INSTALL scalarfs FROM community; LOAD scalarfs;`
- `read_csv('variable:name')`, `read_json('variable:name')` — parse a SET VARIABLE's content as a file.
- `read_csv('data+varchar:...inline...')` — parse inline text.
- `COPY (...) TO 'variable:name' (FORMAT variable)` — capture query result into a typed variable (list/struct), not serialized text. `FORMAT variable, LIST rows|scalar`.
- `read_csv('variable:prefix_*')` — glob across variables.
Use for: replacing the `NULL::CAST` casting soup and COPY-to-temp-file dance in pdf_store; capturing a query result as a native list/struct to hand to a table function (e.g. redaction box lists) without touching disk.

## webbed — HTML/XML parse + validate (currently UNUSED, user flagged)
`INSTALL webbed FROM community; LOAD webbed;`
- `html_to_json`, `xml_to_json`, `html_extract_links`, `read_html`, and **`xml_validate_*`** (schema/well-formedness validation — the user expected this to be used).
Evaluate: validating XML/HTML documents on multi-format ingest, or export/manifest integrity. Only wire if it earns its place.

## NOTES on style (from the user's --# review)
- Coords → a `box := {x0,y0,x1,y1}` STRUCT column, not 4 loose doubles. Verbose names.
- No correlated-subselect stat views → GROUP BY / `SUMMARIZE`.
- No CROSS JOIN except UNNEST. AND/OR chains → CASE WHEN. No `COALESCE(...CASE WHEN agg())`.
- Near-zero macros. Render mega-macros → route bodies. cfg_* macros → literals/SET.
- CTAS / CREATE OR REPLACE for derived; fresh clone each run (no IF NOT EXISTS ceremony).
