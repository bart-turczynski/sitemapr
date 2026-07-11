# ADR-007: API entry points — probe accepted, discover/resolve superseded

- Status: Accepted
- Date: 2026-07-11
- Deciders: Bart Turczyński
- Supersedes (in part): the three-verb proposal in
  `docs/design/api-entry-points.md`
- Related: `docs/design/api-entry-points.md` (the exploratory proposal this
  resolves); ADR-003 (network safety policy); ADR-006 (robots-aware sitemap
  discovery); `docs/architecture.md` (§4 slice map, §7 output contracts)

---

## Context

`docs/design/api-entry-points.md` (2026-07-04) captured a design tension: the
package exposes *parser operations* while users arrive with an *intent*
("what is this URL?", "what sitemap data can I get from this site?", "give me
all page URLs"). To close that gap it proposed a three-verb split:

```r
probe_url(url)
discover_sitemaps(site_or_url)
resolve_sitemap(url)
```

Since that proposal was written, the exports it anticipated have shipped. Two
of the three proposed verbs now duplicate existing behaviour, and only one
names a genuine gap. This ADR records the reshape and answers every open
question the proposal left dangling. The proposal document is retained as a
historical record; its status line is graduated to point here.

The three questions this ADR settles:

1. Which of the three proposed verbs, if any, should become public API?
2. What is the cross-stream (follow / host / format) policy, and is it open?
3. How is each open question in the proposal resolved?

---

## Decision

### 1. `discover_sitemaps()` and `resolve_sitemap()` are superseded by existing exports — not added

Both proposed verbs are already realized by shipped, exported functions:

- **Discovery** is `sitemap_tree(x, from = "root")`. Per ADR-006 it fetches
  `<origin>/robots.txt`, harvests every valid `Sitemap:` directive, composes
  that with the guessed-path catalog (`use_robots` / `use_known_paths`, both
  default `TRUE`), and returns the discovered sitemap structure. That *is*
  `discover_sitemaps(site_or_url)`.
- **Resolution** is `read_sitemap()`. It already auto-follows sitemap indexes
  and returns the final page URLs — it is the "forgiving resolver" the
  proposal describes under `resolve_sitemap(url)`.

Adding `discover_sitemaps()` and `resolve_sitemap()` as new exports would ship
thin near-synonyms of existing functions. The cost (a wider public surface, a
migration burden, and documentation that must forever explain why two names do
one job) is not repaid by any new capability. **They are rejected as
superseded-by-existing-API.**

### 2. `probe_url()` is accepted — the one genuine gap

The permissive *reader* already exists (`read_sitemap()`). What does not exist
is a permissive **probe**: a lightweight, **non-resolving** inspection that
answers "what is this URL?" without expanding indexes or following children.
`probe_url()` fills exactly that gap.

`probe_url()` is a thin composition over existing internals — it wraps the
current `fetch_source()` (one fetch, ADR-003 safety policy applied) and
`sniff_format()` (byte-level classification, no `xml2` parse) and returns a
small typed record. It does **not** introduce a new fetch path, a new safety
model, or a new classification vocabulary.

**Return shape** — a single typed record aligned with the existing
`sitemap_audit` / `problems` convention (it is a diagnostic record, not a new
wrapper taxonomy):

| Field | Meaning |
|---|---|
| `url` | the URL as supplied by the caller |
| `final_url` | URL after redirects (ADR-003 revalidates each hop) |
| `status_code` | HTTP status of the final response |
| `content_type` | `Content-Type` header as received |
| `detected_type` | classification derived from `sniff_format()`: `sitemap` (`xml-urlset`, or a plain-text URL list — sniff `text` that is not robots.txt — consistent with `read_sitemap()`'s text-sitemap support), `sitemap_index` (`xml-sitemapindex`), `feed`, `robots_txt`, `html`, `xml_other` (`xml`), plus the fetch/parse error states below |
| `xml_root` | first XML element name, when the body is XML |
| `is_compressed` | whether the body was gzip/archive-wrapped |
| `child_count` | number of direct children for an index (counted, **not** followed) |
| `sample` | a small excerpt of the body for eyeballing |
| `problems` | zero or more `problems`-convention findings |
| `suggested_next` | the function to call next (e.g. `read_sitemap()` for an index) |

`detected_type` reuses `sniff_format()`'s closed classification set rather than
inventing a taxonomy. Fetch and parse failure states (`not_found`,
`fetch_error`, `parse_error`) are surfaced through `detected_type` plus
`problems`, keeping the record shape stable on the unhappy path. Crucially,
`probe_url()` **counts** an index's children but never fetches them — that is
what makes it a probe and not a resolver.

### 3. Cross-stream defaults are NOT open — they were settled by shipped behaviour

The proposal's "Cross-stream policy (defaults still open)" section is closed.
The defaults are already decided by what `read_sitemap()` / `sitemap_tree()`
ship and by ADR-003 / ADR-006:

- **Same-host follow by default.** Index children are followed only on the same
  host; cross-host children are not followed by default (`allow_cross_host` is
  off by default). Children are interpreted under the parent traversal's rules,
  not independently.
- **Depth and count caps apply** (ADR-003 §3: max index children 50 000, max
  discovery candidates 25, max redirects 5, request timeout 30 s). Nested
  sitemap indexes are followed within those caps.
- **Format and compression are handled, not gated.** Compressed children are
  transparently decompressed within the ADR-003 size ceilings; a differing
  content-type is classified by `sniff_format()` (content, not header) and
  handled or reported, not silently followed as something it is not.
- **Every limit is caller-overridable** (ADR-003 §3: no non-overridable hard
  caps), but the *defaults* are conservative and fixed by the shipped
  behaviour, not reopened here.

`probe_url()` does not participate in cross-stream traversal at all — it fetches
exactly one resource — so these defaults bind only the resolving/discovering
functions that already implement them.

### 4. Resolution of the proposal's open questions

**"Open questions" section:**

1. *Is the primary missing feature a permissive top-level reader, or
   specifically a probe / inspection function?* — Specifically a **probe**. The
   permissive reader already exists (`read_sitemap()`); the missing thing is a
   non-resolving inspection, which `probe_url()` provides.
2. *Should the first user-facing experience be "diagnose first" or "resolve to
   final URLs first"?* — Both are first-class and the user chooses:
   `probe_url()` for diagnose-first, `read_sitemap()` for resolve-first. The
   package does not impose one order.
3. *What should happen when a sitemap index is passed to a sitemap reader?* —
   The strict reader errors, and the error states what was detected (a sitemap
   index) and what to call next (`read_sitemap()` / `probe_url()`). This is the
   proposal's own "Design lean" and is retained unchanged.
4. *What should happen when a site root or HTML page is passed to sitemap
   tooling?* — Discovery from a root is `sitemap_tree(from = "root")`
   (robots.txt + guessed paths per ADR-006); an HTML page fed to `probe_url()`
   is classified `html` with a `suggested_next` pointing at root discovery. No
   HTML crawling or link scraping is added.
5. *Should robots.txt discovery be part of the default path?* — **Yes**, already
   decided by ADR-006: `use_robots = TRUE` by default in
   `sitemap_tree(from = "root")`. Only the `Sitemap:` directive is read; robots
   *rules* are never fetched or applied.
6. *How much should the package infer before requiring an explicit user
   choice?* — Strict readers infer nothing (wrong root → error with guidance).
   `probe_url()` infers only classification and a suggestion, and takes no
   follow-on action. `read_sitemap()` infers index-following within the ADR-003
   caps. Inference never crosses hosts or ignores caps silently.
7. *What should be returned on partial success (e.g. one broken child in an
   otherwise valid index)?* — The existing partial-result contract stands: the
   audit/validation pipeline returns what it could resolve plus `problems`
   findings for the broken child; it does not fail the whole traversal. This is
   the shipped `sitemap_audit` behaviour, not a new rule.
8. *Do users need a structural view of the sitemap graph in addition to a
   flattened URL table?* — Yes, and it already exists: `sitemap_tree()` returns
   the structural view; `read_sitemap()` returns the flattened URL table. No new
   structural type is needed.

**"Cross-stream policy" bullets** (see Decision §3 for the full policy):

- *Should child resources play by the parent's rules or be interpreted
  independently?* — By the parent traversal's rules.
- *Should cross-host children be followed by default?* — No.
- *Should differing content-types or compressed children be allowed by
  default?* — Compressed children: yes (decompressed within ADR-003 ceilings).
  Content-type is classified by content via `sniff_format()`; a child is
  handled or reported per that classification, not followed blindly.
- *Should nested sitemap indexes be followed by default?* — Yes, within the
  ADR-003 depth/count caps.

**"Return-shape tension":** Resolved as the proposal's own compromise lean —
strict readers return strict typed objects; the exploratory `probe_url()`
returns a single typed diagnostic record aligned with the `problems` /
`sitemap_audit` convention. No general one-wrapper-per-call taxonomy is
introduced.

---

## Consequences

### Positive

- The public surface grows by exactly one function (`probe_url()`) and only
  where a real gap exists; no synonym exports, no migration burden.
- `probe_url()` reuses `fetch_source()` and `sniff_format()`, so it inherits the
  ADR-003 safety policy and the ADR-006 discovery behaviour for free and adds no
  new fetch path or classification vocabulary.
- Every open question in the design proposal now has a recorded answer; future
  contributors do not reopen settled cross-stream defaults.
- The diagnostic record aligns with the existing `problems` / `sitemap_audit`
  convention, so tooling and docs stay consistent.

### Negative / accepted trade-offs

- `probe_url()` is deliberately non-resolving: a user who wants final page URLs
  must follow up with `read_sitemap()`. This two-step path is accepted as the
  cost of a clean "inspect vs. resolve" separation.
- The "diagnose vs. resolve first" order is left to the user rather than
  prescribed; documentation must make both entry points discoverable.

### Follow-up implementation

- **`probe_url()` primitive** — implement the accepted probe as described above
  (wrap `fetch_source()` + `sniff_format()`, return the typed record, no index
  expansion). The maintainer will file the tracking FP child; this ADR does not
  file it.
