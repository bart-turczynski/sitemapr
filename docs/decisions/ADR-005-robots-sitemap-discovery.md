# ADR-005: Robots-aware sitemap discovery via the `Sitemap:` directive

- Status: Accepted
- Date: 2026-07-03
- Deciders: Bart Turczyński
- Supersedes (in part): ADR-002
- Related: `docs/architecture.md` (§7), SITE-stxkwfbq

---

## Context

ADR-002 deferred all robots.txt handling out of v1, keeping `sitemapr`
sitemap-specific. Its stated objection to a "thin inline robots.txt parser" was
that any correct `Sitemap:` extraction "still needs enough parsing to handle
multi-group files and `User-agent: *` scoping."

That objection is mistaken for the discovery use case. The `Sitemap:` directive
is **group-independent**: per the robots.txt specification (and Google's
extended spec), `Sitemap:` is a non-group field that applies to the entire file
regardless of any `User-agent` grouping. `User-agent` scoping only governs
`Disallow`/`Allow` rules. So harvesting sitemap URLs needs a focused directive
extractor, not a full grammar with group parsing.

Real-world testing confirmed the cost of the deferral: many sites (e.g. a
WordPress + Yoast deployment tested on 2026-07-03) publish their sitemaps only
at non-guessed, locale-scoped paths listed exclusively in robots.txt, which the
guessed-path catalog can never discover.

---

## Decision

**`sitemapr` discovers sitemaps from the robots.txt `Sitemap:` directive.**

- `sitemap_tree(x, from = "root")` fetches `<origin>/robots.txt` and adds every
  valid `Sitemap:` directive as a discovery candidate with provenance
  `"robots"`, deduplicated against the guessed-path catalog on the full-URL
  identity key (robots directives take precedence).
- The behaviour is controlled by two flags, both defaulting to `TRUE`:
  `use_robots` (read robots.txt) and `use_known_paths` (try the guessed-path
  catalog). They compose, so a caller can run robots-only, guess-only, or both.
- Only the `Sitemap:` directive is read. **Robots rules (`Disallow`/`Allow`) are
  never fetched, parsed, or applied** — that remains out of scope, as in
  ADR-002.
- A missing, unreachable, or malformed robots.txt contributes nothing and never
  fails discovery; a non-absolute-http `Sitemap:` value is skipped with a
  warning.

This supersedes ADR-002 **only** for the `Sitemap:` directive. ADR-002's
decision to keep robots *rule application* (`Disallow`/`Allow`) out of scope
still stands.

---

## Rationale

1. **Correctness of the thin extractor.** Because `Sitemap:` is group-
   independent, a per-line directive extractor is a complete and correct
   implementation for discovery — ADR-002's scoping concern does not apply.
2. **Discovery completeness.** robots.txt is the standard channel for
   advertising sitemaps at arbitrary paths; without it, discovery misses sites
   whose sitemaps are not at well-known locations.
3. **Bounded scope.** Reading one non-group directive adds no `User-agent`
   grammar, no rule-precedence logic, and no new dependency.
4. **CRAN test isolation preserved.** The robots.txt fetch goes through the same
   mockable `fetch_source()` path as every other request; tests remain offline.

---

## Consequences

### Positive
- Discovery finds sitemaps listed only in robots.txt.
- The guessed-path catalog and robots discovery compose behind two flags.
- No robots *rule* machinery enters the package.

### Negative / accepted trade-offs
- `sitemap_tree(from = "root")` now issues one extra request (`/robots.txt`)
  per call by default. Callers who want the prior guess-only behaviour set
  `use_robots = FALSE`.
- `sitemapr` now fetches robots.txt, a small widening of scope beyond strictly
  sitemap resources — accepted as intrinsic to sitemap discovery.
