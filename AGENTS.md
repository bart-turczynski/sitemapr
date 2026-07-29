# Agent Instructions

Use committed docs for durable project knowledge. Keep raw planning notes, temporary context, and generated scratch work in `_scratch/`.

Do not commit `_scratch/`, `.fp/`, secrets, dependencies, build outputs, or local caches.

## Git hygiene

This project uses the [pre-commit](https://pre-commit.com) framework. Its config (`.pre-commit-config.yaml`) is cloned with the repo; each clone enables the hooks once:

```bash
pre-commit install && pre-commit install --hook-type pre-push
```

`pre-commit` is a Python tool. For non-Python templates, install it with `uv tool install pre-commit` or `pipx install pre-commit`.

### Per-commit checks

On every commit, lightweight hooks run: end-of-file fixer, trailing-whitespace trimming, merge-conflict detection, YAML/TOML validation, mixed-line-ending and case-conflict guards, and `check-added-large-files` — a portable 5 MB size guard that blocks accidentally committing heavy blobs (a big blob bloats `.git` history even after deletion).

### Pre-push verify gate

On `git push`, the `verify` hook runs the project's verify command — the same chain CI runs. Server-side branch protection is unavailable on this GitHub plan, so this local pre-push gate is the stand-in for branch protection: it blocks a push whose tree would turn CI red.

### Running the checks locally

The chain lives in `tools/verify.R`, which the pre-push hook invokes with no arguments. Run it directly rather than waiting for a push or for CI:

```bash
Rscript tools/verify.R              # the pre-push gate: docs, registry, lint, R CMD check
Rscript tools/verify.R --all        # everything CI runs, adding coverage and the README diff
Rscript tools/verify.R lint check   # named stages only
Rscript tools/verify.R --list       # list the stages
```

Stages run in declared order, cheapest first, and the chain stops at the first failure. Because the hook and a manual run share one definition, they cannot disagree about what "verified" means.

Every stage runs offline except `readme`: `devtools::build_readme()` installs the package, which resolves the GitHub-hosted dependency chain (`sitemapr` → `rurl` → `pslr`) through pak. With GitHub unreachable it fails with a pak 403 rather than a README problem — which is why `--all` is not the default.

**Do not rely on the pre-push hook as the only trigger.** It fires on `git push`, so it never runs while the remote is unreachable — and the per-commit hooks only see *staged* files, so whole-tree problems stay invisible. To check the tree the way pre-push would:

```bash
pre-commit run --all-files --hook-stage pre-push
```

@FP_AGENTS.md
