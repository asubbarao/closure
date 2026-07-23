# Detection: how names get matched, and the bug that hid for the life of the repo

Closure flags PII two ways. Shape detectors (`finetype`, length/format rules in
`detector_rules.json`) fire on things that *look* like PII — SSNs, phone numbers,
dates. Name matching fires on things that *are* on a case's watchlist — the known
parties, addresses, and "NOT PII" exclusions a FOIA officer seeds per case.

This doc is about the name side: why it uses three scorers, what phonetic
matching buys, the bug that made one scorer dead code without anyone noticing,
and the test that now makes that class of bug impossible to miss.

## Three scorers, because a name can be missed three ways

`name_scorers` is a table, not a `WHERE` clause. Each row names a **function**
(`scorer_fn`) and its threshold; a scorer is data, not code:

| scorer     | `scorer_fn`      | wraps                                   | catches                            |
|------------|------------------|-----------------------------------------|------------------------------------|
| `edit`     | `score_edit`     | `rapidfuzz_ratio`                       | typos that keep the spelling close |
| `jaro`     | `score_jaro`     | `jaro_winkler_similarity`               | prefix-weighted near-misses        |
| `phonetic` | `score_phonetic` | `double_metaphone` primary codes agree  | a name *heard and respelled*       |

Every scorer has one uniform shape — `score(token, term) -> 0..100` — so
`name_rule_hits` is **one scan**, not three near-identical UNION arms:
`func_apply`'s `apply(scr.scorer_fn, token, term)` picks the function by name from
the table row. Adding a fourth scorer is a macro plus one inserted row; the scan
and every downstream table follow unchanged. There are no arms to keep in sync
and no `AS scorer` alias to lose.

rapidfuzz and jaro both index **spelling**. Double Metaphone indexes **sound**:
it maps a word to a phonetic code (a short string like `KLP`), so two words that
*sound* alike collide even when they are spelled differently. `Smith` and `Smyth`
both → `SM0`. It is complementary to edit distance, not a substitute.

### The Zielinski example (why phonetic earns its seat)

Take a watchlist name `Zielinski`:

- **`Zielinsky`** — one letter changed. Edit distance 1. `rapidfuzz_ratio` scores
  this ~95, well over the 88 threshold. **Edit distance catches it.**
- **`Zelinsky`** — the `i` after `Z` is gone *and* the ending changed. Now too
  many characters differ for the ratio to clear threshold — but say it out loud:
  it is the same name. `double_metaphone('zielinski')[1]` ==
  `double_metaphone('zelinsky')[1]`. **Only the phonetic scorer catches it.**

For redaction the asymmetry is the whole argument: a **false positive** is one
reviewer click, and it lands in the `flagged` band anyway; a **false negative**
is unredacted PII shipped in a public release. Recall earns its keep, so we run
the scorer that catches the respelled name even though it fires rarely.

## The bug: a scorer that could never match

An earlier phonetic attempt computed the metaphone code of the **whole watchlist
term** and compared it against a **single document token**:

```
double_metaphone('kaleb johnson')  -> 'KLPJNS'     -- whole term, two words
double_metaphone('kaleb')          -> 'KLP'        -- one document token
double_metaphone('johnson')        -> 'JNSN'
```

`KLPJNS` is never equal to `KLP` or `JNSN`. The join condition was structurally
unsatisfiable: the detector produced **zero rows for every corpus, always**. It
was later deleted in a cleanup as "metaphone detect noise." The deletion was
correct; the stated reason was not — it was not noisy, it was dead.

The fix is to key phonetics **per token on both sides**. `watchlist_tokens`
unnests each multi-word term into its tokens and stores `double_metaphone(tok)[1]`
per token; document tokens are keyed the same way; the scorer joins token-code to
token-code. `kaleb` → `KLP` now matches `kaleb` → `KLP`.

## Why it hid: an emptiness check cannot see a dead scorer

The old `smoke.sql` asserted every table was *non-empty*. On a normal corpus the
`edit` and `jaro` scorers produce plenty of `name_rule_hits` rows, so the table
is non-empty — **whether or not the phonetic scorer contributes anything**. A
scorer that matches nothing is invisible to a "table has rows" check.

(This was worse in the old three-arm form: `name_rule_hits` was a
`UNION ALL BY NAME` of one arm per scorer, and an arm that lost its `AS scorer`
alias would not error — `BY NAME` matched columns by name and silently nulled the
discriminator. The `func_apply` scan removed the arms; the `not_null` invariant
below still guards the discriminator as cheap insurance.)

So the invariant has to be about the **trace**, not the winners. `name_rule_hits`
records *every* scorer that fired, before `name_token_match` picks one primary per
(token, term). On a correctly-spelled corpus the phonetic scorer legitimately
*wins* nothing — `edit`/`jaro` outrank it — but it must still leave **trace
rows**. Zero trace rows for a declared scorer is the "this code is dead" signal.

## The guard: declarative invariants, run by dqtest

Invariants no longer live as `CASE WHEN (SELECT …) THEN error(…)` blocks in the
boot path. They are rows in `tests/dq_tests.json` and run by the `dqtest`
extension over the model built by `server/build.sql` — see `tests/check.sql`,
invoked by `make check`. The one that would have caught this bug on day one:

```json
{"test_name":"name_scorer_never_fires","table_name":"name_scorers",
 "test_type":"custom_sql",
 "test_params":"{\"sql\":\"SELECT scorer FROM {table} ANTI JOIN name_rule_hits USING (scorer)\"}"}
```

Any scorer declared in `name_scorers` that produces no trace row in
`name_rule_hits` is returned by the `ANTI JOIN`, which fails the test and aborts
`make check` non-zero, naming the dead scorer. Reintroducing the whole-term bug
flips this test to `fail` immediately.

## The trace-table pattern (both sides share it)

Name matching mirrors the shape of the token side on purpose:

| token / shape side                | name side                        | role                                   |
|-----------------------------------|----------------------------------|----------------------------------------|
| `word_raw`                        | `words` (doc tokens)             | occurrence grain                       |
| `token_types`                     | `watchlist_tokens`               | distinct evidence, keyed for matching  |
| `kind_rules` (JSON)               | `name_scorers` (thresholds)      | configurable rules as data             |
| `token_rule_hits`                 | `name_rule_hits`                 | **every** rule/scorer that matched      |
| `token_kind` (QUALIFY row_number) | `name_token_match`               | one primary per key                    |

Keeping the full match trace — every rule that fired, not just the winner — is
what makes the invariants expressible. You assert on `name_rule_hits`, then
project the primary in `name_token_match`. A model that collapsed to the winner
first would throw away the evidence the test needs, and the dead-arm bug would
still be invisible.
