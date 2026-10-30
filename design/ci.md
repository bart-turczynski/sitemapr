# Continuous integration

sitemapr runs fleet-ci's tiered CI (seor ADR 0012). `.gitlab-ci.yml`
includes fleet-ci's `templates/r-package.yml`, pinned by commit SHA, and sets
only package variables plus one `x-*` job; `.fleet-ci.yml` holds the local
gate's settings, and `.fleet-ci/` is fleet-ci's vendored gate (re-run
fleet-ci's `bin/vendor`, never edit it). The job names below are the
template's.

| Tier | Where | What runs |
| --- | --- | --- |
| hygiene hooks | pre-commit, at commit and at push | `.pre-commit-config.yaml`. At commit: the hygiene fixers (end of file, trailing whitespace, line endings; the byte-sensitive corpus excluded), the large-file, merge-conflict, YAML, TOML and case-conflict checks, `air-format`, and codespell. At push: codespell again, the citation, BugReports, NEWS and toolchain checks, the `check-news.py` and `bestpractices-url.py` self-tests when those scripts change, and the warn-only `fleet-ci-hook-installed` check |
| T0 | every push whose diff against `main` is docs-only (`docs/**/*.md`, `design/**/*.md`, `_pkgdown.yml` and the like), locally, the pre-push hook | the gate's docs tier, `.fleet-ci/gate` in the fleet image: spelling and `pkgdown::check_pkgdown()` |
| T1 | every other push, locally, the pre-push hook | the gate's full tier: T0's checks, then docs drift (`scripts/check-docs-drift.R`), the findings registry, the R floor and line-width guards (`tools/check-*.R`), the CRAN incoming spelling and file-URI checks (`tools/check-incoming.R`), lintr on the package and `tools/`, the URL check (`scripts/check-urls.R`), README drift (`scripts/check-readme-drift.sh`), the NEWS heading (`scripts/check-news-version.R`), and one `R CMD check --as-cran` (`NOT_CRAN=true`, incoming checks off) |
| T2 | the weekly `deep-check` schedule; every T3 run | `t2-check-release`, `t2-check-oldrel`, `t2-check-devel`, `x-floor` (R 4.1.3, in place of `t2-floor`), `t2-locale`, `t2-ascran` (incoming and URLs on), `coverage` (fails below 95%), `osv-audit`, `security-audit`, `citation-version` |
| T3 | a `RELEASE=1` web pipeline on `main`; a `v*` tag | all of T2 plus `t3-manual` (the PDF manual); the tag, or `RELEASE=1` on a tag, adds `pages` |

Pushes to `main` or a branch, merge requests and API pipelines (`glab ci run`)
create no pipeline at all, and neither does a web pipeline without
`RELEASE=1` (or `PAGES=1` on a tag). An empty pipeline list is not a pass:
the merge gate is the local gate (T0 or T1), run before the branch leaves the
machine.

Before a CRAN submission, start T3 on `main` from **Build > Pipelines > Run
pipeline**, ref `main`, variable `RELEASE=1` (see
[release-deltas.md](release-deltas.md)). `PAGES=1` on a `v*` tag runs `pages`
alone.

## The hook, once per clone

```sh
pre-commit install
.fleet-ci/pre-push --install
```

`pre-commit install` writes both hook types (`default_install_hook_types`);
`.fleet-ci/pre-push --install` then replaces the pre-push one with
fleet-ci's, which runs the gate on each pushed ref's tip and then the
pre-commit pre-push stage. Two commands drop it: `pre-commit install -f`, and
`pre-commit install -f --hook-type pre-push`; re-run the install after
either. Without `-f`, `pre-commit install` (with or without
`--hook-type pre-push`) moves the hook to `hooks/pre-push.legacy`
(pre-commit's migration mode), which still runs the gate first; `-f
--hook-type pre-commit` leaves it alone. `.fleet-ci/gate auto` runs the gate
by hand on `HEAD`. A pass is stamped by tree, tier, classifier version, image
and (full tier) resolved dependency lock, and a stamped commit is skipped.
The gate refuses a push to `main` that adds more than one first-parent
merge.

The gate skips a push to a local mirror: when the push URL is local by
git's rule (the `backup` remote's path, or `file:///` with an empty host) it
prints `gate: skipped, <remote> is a local mirror` and exits 0, so
`data-raw/backup.sh` mirrors to `backup` without `--no-verify`. Under
pre-commit's migration mode the skip ends only the gate's hook, and the
pre-commit pre-push stage still runs.

R CMD check NOTEs don't fail the gate, as before: the former verify failed on
an ERROR or a WARNING only, so `.fleet-ci.yml` sets no `allowed_notes`.

## Project settings CI depends on, which are not in this repository

These live in GitLab's project settings, so a clone does not carry them:

- **Pipeline schedule 4472811** (Build > Pipeline schedules), "Weekly deep
  check (fleet standard)", `0 22 * * 2` Europe/Warsaw on `main`, carrying
  `SCHEDULE_KIND=deep-check`. Required: it is T2's only unattended run, and
  every pipeline on `main` carries `coverage`, so the coverage badge reads
  it.
- **Pipeline schedule 4467474**, `SCHEDULE_KIND=dependency-audit`. The
  template starts no pipeline for it any more (the audits run in T2); its
  removal is owner-gated.
- **`OSSINDEX_USER` / `OSSINDEX_TOKEN`** (Settings > CI/CD > Variables;
  `OSSINDEX_TOKEN` masked; the user is the literal `x`). `security-audit`
  sets `OSSINDEX_AUDIT_REQUIRED=true`, so without them it fails rather than
  passing having audited nothing.
- **`pages_access_level: enabled`** and **Pages unique domain off**: the site
  lives at `https://bart-turczynski.gitlab.io/sitemapr/`, which
  `_pkgdown.yml` and `DESCRIPTION` name. `pages` publishes only the
  top-level `.md` files on `.fleet-ci.yml`'s `pages_keep`.

Never set `SCHEDULE_KIND` as a project or group variable: every schedule
would inherit it.

## Gaps accepted in the fleet-ci migration

- **OPEN: `pages` publishes the wrong directory.** fleet-ci v1.2.0's `pages`
  ends with `mv docs public`, but sitemapr's `docs/` is hand-written project
  context and `_pkgdown.yml` builds the site into `site/`
  (`destination: site`). From a `v*` tag the job would publish the raw
  `docs/` tree as the site. fleet-ci is to read pkgdown's destination in
  `pages`, and sitemapr re-pins before its first tag; until then, do not
  push a `v*` tag or run `PAGES=1`.
- **The floor leg is `x-floor`, not the template's `t2-floor`
  (`FLEET_FLOOR: "false"`).** `t2-floor` installs every dependency from one
  dated snapshot, and sitemapr's floor closure cannot come from one: rurl
  (>= 3.0.1) and the other fleet packages postdate the last snapshot whose
  curl builds against R 4.1.3's libcurl. `x-floor` (on `.t2-job`) keeps the
  former `floor-check` unchanged; `.gitlab-ci.yml` has the detail.
- **No sanitizer leg (`FLEET_SANITIZERS: "false"`).** sitemapr has no
  compiled code; the former CI had none either.
- **The Turkish-locale test runs in T1 and `t2-locale` only.**
  `test-ascii.R` switches `LC_CTYPE` to `tr_TR.UTF-8` and skips without it.
  `.fleet-ci.yml`'s `locales` builds it for the local gate and `t2-locale`;
  the other T2 legs skip that test, as the former CI's legs all did.
- **`t2-locale`'s leg runs under `LC_ALL=C`**, the template's default, which
  the former CI never ran. It passed when run once locally through the gate
  (`locale_legs: [C]`, SEOR-stasqeuk); the gate itself runs no locale leg,
  to keep T1 at one `R CMD check`.
- **No server-side cheap gates.** The former `check` and `citation-version`
  jobs ran the whole verify chain (docs drift, the registry, R-floor and
  line-width guards, spelling, incoming, lintr, URLs), README drift,
  `check-news.py`, `check-bugreports.py` and the NEWS heading on every push
  to `main`, which caught a web edit and a `--no-verify` push. Those runs
  are gone; only the local gate and the pre-push hooks run them, and T2's
  `citation-version` runs `check-citation.py` alone.
- **No incoming check before a merge.** T1's check runs with
  `_R_CHECK_CRAN_INCOMING_=false`; the incoming feasibility and URL checks
  the former verify's `--as-cran` ran on every push run in `t2-ascran` (T2
  and T3). `tools/check-incoming.R` still runs the offline aspell and
  file-URI halves, and `scripts/check-urls.R` every declared URL, in T1.
- **The 100% coverage stage is gone.** The former verify's opt-in
  `coverage` stage failed on any uncovered line before a release; the
  template's `coverage` fails below 95%, the fleet floor, and nothing
  enforces 100% any more.
- **`NOT_CRAN=true` in T1 and the T2 check legs.** The former verify's
  check ran with `NOT_CRAN` unset, so `skip_on_cran()` tests
  (`test-url.R`'s differential test) now run in it. The T2 check legs also
  run `test-osv.R` (network) and `test-security.R` (which skips there
  without the OSS Index credentials); T1 excludes both
  (`.fleet-ci.yml`'s `exclude_tests`), so `test-security.R`'s offline
  allow-list tests run only in `security-audit` (T2, T3). Moving them to a
  file of their own needs a `tests/` change, a follow-up.
- **`pages` deploys from a `v*` tag only**, not on every push to `main`, so
  the site documents the release CRAN serves.
- **No CI run of a branch.** The former web pipeline on any ref ran `check`
  against a branch; the template admits a web pipeline only with
  `RELEASE=1` on `main` or a tag.
- **Comments in `R/`, `tests/` and `cran-comments.md` still name
  `tools/verify.R`**; a CI migration edits none of them.
- **Pandoc** comes from the fleet image (`.fleet-ci/toolchain`, 3.10), which
  reproduces the committed `README.md`. `scripts/check-toolchain.R` checks a
  local pandoc against it, so a local `build_readme()` writes what the gate
  accepts.
