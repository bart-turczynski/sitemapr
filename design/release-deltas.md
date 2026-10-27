# sitemapr's CRAN release deltas

Follow the fleet checklist,
[seor `design/release-checklist.md`](https://gitlab.com/bart-turczynski/seor/-/blob/main/design/release-checklist.md).
sitemapr's deltas:

- **Step 1: robotstxtr reaches CRAN first.** `DESCRIPTION` suggests
  `robotstxtr (>= 0.3.0)` and pins it with
  `Remotes: gitlab::bart-turczynski/robotstxtr@v0.3.0`. Once robotstxtr is on
  CRAN, drop the pin and the `Remotes:` field with it (SEOR-jkmrvikj).
- **Step 4: `cran-comments.md` describes robotstxtr in CRAN incoming.** Its
  `Remotes` and `Suggests` note items and its Dependencies section are
  written for the state before robotstxtr is accepted. Once Step 1 is done,
  finalize them against `DESCRIPTION`, and update the check results to the
  final pre-submission runs (SITE-notumkrs).
- **Step 14: the first release creates sitemapr's first Zenodo record.** No
  sitemapr record exists yet (Zenodo search, 2026-10-22), so the GitHub
  Release starts a new concept DOI. Before it, the owner checks that the
  mirror is ON in Zenodo's GitHub settings. No record is linked to the
  mirror's repository id: `zenodo.org/badge/latestdoi/1282558407` answers 404.
