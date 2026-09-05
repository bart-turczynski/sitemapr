# Verification traps

Six ways this repository's own gates have reported the wrong answer, and what
to do instead. Every entry below was paid for once — the date and the issue id
name the run that found it. They are collected here because none of them is
discoverable from the code: each is a case where a check passed, or failed, for
a reason other than the one it appeared to be about.

The theme, if there is one: **a measuring instrument is as capable of being
wrong as the code it measures.** Most of these are false greens.

## 1. Measure from outside the process

A probe the code reports about itself can be satisfied by intent rather than
behavior.

`inflight_probe_note()` (`R/index-expansion.R`) reported the *intended* window
size, so `expect_gt(peak_inflight(), 1L)` in `test-concurrency-contract.R` read
as "requests overlap" and passed against a fully sequential `for` loop. That
false green is how ADR-008's bounded concurrency shipped as done with a real
in-flight count of exactly 1 (SITE-hxzmvlkn, 2026-07-29).

What settled it was a rig outside the process: a threaded local HTTP server
with a fixed delay that counted *its own* peak concurrency, plus a raw
`httr2::req_perform_parallel()` control against the same server to prove the
target was achievable at all.

Related: the suite's HTTP mocks (`httr2::local_mocked_responses`, which sets
`httr2_mock` and is honored by `req_perform_parallel` too) run
**synchronously**. No mocked test can demonstrate real overlap. Say so in the
test file rather than letting a passing assertion imply it.

**How to apply.** After a repro confirms what you expected, spend one more step
confirming it confirmed it *for the stated reason* — assert the work actually
happened (request counts, non-NULL results), not just that the timing looked
right. A run that returns suspiciously fast has usually aborted into a
`tryCatch`.

## 2. A fixture must not share a remote with the code under test

Two traps from testing the publish guard in `data-raw/backup.sh` (SITE-oungcasn,
2026-08-07). Neither is discoverable from the repo.

**Fabricated remote-tracking refs do not survive.** `git update-ref
refs/remotes/origin/<branch> <sha>` to stage a fixture gets deleted before the
code under test reads it: this repo sets `fetch.prune=true` and something in
the environment runs `git fetch --all` periodically, pruning any `origin/*` ref
the real remote lacks. It vanished twice, including *within a single shell
invocation* — so batching setup and run into one call does not save it.

**Do not reach for the existing `backup` remote as the shortcut.** `backup.sh`
mirrors to `backup` as part of its own run, which updates those very tracking
refs; the publish check then sees `ahead=0` and the test passes without ever
exercising the push. A fixture that shares a remote with the code under test is
not a fixture — it is the code under test grading itself, which is entry 1 in
another costume.

**The fix is a throwaway repo, not a seam in the script.** `BACKUP_SH_ORIGIN`
once existed in `backup.sh` for this purpose and was removed 2026-08-07
(SITE-ddyqkjwj) — do not expect to find it, and do not re-add it. Build real
bare repos in the scratchpad, wire them as `origin` and `backup`, and copy the
real script in fresh rather than testing a stale copy.

## 3. Unicode in roxygen can break the PDF manual

`R CMD check` builds a PDF manual from the generated `.Rd` files, and its LaTeX
run has no `\usepackage` coverage for arbitrary Unicode. One character it does
not know fails the whole stage:

```
* checking PDF version of manual ... WARNING
  ! LaTeX Error: Unicode character ↔ (U+2194) not set up for use with LaTeX.
* checking PDF version of manual without index ... ERROR
```

Verified 2026-08-08 against `tools/verify.R check`: `↔` (U+2194) **fails**,
while `→` (U+2192), the em dash and `§` all **pass**. So the rule is not "avoid
Unicode" — the prose style here leans on em dashes and `§` throughout. It is a
per-character gap.

This is worth knowing because of *where* it surfaces: minutes into the gate, in
the `check` stage, reported as an Rd problem rather than as the roxygen block
you actually wrote.

**How to apply.** Reword rather than debug — "the bridge between the A and B
value sets" instead of "the A ↔ B bridge". Only roxygen comments under `R/` are
gated; the same character is fine in `docs/*.md`, which never reaches LaTeX. If
the check stage reports a PDF-manual problem after a docs change, grep the diff
for exotic arrows before anything else.

## 4. air detaches a trailing `# nolint`

`air format` moves an end-of-line comment that follows `{` onto its own line,
which silently detaches a trailing `# nolint` from the line it covers. It broke
the suppression on `decompression_findings_from_problems` during the formatting
sweep (2026-07-30, SITE-cklgdzwq / SITE-dxujycqe) — verified by execution: no
lint before the reformat, flagged after.

**No local gate stage catches this.** The linter involved,
`object_length_linter`, is a lintr *default*, and `.lintr` here is built with
`defaults = list()`, so it is absent from both that config and goodpractice's
set. It is live only for whatever runs lintr's defaults, such as pkgcheck.

**How to apply.** Use a block-scoped `# nolint start: <linter>.` / `# nolint
end` pair, which air leaves in place. `R/decompression-validate.R` carries the
worked example and explains itself at the site.

A second, smaller air trap from the same sweep: air will exceed its own
`line-width` when collapsing an argument list whose value is one long
unsplittable literal. `air.toml` and `.lintr` agree at 80 and do not disagree in
general, but a collapse produced an 89-character line in
`test-discovery-engine.R`. Hoist the literal to a local. Watch for list
*names* — a URL used as a `list()` name cannot be replaced by a variable
without changing semantics; only the value side can be hoisted.

## 5. cyclocomp charges about 4 per `&&` / `||`

The `cyclocomp` package charges roughly **4 per short-circuit operator** — a
four-`&&` chain alone scores 16 — but a single vectorized `all(h[1:6] ==
c(...))` counts as about **one** branch. `all()` over a slice is cheap; the
operator chain is what inflates the score.

So a predicate written as an `&&` chain of element comparisons can often be
rewritten as one pattern-vector comparison, collapsing the score while reading
*more* like a spec table, not less. Proven on `ssrf_embedded_ipv4()`
(`R/ssrf.R`): the RFC embedding-prefix table went from 32 to 13 by turning each
`&&` prefix check into a hextet pattern vector.

**How to apply.** Before documenting a boolean-operator-driven offender as an
accepted exception, check whether its chains are element-equality comparisons
that fold into `all(... == c(...))`. Not everything does:
`ssrf_ipv6_hextets()` stays accepted because its `||` guards are heterogeneous
validity checks — length, NA, charset — not a uniform equality pattern, so no
clean fold exists. Check a candidate rewrite with `cyclocomp::cyclocomp(f)`
before committing.

## 6. Every re-impose drops the run-manifest attributes

The findings tibble's public contract is its columns, so anything the report
needs that is *about the run* rather than about a row rides as an attribute.
Three exist: `layers_run` (`R/layers-run.R`), `page_coverage` and `ruleset_run`.

**When a new one is warranted.** A per-row column cannot answer a question about
a run that produced no rows. The `ruleset` column names the selected engine per
finding, so an overlay run that finds nothing has the column with zero values in
it — the engine is unrecoverable exactly when every engine-gated check passed
cleanly. Reach for an attribute when the fact is one the *run* knows and the
*result* forgets.

**The rejected alternative is worth remembering.** Deriving the fact from
whatever rows happen to exist makes a check's reported state depend on whether
an unrelated check fired, so a cleaner sitemap would vouch for fewer checks than
a dirtier one. That non-monotonicity is the tell.

**Stamp only positive facts; absence is the safe reading.** A baseline call
stamps no `ruleset_run`, so an absent stamp reads as "no overlay proven" —
correct for a baseline run, an older result and a hand-built tibble alike.

**The trap.** `[` and `tibble::new_tibble()` both discard attributes, so every
assembly path must carry a stamp across by hand: the three `assemble_findings()`
exits, `combine_findings_contracts()` (re-read from the argument, not unioned —
one call shares one ruleset), and the page path in `R/page-findings.R`. This has
now bitten `precap_totals` (SITE-tudzmegl), `layers_run` and `ruleset_run`.
Assume it applies to the next one, and pin it with a test covering every exit.
