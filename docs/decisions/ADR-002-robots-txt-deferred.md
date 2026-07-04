# ADR-002: Defer robots.txt parsing to post-v1

- Status: Superseded in part by ADR-006 (2026-07-03)
- Date: 2026-06-28
- Deciders: Bart Turczyński
- Related: `docs/PRD.md` (§2 scope, §9 open decisions), ADR-006

> **Update (ADR-006, 2026-07-03):** the `Sitemap:` directive is now read for
> discovery. Because `Sitemap:` is a group-independent directive, the "thin
> parser" objection below does not apply to it. This ADR's decision still holds
> for robots *rule application* (`Disallow`/`Allow`), which remains out of scope.

---

## Context

Sitemap Protocol 0.9 specifies two discovery mechanisms for sitemaps: well-known
guessed paths and the `Sitemap:` directive in `robots.txt`. Many real-world
deployments list their sitemap URL only in `robots.txt`, making robots.txt
parsing a natural part of sitemap discovery.

Two possible v1 stances were considered:

- **(A)** Include robots.txt fetching and `Sitemap:` directive parsing inside
  `sitemapr`'s discovery logic.
- **(B)** Keep `sitemapr` strictly sitemap-specific; treat robots.txt as a
  separate concern and a possible future package.

---

## Decision

**`sitemapr` v1 will not parse robots.txt, either for discovery or for
`Disallow` rule application.**

- The v1 discovery path (`sitemap_tree()` from a site/root URL) issues
  guesses only: generic well-known paths and CMS-specific paths in a fixed,
  data-driven catalog. It does **not** fetch or parse `robots.txt`.
- Robots-aware discovery (`Sitemap:` directive) and robots rule application
  (respecting `Disallow` during URL-level page inspection) are deferred to
  post-v1.
- If a robots.txt parser for R warrants a dedicated package, it should be
  built and published separately and referenced from `sitemapr`'s documentation
  rather than bundled.

---

## Rationale

1. **Scope containment.** `sitemapr`'s differentiating value is sitemap
   parsing and validation. Bundling a robots.txt parser expands the scope,
   the dependency surface, and the maintenance burden without contributing to
   that core value.
2. **Independent utility.** A robots.txt parser that correctly implements the
   Google-extended `robots.txt` spec (beyond the original `robots.txt` draft)
   has enough surface area to stand alone. Coupling its lifecycle to
   `sitemapr` is a constraint neither package benefits from.
3. **Guessed-path discovery is sufficient for v1.** The fixed guess catalog
   covers the majority of real-world deployments in a CRAN-safe, no-network
   way in tests. Discovery via `robots.txt` is an enhancement that can be
   layered on top of the same `sources` attribute model once a parser exists.
4. **CRAN test isolation.** Every network dependency in the discovery path
   is a fixture or a mock in tests. Adding a robots.txt round-trip would
   require an additional fixture type before tests could run offline.

---

## Consequences

### Positive
- `sitemapr` stays sitemap-specific; no robots.txt grammar, no `User-agent`
  directive handling, no `Disallow`/`Allow` precedence rules.
- Smaller API surface; no need to surface robots-rule compliance flags.
- Tests remain fully offline and CRAN-clean.

### Negative / accepted trade-offs
- Discovery will miss sitemaps listed only in `robots.txt` until the future
  integration is available.
- Users who need robots-aware discovery must supply the sitemap URL directly
  or use an external robots parser themselves.

---

## Alternatives considered (and rejected)

1. **Thin inline robots.txt parser** (fetch → regex-extract `Sitemap:` lines
   only). — Rejected: any production-quality `Sitemap:` extraction still
   needs enough parsing to handle multi-group files and `User-agent: *`
   scoping. A correct thin implementation is almost as large as a full parser.
2. **`Suggests` dependency on a future `robotsr` package.** — Rejected for
   v1: no such CRAN package exists, so adding a `Suggests` entry now would
   be an unresolvable dependency. Re-evaluate once a package exists.

---

## Revisit conditions

- A CRAN-published robots.txt parser with sufficient test coverage is
  available.
- User demand (GitHub issues, downloads) confirms that guessed-path discovery
  alone is a meaningful friction point.
