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
| T1 | every other push, locally, the pre-push hook | the gate's full tier: T0's checks, then docs drift (`scripts/check-docs-drift.R`), the findings registry, the R floor and line-width guards (`tools/check-*.R`), the CRAN incoming spelling and file-URI checks (`tools/check-incoming.R`), lintr on the package, `tools/`, `scripts/check-urls.R` and `scripts/check-news-version.R`, the URL check (`scripts/check-urls.R`), README drift (`scripts/check-readme-drift.sh`), the NEWS heading (`scripts/check-news-version.R`), and one `R CMD check --as-cran` (`NOT_CRAN=true`, incoming checks off) |
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
prints `gate: skipped, <remote> is a local mirror` and exits 0. Under
pre-commit's migration mode the skip ends only the gate's hook, and the
pre-commit pre-push stage still runs, so `data-raw/backup.sh` still mirrors
to `backup` with `--no-verify`: a backup must never be stopped by a lint
failure or need the network. Its publish push to `origin` goes through the
gate, which needs a running Docker daemon and the registry login (seor ADR
0013).

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
  `_pkgdown.yml` and `DESCRIPTION` name. `pages` publishes pkgdown's
  `destination`, `site/` (`docs/` is hand-written project context, never
  the site), with only the top-level `.md` files on `.fleet-ci.yml`'s
  `pages_keep`; the gate's docs tier checks that destination too.

Never set `SCHEDULE_KIND` as a project or group variable: every schedule
would inherit it.

## Gaps accepted in the fleet-ci migration

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
  the former CI never ran. It passed, tests included, when run once through
  the gate on a throwaway commit (`locale_legs: [C]`, SEOR-stasqeuk). That
  run needed `en_US.UTF-8` in `locales` too: under `C`, `R CMD check`'s
  syntax check switches to it for the UTF-8 sources, and the gate's own
  locale directory holds only what `locales` lists, while CI's image ships
  it. The gate itself runs no locale leg, to keep T1 at one `R CMD check`.
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
- **A NOTE fails nothing, as before.** The former verify failed on an
  ERROR or a WARNING only (`error_on = "warning"`, no NOTE list), so
  `.fleet-ci.yml` sets no `allowed_notes`, and neither the gate nor the T2
  check legs fail on a NOTE. Read `t2-ascran`'s NOTEs, the only leg with
  the incoming feasibility and URL checks, before a submission.
- **The 100% coverage stage is gone.** The former verify's opt-in
  `coverage` stage failed on any uncovered line before a release; the
  template's `coverage` fails below 95%, the fleet floor, and nothing
  enforces 100% any more.
- **`NOT_CRAN=true` in T1 and the T2 check legs.** The former verify's
  check ran with `NOT_CRAN` unset, so `skip_on_cran()` tests
  (`test-url.R`'s differential test) now run in it. T1 excludes
  `test-osv.R` (network) and `test-security.R` (`.fleet-ci.yml`'s
  `exclude_tests`), so the gate runs neither. The T2 legs that run the
  suite with `NOT_CRAN=true` (`t2-check-release`, `t2-check-oldrel`,
  `t2-check-devel`, `t2-locale`) run both, and `test-security.R` does not
  skip there: `OSSINDEX_USER` and `OSSINDEX_TOKEN` are project variables
  that every job on the protected `main` gets, and `NOT_CRAN=true` defeats
  its `skip_on_cran()`, so the live OSS Index audit runs in each of those
  legs as well as in `security-audit`, and an OSS Index outage or a new
  advisory fails them too. Its offline allow-list tests run in the same
  places. Splitting the live audit from them needs a `tests/` change, a
  follow-up.
- **`pages` deploys from a `v*` tag only**, not on every push to `main`, so
  the site documents the release CRAN serves.
- **No CI run of a branch.** The former web pipeline on any ref ran `check`
  against a branch; the template admits a web pipeline only with
  `RELEASE=1` on `main` or a tag.
- **Comments in `R/` and `tests/` still name `tools/verify.R`**; a CI
  migration edits neither.
- **`--as-cran` runs on R release only.** The former `deep-check` ran
  `tools/verify.R check`, `R CMD check --as-cran`, on R 4.6, 4.5 and devel.
  The template's `t2-check-oldrel` and `t2-check-devel` run `--no-manual`
  without `--as-cran` (as does `t2-check-release`), so `t2-ascran` (R
  release) is the only CI leg with `--as-cran`; `x-floor` (R 4.1.3) runs it
  with incoming off. An `--as-cran`-only finding on oldrel or devel now
  surfaces at win-builder, or at CRAN.
- **`t2-ascran` has no download timeout.** The former check passed
  `R_DEFAULT_INTERNET_TIMEOUT=300` to R CMD check, the fix for the
  incoming check stalling on CRAN's `archive.rds` (SITE-xolykhjm).
  `t2-ascran` is the template's, and sets none, so the stall can come back
  there; `x-floor` keeps the 300s timeout.
- **No runner tag.** The former CI's `default: tags: [local-docker]` is
  gone: the template sets no `tags`, and the project runner accepts untagged
  jobs, so they run there today. If shared runners were ever enabled on the
  project, jobs could land on GitLab's SaaS runners instead.
- **Pandoc** comes from the fleet image (`.fleet-ci/toolchain`, 3.10), which
  reproduces the committed `README.md`. `scripts/check-toolchain.R` checks a
  local pandoc against it, so a local `build_readme()` writes what the gate
  accepts.
