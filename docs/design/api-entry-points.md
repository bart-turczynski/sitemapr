# Design proposal: API entry points and the intent-first workflow

- Status: **Resolved → `docs/decisions/ADR-007-api-entry-points.md`
  (2026-07-11):** `discover_sitemaps()` / `resolve_sitemap()` superseded by
  existing exports (`sitemap_tree(from = "root")` and `read_sitemap()`);
  `probe_url()` accepted as the one new primitive; cross-stream defaults settled
  by shipped behaviour (ADR-003 / ADR-006). The body below is retained as the
  historical proposal that ADR-007 resolves.
- Date: 2026-07-04
- Related: `docs/architecture.md` (§4 slice map, §7 output contracts);
  ADR-002 / ADR-006 (robots.txt discovery); the fixed-sitemap-output proposal
  (`docs/design/fixed-sitemap-output.md`)

---

## Problem

The package exposes **parser operations**, but users arrive with an **intent**.
The current mental model forces the user to classify the input before the
package will help them:

- A sitemap URL goes to a sitemap function.
- A sitemap index URL goes to a sitemap index function.
- A URL discovered through another source is expected to play by the rules of
  the "master" source that led to it.
- If the user simply tries a URL, they may not get the same useful preview they
  would get by opening the raw URL in a browser.

That asks users to classify the input **too early**. The deeper issue is not
only "the user must know whether this URL is a sitemap or a sitemap index" — it
is that the API is shaped around parser operations while users start from
intent. Plausible user intents:

- "What is this URL?"
- "What sitemap data can I get from this site?"
- "Give me all page URLs represented by this sitemap system."
- "Show me the sitemap structure without flattening it."
- "Validate or debug this site's sitemap setup."

These are different workflows, but they all begin with the same action: pasting
a URL.

---

## Design lean

**Keep the low-level readers strict; add a forgiving top-level entry point.**

Strict parser functions remain valuable and should stay strict — they are good
for reproducibility, testability, and users who already know what artifact they
hold:

- A sitemap reader expects a `<urlset>`.
- A sitemap index reader expects a `<sitemapindex>`.
- If the input is the wrong XML root, the function errors.
- **The error message states what was detected and what to call next.** For
  example, if a user passes a sitemap index to a sitemap reader, the error says
  that a sitemap index was detected and suggests an index reader or an automatic
  resolver.

Alongside those, the package needs an **inspection / probing layer** — a
function whose job is not to fully resolve everything, but to tell the user what
they have. This is the package equivalent of opening the raw URL in a browser
and looking around before choosing what to do next.

---

## Proposed three-verb split

Keep exploratory, discovery, and flattening workflows separate instead of asking
one magical function to carry every use case.

```r
probe_url(url)
discover_sitemaps(site_or_url)
resolve_sitemap(url)
```

### `probe_url(url)` — "what is this?"

A non-resolving inspection. Returns:

- `url`
- `final_url`
- `status_code`
- `content_type`
- `detected_type` ∈ `{sitemap, sitemap_index, robots_txt, html, xml_other,
  not_found, fetch_error, parse_error}`
- `xml_root`
- `is_compressed`
- `child_count`
- `sample`
- `problems`
- `suggested_next`

### `discover_sitemaps(site_or_url)` — find candidates

Starts from a site root, page URL, or robots.txt and finds sitemap candidates.

### `resolve_sitemap(url, ...)` — follow to final page URLs

Follows sitemap indexes and returns the final page URLs.

```r
resolve_sitemap(
  url,
  follow = TRUE,
  max_depth = 2,
  same_host = TRUE,
  allow_cross_host = FALSE
)
```

---

## Cross-stream policy (defaults still open)

"Cross streams" needs an explicit policy. Sitemap indexes can point to resources
that do not behave exactly like the original resource — they may cross hosts or
change format. A conservative default may be sensible, but the policy must be
stated explicitly rather than emerging by accident:

- Should child resources always play by the parent / master source's rules, or
  be interpreted independently once discovered?
- Should cross-host children be followed by default?
- Should differing content-types or compressed children be allowed by default?
- Should nested sitemap indexes be followed by default?

The arguments above (`follow`, `max_depth`, `same_host`, `allow_cross_host`)
sketch the surface; the right **defaults** are still open.

---

## Return-shape tension

Two competing directions:

1. **Typed objects per kind** — `sitemap`, `sitemap_index`, `robots_sitemaps`,
   `sitemap_tree`, `sitemap_resolution`. Cleaner for strict readers.
2. **One wrapper object** with a `type` field and typed `data`. Easier for
   probing and diagnostics.

**Compromise lean:** strict readers return strict typed objects; exploratory
functions return a wrapper result with `type`, `data`, `messages`, and
`problems`.

---

## Product principle candidate

**Low-level functions are strict; the main exploratory entry point is
forgiving** — because "I have a URL, tell me what is useful here" is itself a
valid sitemap workflow.

---

## Open questions

- Is the primary missing feature a permissive top-level reader, or specifically
  a probe / inspection function? (This is the real gap to name.)
- Should the first user-facing experience be "diagnose first" or "resolve to
  final URLs first"?
- What should happen when a sitemap index is passed to a sitemap reader?
- What should happen when a site root or HTML page is passed to sitemap tooling?
- Should robots.txt discovery be part of the default path?
- How much should the package infer before requiring an explicit user choice?
- What should be returned on partial success — e.g. one broken child sitemap in
  an otherwise valid sitemap index?
- Do users need a structural view of the sitemap graph in addition to a
  flattened URL table?
