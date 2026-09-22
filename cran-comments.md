## R CMD check results

Checked with `R CMD check --as-cran` on:

- macOS aarch64 (R 4.6.0, local)

Result: **0 errors | 0 warnings | 1 note**

That local run is the only check this package gets. There is no continuous
integration: `origin` is GitLab and carries no pipeline configuration, and the
repository's former GitHub Actions tree was deleted rather than left in place to
suggest coverage it could no longer provide. The single gate is
`Rscript tools/verify.R`, invoked by a local pre-push hook; its last stage is
`R CMD check --as-cran`, and nothing server-side runs behind it.

---

### Note

`checking CRAN incoming feasibility ... NOTE` — the usual new-submission note.
It covers five items:

* **New submission.** This is the first CRAN submission of `sitemapr`.
* **Version contains large components (`0.0.0.9000`).** The package is still on
  a development version. It is bumped to a release version before submission
  (see the checklist below).
* **Unknown field `Remotes` in DESCRIPTION.** `sitemapr` imports
  `rurl (>= 2.1.0)` and optionally suggests `robotstxtr (>= 0.2.0)`. Neither is
  on CRAN, so a temporary `Remotes:` field names their GitLab sources, which is
  what lets the package and its documentation build while the chain is in
  flight:

  ```
  Remotes:
      gitlab::bart-turczynski/rurl,
      gitlab::bart-turczynski/robotstxtr@v0.2.0
  ```

  `robotstxtr` is pinned to the tag `v0.2.0` because the engine-contract v1 API
  this package calls (`robots_engine_contract_v1()` and the v1 evaluation
  entry points) first exists at that tag; an earlier build advertises the same
  contract id without the fields `sitemapr` reads. `rurl` carries no `@ref`, so
  it tracks that project's default branch — a moving target: a build today and a
  build next week need not resolve the same commit. Both entries go away before
  submission.
* **`Suggests` not in mainstream repositories: `robotstxtr`.** Same cause —
  `robotstxtr` is an optional (Suggests) dependency not yet on CRAN.
* **`BugReports:` reported as a 404.**

      Found the following (possibly) invalid URLs:
        URL: https://gitlab.com/bart-turczynski/sitemapr/-/issues
          From: DESCRIPTION
          Status: 404

  This is the address the incoming check itself asks for. GitLab has migrated
  issues to work items and answers `/-/issues` with 404 to any signed-out,
  non-browser client, on every project on the site: GitLab's own tracker,
  `https://gitlab.com/gitlab-org/gitlab/-/issues`, answers 404 identically. A
  browser is redirected (302) to `/-/work_items`, so the link works for a
  reader.

  No gitlab.com address clears both checks.
  `tools:::.check_package_CRAN_incoming()` accepts a gitlab.com `BugReports:`
  only when its path ends in `/-/issues`, and every such path, with or without
  a query string, is the 404 above. A sibling package's first upload declared
  `/-/work_items`, which returns 200, and was archived at the pretest for that
  reason; it was accepted on resubmission with `/-/issues`. The field here
  follows the check's suggestion, as the dependency `rurl` 3.0.1 does on CRAN.
  The `NEWS.md` bullet gives the address as code rather than as a link, so the
  404 is reported once, from `DESCRIPTION` only.

---

## Dependencies

`sitemapr` imports `rurl` and suggests `robotstxtr`. Neither is on CRAN yet, so
this package cannot be submitted to CRAN until both of its dependencies have
been accepted first. Both are in-flight packages by the same author, hosted on
GitLab alongside `sitemapr` itself:

- `rurl` — <https://gitlab.com/bart-turczynski/rurl>
- `robotstxtr` — <https://gitlab.com/bart-turczynski/robotstxtr>

**Coordinated submission order.** `rurl` must reach CRAN before `sitemapr`;
`robotstxtr` (a Suggests-only dependency) should also be on CRAN so the optional
code paths and their tests resolve cleanly. Submit in this order:

1. **`rurl`** — hard dependency (Imports); submit and land on CRAN first.
2. **`robotstxtr`** — optional dependency (Suggests); submit next.
3. **`sitemapr`** — submit last, once both dependencies are on CRAN.

---

## ACTION BEFORE CRAN SUBMISSION

Four things must be true before this file is accurate at submission time. None
of them is done yet.

1. **Both dependencies accepted on CRAN**, in the order above, so the
   `Imports`/`Suggests` version floors (`rurl (>= 2.1.0)`,
   `robotstxtr (>= 0.2.0)`) resolve from a mainstream repository.
2. **`Remotes:` removed from DESCRIPTION.** CRAN does not accept the field; it
   is present only so the package builds against the in-development GitLab
   dependencies while the chain is in flight, and is not part of the intended
   CRAN-released DESCRIPTION. Deleting it also retires the unpinned `rurl`
   entry described above.
3. **Version bumped off `0.0.0.9000`** to a release version, which clears the
   large-components item from the note.
4. **The GitLab projects made public.** As of this writing the `sitemapr` and
   `robotstxtr` projects are private. Every link a reviewer may follow has to
   resolve for an anonymous visitor first: the `URL:` entries in DESCRIPTION
   (the project page and the pkgdown site) and the dependency links above. A
   private GitLab project redirects an anonymous request to the sign-in page
   (measured: `302` to `/users/sign_in`, resolving to `403`), which both wastes
   the reviewer's time and gives `--as-cran` a URL to report. This is a
   repository-visibility change, not a package change. `BugReports:` is the one
   exception: it stays on `/-/issues` and 404s for a non-browser client even
   once the project is public, because that is the form the incoming check
   requires — see the note above.

---

## Downstream dependencies

None — this is a new package.
