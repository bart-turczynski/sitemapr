# sitemapr architecture

The architecture lives in [`docs/architecture.md`](docs/architecture.md): the
layer model (A–F), the output contracts and the constraints the package keeps.
This file is the fixed entry point every package in the fleet carries.

- Settled design decisions: [`docs/decisions/`](docs/decisions/).
- Finding codes and the layer vocabulary:
  [`docs/findings-contract.md`](docs/findings-contract.md).
- The verify gate and repository hooks:
  [`docs/repo-hygiene.md`](docs/repo-hygiene.md).
- Maintainer notes kept out of `CONTRIBUTING.md`: the CRAN release deltas,
  [`design/release-deltas.md`](design/release-deltas.md), and what CI runs on
  a branch, [`design/ci-on-branches.md`](design/ci-on-branches.md).
