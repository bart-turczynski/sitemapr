## R CMD check results

Checked with `R CMD check --as-cran` on:

- macOS aarch64 (R 4.6.0, local)

Result: **0 errors | 0 warnings | 1 note**

---

### Note

`checking CRAN incoming feasibility ... NOTE` — the usual new-submission note,
covering:

* **New submission.** This is the first CRAN submission of `sitemapr`.
* **`Remotes` field in DESCRIPTION.** `sitemapr` depends on `rurl` and
  (optionally) `robotstxtr`, which are not yet on CRAN; a temporary `Remotes:`
  field points CI and reviewers at the GitHub versions so the package builds in
  the interim. This field will be removed before the actual CRAN submission
  (see below).
* **`Suggests` not in mainstream repositories: `robotstxtr`.** Same cause —
  `robotstxtr` is an optional (Suggests) dependency not yet on CRAN.

---

## Dependencies

`sitemapr` imports `rurl` and suggests `robotstxtr`. Neither is on CRAN yet, so
this package cannot be submitted to CRAN until both of its dependencies have
been accepted first.

**Coordinated submission order.** `rurl` must reach CRAN before `sitemapr`;
`robotstxtr` (a Suggests-only dependency) should also be on CRAN so the optional
code paths and their tests resolve cleanly. Submit in this order:

1. **`rurl`** — hard dependency (Imports); submit and land on CRAN first.
2. **`robotstxtr`** — optional dependency (Suggests); submit next.
3. **`sitemapr`** — submit last, once both dependencies are on CRAN.

**ACTION BEFORE CRAN SUBMISSION — remove the `Remotes:` field.** CRAN rejects
`Remotes:`. It is present only so the package builds against the in-development
GitHub dependencies while the chain is in flight, and is not part of the
intended CRAN-released DESCRIPTION. Delete it once `rurl` (and `robotstxtr`) are
on CRAN and the `Imports`/`Suggests` version floors resolve there.

## Downstream dependencies

None — this is a new package.
