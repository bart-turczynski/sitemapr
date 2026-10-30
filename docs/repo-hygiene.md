# Repository hygiene

How this repository verifies a tree before it reaches `origin` — fleet-ci's
local gate, run by the pre-push hook, is the only gate in front of `main`; CI
runs only on the weekly schedule and at release ([design/ci.md](../design/ci.md))
— and how the issue tracker survives leaving this machine.

## Hooks

This project uses the [pre-commit](https://pre-commit.com) framework for its
hygiene hooks, and fleet-ci's pre-push hook for the gate. Both configs are
cloned with the repo; each clone installs them once, in this order:

```bash
pre-commit install
.fleet-ci/pre-push --install
```

`pre-commit install` writes both hook types (`default_install_hook_types`);
`.fleet-ci/pre-push --install` then replaces the pre-push one with fleet-ci's,
which runs the gate and then the pre-commit pre-push stage.
[design/ci.md](../design/ci.md) says which commands drop it again.

`pre-commit` is a Python tool. For non-Python templates, install it with
`uv tool install pre-commit` or `pipx install pre-commit`.

### Per-commit checks

On every commit, lightweight hooks run: end-of-file fixer, trailing-whitespace
trimming, merge-conflict detection, YAML and TOML validation, mixed-line-ending
and case-conflict guards, `air-format` (posit-dev/air-pre-commit, pinned 0.12.0),
and `check-added-large-files` — a portable 5 MB size guard (`--maxkb=5120`) that
blocks accidentally committing heavy blobs (a big blob bloats `.git` history even
after deletion).

`check-toml` exists for `air.toml`, the only TOML in the tree and the file that
drives `air-format`. Without it a malformed `air.toml` reaches main and surfaces
as a formatter failure on someone else's machine.

The whitespace, end-of-file and line-ending hooks all exclude
`tests/testthat/fixtures/corpus/`. Those fixtures deliberately carry trailing
whitespace, CR/CRLF/CR line endings, BOMs and UTF-16, and normalizing them
destroys what they test. They, codespell and air also exclude `.fleet-ci/`,
fleet-ci's vendored gate, which must stay byte for byte what `bin/vendor`
writes.

### The pre-push gate

On `git push`, fleet-ci's hook runs `.fleet-ci/gate` on each pushed ref's
tip, in the fleet Docker image, against an export of the commit (never the
working tree), and then the pre-commit pre-push hooks: codespell, the
citation, BugReports, NEWS and toolchain checks, and a warn-only check that
the fleet-ci hook is installed.

**It is the only gate in front of `main`.** `origin` is GitLab, and since the
fleet-ci migration no push, merge request or push to `main` creates a
pipeline: CI runs the weekly T2 deep check and the T3 release runs only
([design/ci.md](../design/ci.md)). The pkgdown site is published from a `v*`
tag by fleet-ci's `pages` job, which moves every top-level `.md` not on
`.fleet-ci.yml`'s `pages_keep` out of the tree first, so `AGENTS.md`,
`CLAUDE.md` and any new agent file stay private (SEOR-pibdjanz,
SEOR-wqxhftpv). A new top-level `.md` meant for the public site is not
published until it is added to `pages_keep` in the same commit. The
repository once carried a GitHub Actions workflow tree, but `origin` is GitLab
and GitHub holds only a read-only mirror of it, so the tree was deleted rather
than left to rot (SITE-kgpdfhoh — git history keeps it restorable). `main` is a
protected branch (Maintainer-only push and merge, force-push refused), but that
governs who may write to it, not whether the tree is sound. Treat a red gate
as a red build: no second opinion is coming before the merge.

## The gate's checks

`.fleet-ci.yml` lists them. A diff against `main` that fleet-ci's classifier
calls docs-only (`docs/**/*.md`, `design/**/*.md`, `_pkgdown.yml`) runs the
docs tier: spelling and `pkgdown::check_pkgdown()`. Anything else runs the
full tier: spelling, then the cheap gates below, each run whatever the others
report, then one `R CMD check --as-cran` with `NOT_CRAN=true` and the CRAN
incoming checks off. Run it by hand rather than waiting for a push:

```bash
.fleet-ci/gate auto     # the tier the classifier picks, on HEAD
.fleet-ci/gate full     # the full tier, whatever the diff
```

The cheap gates were the default stages of the former `tools/verify.R`; their
names below are those stages'.

`rfloor` (`tools/check-r-floor.R`) has no counterpart in
`R CMD check`: it walks the hard-dependency closure, takes the maximum
`R (>= x.y)` any of them declares, and fails when `DESCRIPTION`'s own floor
sits below it. A floor that a dependency contradicts is *uninstallable*, not
merely untested, and `--as-cran` never cross-checks the two. It reads the
**installed** dependency DESCRIPTIONs, so it checks the versions the gate just
installed rather than the minimums `DESCRIPTION` permits — the price of keeping
the stage offline, and enough to catch the class that shipped once already.

`docs` runs `scripts/check-docs-drift.R` (seor's copy, vendored byte for byte;
change it in seor) on the gate's export of the pushed commit.

`registry` (`tools/check-findings-registry.R`) holds
`inst/findings-registry.csv` byte-identical to `docs/findings-registry.csv`.

`linewidth` (`tools/check-line-width.R`) compares `air.toml`'s `line-width`
against the width `.lintr` passes to `line_length_linter()`. Both files claim
in comments to mirror the other, and nothing enforced it: lintr never reads
`air.toml`, air never reads `.lintr`. Raise one alone and the two gates become
unsatisfiable together — the pre-commit formatter rewrites a line to a width
the pre-push linter then rejects, on every commit. The stage reads both
textually to stay dependency-free and offline.

`lint` runs `lintr::lint_package()` **and** `lintr::lint_dir("tools")`. The
second call is not redundant: `tools/` is `.Rbuildignore`d, so `lint_package()`
skips it, and until SITE-pzrosmkn every script the gate is *made of* was exempt
from the gate's own lint stage. Add a new `tools/` script and it is linted; that
was not true before. It lints `scripts/check-urls.R` and
`scripts/check-news-version.R` by name too, for the same reason; the other R
scripts there, `check-docs-drift.R` and `check-toolchain.R`, are seor's copies
and change only in seor.

`spelling` (the docs tier) runs `spelling::spell_check_package()` over `DESCRIPTION`, `man/`,
the vignettes, `README` and `NEWS.md`. `R CMD check` has a DESCRIPTION spelling
check of its own, but it runs only where `_R_CHECK_CRAN_INCOMING_USE_ASPELL_` is
set, which is CRAN and not here, so a typo first surfaced in win-builder's
incoming NOTE (SEOR-mtbzfroz). spelling bundles its own dictionaries. A genuine
term goes in `inst/WORDLIST`; a typo gets fixed at its source (the roxygen
comment for `man/`, `README.Rmd` for `README.md`).

`incoming` (`tools/check-incoming.R`) repeats the two `checking CRAN incoming
feasibility` checks that a local `R CMD check --as-cran` skips (see
verification trap 7). It spell-checks
`DESCRIPTION`'s Title and Description **without** `inst/WORDLIST`, because
CRAN's aspell never reads it: reword, or quote a name as `'name'`. And it fails
a relative link in `README.md` or `man/` whose target `.Rbuildignore` drops from
the tarball: link it by repository URL instead.

`urls` (`scripts/check-urls.R`) fetches every URL the package declares
(`DESCRIPTION`, `man/`, `inst/CITATION`, `NEWS.md`, `README.md`) with
`tools:::check_url_db()`, the function `R CMD check` itself uses. The gate's
`R CMD check` runs with CRAN incoming off, so it fetches none of them; and
where `--as-cran` does (`t2-ascran`), it reports a dead link as a NOTE and
fails only on warnings, so before this stage a dead link passed the gate and
surfaced at CRAN incoming (SITE-dpmutjii). A URL that answers HTTP 4xx or 5xx fails the stage. A URL that
could not be reached at all (DNS failure, refused connection, timeout: no HTTP
status) is printed as a warning and the stage passes, because a network blip
must not reject a push (the lesson of SITE-xolykhjm). Nothing is
exempt: `DESCRIPTION`'s `BugReports:` names `/-/work_items`, which answers 200
([seor's ADR 0011](https://gitlab.com/bart-turczynski/seor/-/blob/main/design/adr/0011-bugreports-names-work-items.md)).
It fails rather than passes when it finds no URLs at all, and it
prints how many it checked, so a lookup that read nothing cannot report clean.
Its classifier runs an offline self-test first on every run;
`Rscript scripts/check-urls.R --self-test` runs that alone.

`readme` (`scripts/check-readme-drift.sh`) installs the package into a
throwaway library, knits `README.Rmd` under the image's pinned pandoc and
fails when `README.md` differs, blank lines aside. `news-version`
(`scripts/check-news-version.R`) holds the top `NEWS.md` heading to
`(development version)` or the `DESCRIPTION` Version.

Besides `urls`, the dependency install reaches the network (pak resolves the
dependency chain, `sitemapr` → `rurl`, and the `Remotes:` pin, which must stay
publicly readable — a private GitLab project fails it with a pak 403). Every
cheap gate runs after that install, whatever the others report, so one run
names every failing check.

**Do not rely on the pre-push hook as the only trigger.** It fires on `git push`,
so it never runs while the remote is unreachable — and the per-commit hooks only
see *staged* files, so whole-tree problems stay invisible. To check the tree the
way pre-push would, run `.fleet-ci/gate auto` for the gate, and for the
hygiene hooks:

```bash
pre-commit run --all-files --hook-stage pre-push
```

## The linter set

`.lintr` is intentionally aligned with the linter set `goodpractice::gp()` runs
(`goodpractice:::linters_to_lint()`), so the local and CI `lintr::lint_package()`
gate surfaces the same findings as the goodpractice report reviewers run. Without
that alignment a package passes its own lint gate and then trips a pile of
goodpractice findings later. Regenerate the list after a goodpractice upgrade,
comparing against `names(goodpractice:::linters_to_lint())`.

**Keep `.lintr` free of `#` comments.** It is parsed with `read.dcf()`, which
only learned to skip comment lines in R 4.6. On R 4.5 and older a single comment
makes `lint_package()` abort with `Invalid DCF format`, so the rationale lives
here instead. Keep it ASCII too: a non-ASCII byte in `.lintr` comes back
`bytes`-encoded on older R and makes any config error surface as a confusing
`sprintf()` failure instead of the real message.

Documented deviations from the goodpractice set — test-idiom and public-API
reasons a real package hits as it grows:

- `object_name_linter` / `object_usage_linter`: not part of the goodpractice set
  and deliberately NOT added. The cucumber DSL (`when`/`then`/`context`) and the
  testthat helpers read as undefined globals to `object_usage_linter`, and
  packages commonly expose mixed-case or dotted public parameters plus
  `._`-prefixed internal helpers that `object_name_linter` would flag.
- `expect_identical_linter`: off. Suites routinely rely on `expect_equal()`'s
  numeric tolerance (`expect_equal(nrow(x), 2)` compares integer vs double) and
  its string-encoding normalization, both of which `identical()` rejects; a
  wholesale swap means retyping literals for no behavioral gain.
- `implicit_assignment_linter`: off. Tests use the standard
  `expect_warning(res <- f(), "msg")` idiom to capture both the warning and the
  return value (`expect_warning()` returns the condition, not the value).
- `library_require_linter`: off. `tests/testthat.R` and vignette setup chunks
  legitimately call `library()`.
- `undesirable_operator_linter`: configured to keep flagging `<<-`/`->>` but
  allow `:::`, which tests use to reach internal (unexported) functions.

`strings_as_factors_linter` is off, as in goodpractice, which dropped it in 1.2.0
(ropensci-review-tools/goodpractice#321). It only guarded the pre-R-4.0
`data.frame()` default, and this package depends on R >= 4.1. The existing
`stringsAsFactors = FALSE` arguments stay; they are harmless here.

## The tracker is not in git unless it is snapshotted

`.fp/` is gitignored, so the issue tracker is a local database that no commit, no
clone and no bundle has ever contained — while `docs/architecture.md` and the
other docs under `docs/` cite `SITE-*` ids as the evidence behind their
decisions. Lose `.fp/` and every one of those citations dangles while the code
survives intact. Regenerate the only copy that is in git with:

```bash
sh data-raw/snapshot-tracker.sh
```

It writes `docs/tracker-snapshot.md`, alongside the docs that cite the ids.
`docs/` is committed source here — pkgdown builds into `site/` instead
(`_pkgdown.yml`, gitignored at `.gitignore:38`) — so unlike a repository that
publishes from `docs/`, the snapshot lands in a directory that actually reaches a
commit.

`fp` stays authoritative. Nothing reads the snapshot back, `fp context <id>`
remains the way to read an issue, and **every run overwrites the file
wholesale**, so hand-edits to it are lost.

## Taking a backup

Do not run the snapshot and the copy as two steps. Use:

```bash
sh data-raw/backup.sh                 # refresh, commit, bundle, mirror, publish
sh data-raw/backup.sh <bundle-path>   # write the bundle somewhere specific
sh data-raw/backup.sh --no-commit     # refuse rather than commit a stale snapshot
```

It regenerates the snapshot, commits it if it changed (only that path, so
unrelated staged work is untouched), writes and verifies a bundle, then mirrors
to the `backup` remote at `~/Projects/_backups/sitemapr.git`. A copy taken
without refreshing first carries a stale copy of the only tracker reasoning in
git and *looks* current, which is worse than having no snapshot at all — so the
ordering is enforced by control flow rather than by this paragraph.

Four properties are deliberate and worth knowing:

- **The bundle is written before the mirror.** The bundle is local and needs no
  network; the mirror can fail. Ordering it this way means a run that ends in an
  error still leaves a verified archive behind.
- **The mirror push skips every pre-push hook.** Gating a backup on a green
  tree is backwards — a broken tree is when the copy matters most, and a lint
  failure must never be able to stop one. fleet-ci's hook already skips the
  gate for a push to a local path, as `backup`'s is, but pre-commit's own
  pre-push hooks can still refuse it (under pre-commit's migration mode, or a
  clone with pre-commit's hook alone), and they may reach the network. So
  that one push keeps `--no-verify`.
- **The mirror is not an archive.** `--mirror` makes the remote match this
  repository exactly, so a ref deleted here is deleted there on the next run.
  The bundles are the half that remembers.
- **The snapshot commit is published, under a bound.** Left unpushed it strands
  on `main`, and the next merge leaves local and `origin` diverged over a
  generated file long after the run that caused it. It goes through the gate,
  whose classifier calls a change to `docs/tracker-snapshot.md` alone
  docs-only, so it costs the docs tier's seconds. The gate runs in fleet-ci's
  Docker image, so this push needs a running Docker daemon and a
  `docker login registry.gitlab.com` (fleet-ci's images are private, [seor
  ADR 0013](https://gitlab.com/bart-turczynski/seor/-/blob/main/design/adr/0013-fleet-ci-is-private.md));
  without them it fails, and the run ends with `PUBLISH FAILED` after a
  complete bundle and mirror. The script pushes it *only*
  when it is the single unpushed commit and is exactly the one the run just
  made, so a backup never carries other work out to `origin`. In any other
  state the commit is left for a normal push to carry through the gate, and
  the script says so. On a detached HEAD it refuses too — the commit it already made rides
  out in that run's bundle and is re-made by the next run from a branch, so
  nothing is lost.

Re-running with nothing changed commits nothing. The snapshot header carries a
date rather than a timestamp, so same-day re-runs are byte-identical; the first
run after midnight commits a one-line date change.

The scripts and the snapshot live on `main`. If they are absent from the branch
you are on, merge or rebase onto `main` rather than adding a second copy.

## Keeping a commit without a tag

Tags are public: r-universe lists every tag on the GitLab project as if it
were a release, and the GitHub mirror carries them too. So `refs/tags/` holds
release tags (`vX.Y.Z`) and nothing else. To keep a commit that no branch
reaches, such as a pre-rebase state or a dropped stash, put it under
`refs/archive/`:

```bash
git push origin <sha>:refs/archive/<date>/<name>
```

GitLab keeps the ref, and nothing that lists tags or releases shows it. An
ordinary clone doesn't fetch it, so a clone that should have it, including the
one `data-raw/backup.sh` runs from, adds the refspec once:

```bash
git config --add remote.origin.fetch '+refs/archive/*:refs/archive/*'
```

The three `prerebase-2026-07-31/*` anchors moved there in SITE-tbrzwoqw.
