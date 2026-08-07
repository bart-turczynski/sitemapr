# Repository hygiene

How this repository verifies a tree before it reaches CI, and how the issue
tracker survives leaving this machine.

## Hooks

This project uses the [pre-commit](https://pre-commit.com) framework. Its config
(`.pre-commit-config.yaml`) is cloned with the repo; each clone enables the hooks
once:

```bash
pre-commit install && pre-commit install --hook-type pre-push
```

`pre-commit` is a Python tool. For non-Python templates, install it with
`uv tool install pre-commit` or `pipx install pre-commit`.

### Per-commit checks

On every commit, lightweight hooks run: end-of-file fixer, trailing-whitespace
trimming, merge-conflict detection, YAML and TOML validation, mixed-line-ending
and case-conflict guards, `air-format` (posit-dev/air-pre-commit, pinned 0.8.2),
and `check-added-large-files` — a portable 5 MB size guard (`--maxkb=5120`) that
blocks accidentally committing heavy blobs (a big blob bloats `.git` history even
after deletion).

`check-toml` exists for `air.toml`, the only TOML in the tree and the file that
drives `air-format`. Without it a malformed `air.toml` reaches main and surfaces
as a formatter failure on someone else's machine.

The whitespace, end-of-file and line-ending hooks all exclude
`tests/testthat/fixtures/corpus/`. Those fixtures deliberately carry trailing
whitespace, CR/CRLF/CR line endings, BOMs and UTF-16, and normalizing them
destroys what they test.

### Pre-push verify gate

On `git push`, the `verify` hook runs the project's verify command — the same
chain the CI workflows run.

**It is currently the only gate that runs at all.** `origin` is GitLab and
carries no CI config; every workflow in `.github/workflows/` is GitHub Actions,
and that account is suspended, so nothing runs them. There is also no
server-side branch protection standing behind it. Treat a red pre-push gate as a
red build: no second opinion is coming, and nothing downstream will catch what
it lets through.

## Running the checks locally

The chain lives in `tools/verify.R`, which the pre-push hook invokes with no
arguments. Run it directly rather than waiting for a push:

```bash
Rscript tools/verify.R              # the pre-push gate: docs, registry, rfloor, lint, R CMD check
Rscript tools/verify.R --all        # adds coverage and the README diff
Rscript tools/verify.R lint check   # named stages only
Rscript tools/verify.R --list       # list the stages
```

`rfloor` (`tools/check-r-floor.R`) is the one stage with no counterpart in
`R CMD check`: it walks the hard-dependency closure, takes the maximum
`R (>= x.y)` any of them declares, and fails when `DESCRIPTION`'s own floor
sits below it. A floor that a dependency contradicts is *uninstallable*, not
merely untested, and `--as-cran` never cross-checks the two. It reads the
**installed** dependency DESCRIPTIONs, so it checks this machine's versions
rather than the minimums `DESCRIPTION` permits — the price of keeping the stage
offline, and enough to catch the class that shipped once already.

`lint` runs `lintr::lint_package()` **and** `lintr::lint_dir("tools")`. The
second call is not redundant: `tools/` is `.Rbuildignore`d, so `lint_package()`
skips it, and until SITE-pzrosmkn every script the gate is *made of* was exempt
from the gate's own lint stage. Add a new `tools/` script and it is linted; that
was not true before.

Stages run in declared order, cheapest first, and the chain stops at the first
failure. Because the hook and a manual run share one definition, they cannot
disagree about what "verified" means.

Every stage runs offline except `readme`: `devtools::build_readme()` installs the
package, which resolves the GitHub-hosted dependency chain (`sitemapr` → `rurl` →
`pslr`) through pak. With GitHub unreachable it fails with a pak 403 rather than
a README problem — which is why `--all` is not the default.

**Do not rely on the pre-push hook as the only trigger.** It fires on `git push`,
so it never runs while the remote is unreachable — and the per-commit hooks only
see *staged* files, so whole-tree problems stay invisible. To check the tree the
way pre-push would:

```bash
pre-commit run --all-files --hook-stage pre-push
```

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
- **The mirror push skips the pre-push gate.** Gating a backup on a green tree
  is backwards — a broken tree is when the copy matters most, and a lint failure
  must never be able to stop one.
- **The mirror is not an archive.** `--mirror` makes the remote match this
  repository exactly, so a ref deleted here is deleted there on the next run.
  The bundles are the half that remembers.
- **The snapshot commit is published, under a bound.** Left unpushed it strands
  on `main`, and the next merge leaves local and `origin` diverged over a
  generated file long after the run that caused it. Pushing it through the
  pre-push gate would cost ~200s and buy nothing: `^docs$` is in
  `.Rbuildignore`, so `R CMD check` never sees this file, and no other stage
  reads it either. So the script pushes it with `--no-verify` — but *only* when
  it is the single unpushed commit and is exactly the one the run just made. A
  bare `--no-verify` push would carry every other unpushed commit out ungated,
  which is the failure this bound exists to prevent. In any other state the
  commit is left for a normal push to carry through the gate, and the script
  says so. On a detached HEAD it refuses too — the commit it already made rides
  out in that run's bundle and is re-made by the next run from a branch, so
  nothing is lost.

Re-running with nothing changed commits nothing. The snapshot header carries a
date rather than a timestamp, so same-day re-runs are byte-identical; the first
run after midnight commits a one-line date change.

The scripts and the snapshot live on `main`. If they are absent from the branch
you are on, merge or rebase onto `main` rather than adding a second copy.
