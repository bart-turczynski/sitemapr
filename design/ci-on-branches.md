# CI on a branch

What runs between a push and the merge, moved from `CONTRIBUTING.md`. The full
account of the jobs is in [`docs/repo-hygiene.md`](../docs/repo-hygiene.md),
"Pre-push verify gate".

The pre-push hook runs the verify command, `Rscript tools/verify.R`.
It is the first gate, and on a branch the
only one that runs on its own: branch and merge-request pipelines are no longer
created (SEOR-bmgkzhvy), so nothing runs between your push and the merge unless
you ask for it. You can — start a pipeline at **Build > Pipelines > Run
pipeline**, pick the branch, and the same `check` runs on the server.
