# Design proposal: fixed-sitemap output (serialization + repair)

- Status: **Exploratory — not yet decided.** This is a proposal capturing an
  open design tension; it is not a settled decision. Resolved parts should
  graduate to a `docs/decisions/` ADR.
- Date: 2026-07-04
- Tracker: SITE-rjwpnwnt
- Related: `docs/architecture.md` (§7 output contracts); ADR-004
  (validation consumes a faithful parse; `lastmod`/`priority` kept as raw
  trimmed strings); ADR-005 (validation reports the delta, does not rewrite);
  the API entry-points proposal (`docs/design/api-entry-points.md`)

---

## Framing

We already hold two views of a sitemap, both produced today:

- `read_sitemap()` → the tidy row model (`loc`, `lastmod`, `priority`,
  extension list-columns, provenance). The **content** view.
- `validate_sitemap()` → the findings tibble (coded, severity-ranked). The
  **diagnosis** view.

What is missing is serialization **back out** to XML — call it
`write_sitemap()` / `as_sitemap_xml()`: emit a corrected sitemap or
sitemapindex, since we already diagnose every issue. Everything upstream of it
exists; this is the genuinely novel capability.

---

## "Corrected" is a repair policy, not free — three tiers

1. **Reformat (lossless).** Re-emit the same URLs as well-formed, canonically
   indented XML. Fixes malformed markup, encoding declarations, whitespace.
   Drops nothing. Cheapest, safest.
2. **Repair (drop / clamp).** Remove URLs that fail schema / protocol,
   re-escape unescaped `loc`s, clamp `priority` to `[0, 1]`, dedupe. Each fix
   maps to a finding code — **this is the tier that actually uses the
   findings.**
3. **Canonicalize (rewrite values).** Normalize `lastmod` to W3C datetime,
   lowercase host, resolve equivalent URLs. Ambitious.

**Key constraint on tier 3:** per ADR-004 the package deliberately keeps
`lastmod` / `priority` as raw trimmed strings and defers the normalization
unwind to Layer F. So a canonicalize output **forces building Layer F** — that
is a whole layer, not a convenience.

**Lean:** ship **tier 2 (repair)**, with tier 1 as its degenerate case (a clean
file reformats identically). Scope tier 3 (Layer F) out of the first cut. Every
dropped or changed element must be traceable to a finding code, so the output is
explainable.

---

## Relationship to the entry-point redesign — keep separate

The probe / discover / resolve, strict-vs-forgiving, and wrapper-vs-typed
material in `docs/design/api-entry-points.md` is an **input** redesign; the
fixed-sitemap feature is an **output** transform. Mostly orthogonal — one input,
one output. Resist letting the small shippable convenience get swallowed by the
big API question.

The **one place they touch**: the "library-created-and-used R object" idea. If
`read_sitemap()` returned a proper `sitemap` S3 object (rows + sources +
problems, with `print` / `format` / `write_sitemap` methods), then "get the
fixed sitemap" becomes a **method on an object the user already holds**, not a
fourth top-level verb. That is the seam the entry-point notes are groping toward
— but it is a bigger change and ripples into the return-shape question.

**Lean:** standalone function first, S3 object later. Prove the repair semantics
are useful before committing to an object model; the function can be
re-expressed as a method later without breaking callers.

---

## Prior art: `fljoly/xsitemap`

A discovery + liveness package (6 functions, no object model). `sitemapr`
already covers everything it does, more carefully (capped index expansion, SSRF
guards, a real findings contract, a tidy row model):

| xsitemap | sitemapr equivalent |
|---|---|
| `xsitemapGet()` | `read_sitemap()` |
| `xsitemapGuess()` | `sitemap_tree(from = "root")` guessed-path catalog |
| `xsitemapGetFromRobotsTxt()` | robots.txt discovery (ADR-006) |
| `xsitemapCheckWordpress()` | WP / Shopify catalog |
| `xsitemapCheckHTTP()` | **not present in sitemapr** |

No generation / repair / writing / object model — which confirms serialization
is novel territory, not a solved problem to reinvent.

### The one idea worth stealing: liveness checking

`xsitemapCheckHTTP()` checks whether each `<loc>` actually returns 200 (vs
404 / 410 / 301). This is **orthogonal** to our validation axis (well-formed +
protocol-conformant): a perfectly valid sitemap can be full of dead links. It is
also the **strongest input to repair tier 2** — "the fixed sitemap" is far more
compelling if it can drop URLs that are *dead*, not just *malformed*.

Caveats: expensive (one request per URL); network fan-out with the same SSRF /
rate concerns; makes output **non-deterministic** (time-dependent).

**Lean:** treat liveness as **opt-in enrichment only**, never default repair.
It might stand alone as its own verb (`check_urls_live()`) or become a new
finding layer (`LIVENESS_*`, severity `info`) — arguably it belongs to the
entry-point API conversation more than to the fixed-sitemap cut. Keep the first
fixed-sitemap cut **purely structural** (schema / protocol-driven repair) and
track liveness separately.

---

## Open decisions

- **Repair tier:** ship tier 2 (findings-driven repair); defer tier 3
  (Layer F canonicalization)? Or also attempt tier 3?
- **Output target:** string return (`as_sitemap_xml()`) vs write-to-file
  (`write_sitemap()`) vs both. Does a repaired **index** re-emit an index, or
  flatten to one urlset?
- **Object model:** standalone function now, or introduce the `sitemap` S3
  object?
- **Explainability:** carry a "what we changed" report (an attribute tibble
  keyed to finding codes), or just emit the clean file?
