## R CMD check results

Checked with `R CMD check --as-cran` on:

- macOS aarch64 (R 4.6.0, aarch64-apple-darwin23, macOS Tahoe 26.7, local)
- Linux, GitLab CI's `check` job on the `rocker/r-ver:4.6` image (R 4.6
  series)
- Windows Server 2022 x64, win-builder: R-release (R 4.6.1 ucrt) and
  R-devel (2026-09-30 r90605 ucrt). Each: 0 errors | 0 warnings | 1 note,
  the incoming-feasibility note below.
- macOS 26.6 aarch64, mac-builder (R 4.6.1 Patched): Status OK. It runs
  without `--as-cran`, so no incoming note; `robotstxtr` was unavailable
  there, which R reports as INFO.

Result: **0 errors | 0 warnings | 1 note** (local run; the note is below)

The GitLab CI `check` job runs the same `Rscript tools/verify.R` chain as the
local pre-push hook. Its last stage is `R CMD check --no-manual --as-cran`,
which fails the job on an error or a warning but not on a note, so a passing
job does not report a note count. The job runs on every push to `main` and
passed there at the commit checked locally. CI does not run on branches or
merge requests. The win-builder and mac-builder runs were on the final
pre-submission commit of the package code.

---

### Note

`checking CRAN incoming feasibility ... NOTE` — the usual new-submission note.
It covers five items:

* **New submission.** This is the first CRAN submission of `sitemapr`.
* **Version contains large components (`0.0.0.9000`).** The package is still on
  a development version. It is bumped to a release version before submission
  (see the checklist below).
* **Unknown field `Remotes` in DESCRIPTION.** `sitemapr` optionally suggests
  `robotstxtr (>= 0.3.0)`, which is not on CRAN yet, so a temporary `Remotes:`
  field names its GitLab source. That is what lets the package and its
  documentation build with the optional dependency while it is in flight:

  ```
  Remotes:
      gitlab::bart-turczynski/robotstxtr@v0.3.0
  ```

  `robotstxtr` is pinned to the tag `v0.3.0`, the release in CRAN incoming,
  because `sitemapr` calls `robots_resolve_matcher_profile_v1()`, which that
  release first exports, alongside the engine-contract v1 API. The entry goes
  away before submission.
* **`Suggests` not in mainstream repositories: `robotstxtr`.** Same cause —
  `robotstxtr` is an optional (Suggests) dependency not yet on CRAN.
* **`BugReports:` "which should likely be" an `/issues` address.**
  `BugReports:` is `https://gitlab.com/bart-turczynski/sitemapr/-/work_items`.
  The incoming check suggests an `/issues` path instead ("which should likely
  be ..."; R 4.6.1 proposes `.../-/work_items/issues`). On gitlab.com,
  `/-/issues` answers 404 to a non-browser client, `tools::check_url_db()`
  included, while `/-/work_items` answers 200. On 2026-10-23 Uwe Ligges called
  this NOTE a bug in the check for GitLab and invited the `/-/work_items` form
  on the pslr 1.2.2 submission, which CRAN then published. Quote the local
  check's wording of the NOTE here when submitting, and keep this item in the
  submission comments
  ([seor ADR 0011](https://gitlab.com/bart-turczynski/seor/-/blob/main/design/adr/0011-bugreports-names-work-items.md)).

The `Remotes` and `Suggests` items above, and the Dependencies section below,
describe `robotstxtr` while it waits in CRAN incoming. They are the part of
this file to finalize at submission (SITE-notumkrs): once `robotstxtr` is
accepted and `Remotes:` is removed, both items leave the note.

---

## Dependencies

`sitemapr` imports `rurl (>= 3.0.1)`, which is on CRAN, and suggests
`robotstxtr (>= 0.3.0)`, which is not yet. `robotstxtr` is by the same author
and hosted on GitLab alongside `sitemapr` itself:

- `robotstxtr` — <https://gitlab.com/bart-turczynski/robotstxtr>

`robotstxtr` 0.3.0 has been in CRAN incoming since 2026-09-28. `sitemapr` is
submitted only after it is accepted, so the optional code paths and their tests
resolve against a CRAN release.

---

## ACTION BEFORE CRAN SUBMISSION

Four things must be true before this file is accurate at submission time. None
of them is done yet.

1. **`robotstxtr` accepted on CRAN**, so the `Suggests` version floor
   `robotstxtr (>= 0.3.0)` resolves from a mainstream repository.
2. **`Remotes:` removed from DESCRIPTION.** CRAN does not accept the field; it
   is present only so the package builds against `robotstxtr` from GitLab
   while that package is in flight, and is not part of the intended
   CRAN-released DESCRIPTION. With item 1, this clears the `Remotes` and
   `Suggests` items from the note; rewrite them and the Dependencies section
   to match (SITE-notumkrs).
3. **Version bumped off `0.0.0.9000`** to a release version, with the
   top `NEWS.md` heading (`# sitemapr 0.0.0.9000`) renamed to match. This
   clears the large-components item from the note.
4. **Pre-submission checks rerun** on the final tree, and the check results at
   the top of this file updated to what they report.

---

## Downstream dependencies

None — this is a new package.
