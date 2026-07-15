# Findings contract

This document defines `validate_sitemap()`'s output tibble as a
**compatibility contract**. Column names, layer vocabulary, `subject_ref`
format, and finding codes are stable across releases. Adding a new column or
a new code value is a documented addition. Removing or renaming any of the
above is a documented breaking change.

The **machine-readable catalog of every finding code** — its canonical name,
default severity, layer, subject type, strict-only flag, and the
`sitemap-validator` alias it reconciles with — lives in
[`findings-registry.csv`](findings-registry.csv). That CSV is the single
source of truth shared with the sibling TypeScript implementation
(`sitemap-validator`); this document is the prose contract that explains it.
When the two disagree, the CSV wins for code metadata and this document wins
for structure and semantics.

---

## Output tibble columns

| Column | Type | Description |
|---|---|---|
| `code` | `character` | Machine-readable finding code (see `findings-registry.csv`). Stable across releases; changes are breaking. |
| `severity` | `character` | `"fatal"` / `"error"` / `"warning"` / `"info"` |
| `layer` | `character` | Which processing layer produced this finding (see layer vocabulary). |
| `subject_type` | `character` | What the finding refers to (`"document"`, `"entry"`, `"field"`, `"index-child"`, `"archive-member"`, `"source"`, `"report"`). |
| `subject_ref` | `character` | Stable reference within the subject (e.g. `"sitemap://example.com/sitemap.xml"`, `"sitemap://…#entry:42"`, `"sitemap://…#field:loc"`). Never a raw integer offset; always anchored to a stable identifier. |
| `message` | `character` | Human-readable description of the finding. Suitable for display; may change across patch releases. |
| `evidence` | `list` | Named list: `excerpt` (character ≤ 500 chars; ≤ 200 chars for text-sitemap lines), `line` (integer or `NA`), `column` (integer or `NA`). Always a normalized snippet, never raw parser output. |
| `mode` | `character` | The mode under which the finding was produced: `"strict"` or `"non-strict"`. |
| `is_strict_only` | `logical` | `TRUE` if the rule only fires in `strict` mode and is suppressed in `non-strict`. |
| `remediation_hint` | `character` | Optional. A short actionable suggestion. `NA` when not applicable. |

---

## Layer vocabulary

The `layer` column is constrained to this fixed set:

| Value | What it covers |
|---|---|
| `"input"` | Entrypoint normalization; format of the user-supplied argument |
| `"fetch"` | Network request, redirect chain, SSRF guard, timeout, body limit |
| `"discovery"` | Guessed-path candidate evaluation |
| `"classification"` | Byte-level format sniffing and encoding checks |
| `"decompression"` | Gzip / archive extraction |
| `"schema"` | XSD Layer C validation |
| `"protocol"` | Protocol/semantic Layer D checks |
| `"index-expansion"` | Sitemap index recursion, cycle detection, depth/count caps |
| `"page"` | Per-URL page inspection (Layer E, v0.2) |
| `"robots"` | robots.txt allow/disallow testing (v0.2) |
| `"report"` | Finding assembly, dedup, cross-source aggregation |

`"robots"` is emitted by the opt-in robots allow/disallow check (Layer E check
#7; `validate_sitemap(check_robots = TRUE)`); it stays empty on a default call.
`"page"` remains reserved for the rest of the v0.2 per-URL inspection epic (the
`PAGE_*` codes) and is not yet emitted. Encoding findings (`ENCODING_*`) are
emitted under `"classification"`, not a separate encoding layer.

---

## Subject ref format

`subject_ref` values follow a stable URI-like scheme:

```
sitemap://<normalized-sitemap-url>[#<fragment>]
```

Fragments (present when the finding is scoped below document level):

| Fragment | Meaning |
|---|---|
| `#entry:<n>` | The nth URL entry (1-based) within the document |
| `#field:<name>` | A specific element or attribute name within an entry |
| `#index-child:<url>` | A child `<loc>` in a `sitemapindex` |
| `#archive-member:<path>` | A file path within a `.tar.gz` archive |
| `#line:<n>` | A specific line in a text sitemap |
| `#page-url:<url>` | An advertised page URL being tested (the `page-url` subject) |

The `page`/`robots` layers use the `page-url` subject to scope a finding to one
advertised page URL. Its `subject_ref` anchors to the sitemap that advertised
the URL and names the page in the fragment:
`sitemap://<sitemap-url>#page-url:<url>`. The `robots` layer emits it today; the
`page` layer will reuse it when the rest of Layer E lands.

---

## Strict-vs-non-strict behavior

`mode` and `is_strict_only` together encode the SPEC's failure-behavior model.
These transforms are **systematic** (rule-based, not per-code), which is why
`findings-registry.csv` records each code's *base* emitted severity and lets
these rules derive the mode-specific value:

- **`mode`** records the mode the call was made in (`"strict"` or
  `"non-strict"`), not whether the rule *is* strict-only.
- **`is_strict_only = TRUE`** means the rule fires only in strict mode; under
  `non-strict`, no row is emitted for this code at all. Exactly three codes:
  `PROTOCOL_LASTMOD_DATE_ONLY`, `HREFLANG_HREF_RELATIVE`,
  `PROTOCOL_TEXT_BLANK_LINE`.
- **Schema-layer downgrade:** any `layer == "schema"` finding at `fatal`/`error`
  is downgraded to `warning` in `non-strict`. This keys on the layer; the only
  base-`error` schema code it affects is `SCHEMA_INVALID`
  (`SCHEMA_UNKNOWN_NAMESPACE` is base `warning`, advisory in both modes).
- **Strict elevation `info → warning`:** exactly two codes are emitted at `info`
  but elevated to `warning` in strict mode (they still appear as `info` in
  non-strict): `ENCODING_BOM_DECLARATION_CONFLICT` and
  `PROTOCOL_LASTMOD_LOOKS_GENERATED`.
- **Content-driven severity (not mode-driven):** `PROTOCOL_URL_NOT_ESCAPED` is
  `warning` when the raw `loc` contains a character illegal in both a URI and an
  IRI, and `info` when the raw `loc` is a valid IRI whose URI form is what
  crawlers fetch. The CSV records `warning` as its base.

`SCHEMA_INVALID` is emitted with `subject_type = "field"` for a located element
failure and `"document"` for a document-generic failure; the CSV records
`"field"` as its base.

---

## Finding code taxonomy

Codes are namespaced by a layer-oriented prefix. The authoritative list — with
severity, layer, subject type, strict flag, sitemapr implementation status, and
the reconciling `sitemap-validator` code — is `findings-registry.csv`. The
prose below documents the semantics of the v1 codes sitemapr emits or reserves.

### Fetch codes (`FETCH_*`)
- `FETCH_FAILED` — the submitted source could not be fetched or read for a
  reason not covered by a more specific fetch code; in batched validation this
  lets other submitted sources continue. `fatal`.
- `FETCH_BODY_CEILING_EXCEEDED` — the per-resource safety ceiling (default
  500 MB of decompressed/effective bytes) was exceeded; the body is discarded
  and the source returns a partial result. `fatal`. (See ADR-003 §3.)
- `FETCH_TIMEOUT` — the request exceeded the wall-clock timeout (default 30 s);
  no usable body. `fatal`.

Scalar `read_sitemap()` / `validate_sitemap()` calls and parse APIs still
surface these as classed conditions where that was the historical behavior.
Batched `validate_sitemap()` / `validate_sitemaps()` calls emit the fetch
finding and continue with other submitted sources; batched `read_sitemap()` /
`read_sitemaps()` records the failed source in the `problems` attribute.

### Schema codes (`SCHEMA_*`)
- `SCHEMA_INVALID` — document fails XSD validation (Layer C)
- `SCHEMA_UNKNOWN_NAMESPACE` — namespace not recognized and not imported into
  the runtime-generated profile

### Protocol codes (`PROTOCOL_*`)
- `PROTOCOL_URL_COUNT_EXCEEDED` — more than 50 000 URL entries
- `PROTOCOL_SIZE_EXCEEDED` — sitemap exceeds 50 MB uncompressed (the protocol
  size limit). Non-fatal: the body is still read so other findings surface.
- `PROTOCOL_DUPLICATE_LOC` — two entries share a **byte-identical** `loc`
  (`warning`). A sitemapr lint: sitemaps.org is silent on duplicates (ADR-005).
- `PROTOCOL_URL_EQUIVALENT` — two entries' `loc` values are not byte-identical
  but resolve to the same RFC-3986/3987-canonical URL (`warning`; message names
  the resolved form). A sitemapr lint (ADR-005).
- `PROTOCOL_PRIORITY_OUT_OF_RANGE` — `priority` outside `[0.0, 1.0]`
- `PROTOCOL_CHANGEFREQ_INVALID` — `changefreq` not in the enum
- `PROTOCOL_LASTMOD_INVALID` — `lastmod` not a valid W3C Date-Time value
- `PROTOCOL_LASTMOD_DATE_ONLY` — date-only `lastmod`; strict-only `info`
- `PROTOCOL_LASTMOD_ALL_IDENTICAL` — all/most `lastmod` values identical;
  `warning`. Corpus-level (`subject_type = "document"`): engines may distrust and
  disregard such dates (Bing).
- `PROTOCOL_LASTMOD_LOOKS_GENERATED` — `lastmod` ≈ sitemap fetch/generation time
  across URLs; `info` (→ `warning` in strict). Corpus-level.
- `PROTOCOL_URL_INVALID_ESCAPE` — malformed percent-encoding in a URL field
  (e.g. `%zz`); a genuine RFC-3986 violation (`error`)
- `PROTOCOL_URL_NOT_ESCAPED` — `loc` is not written in escaped RFC-3986 form
  (sitemaps.org: URLs "must be URL-escaped"; follow RFC-3986/3987 — ADR-005).
  `info` when the raw `loc` is a valid IRI (RFC-3987) whose URI form is what
  crawlers fetch; `warning` when it contains a character illegal in both a URI
  and an IRI (raw space, `<`, `>`, `{`, `}`, …). XML entity-escaping of
  `& ' " < >` stays a Layer C concern (`SCHEMA_INVALID`), not this code.
- `PROTOCOL_URL_NOT_ABSOLUTE` — `loc` is not an absolute `http`/`https` URL
- `PROTOCOL_URL_NO_HOST` — `loc` has no host component
- `PROTOCOL_URL_TOO_LONG` — `loc` exceeds 2 048 characters (XML; the
  text-sitemap variant is `PROTOCOL_TEXT_URL_TOO_LONG`)
- `PROTOCOL_URL_OUT_OF_SCOPE` — `loc` does not share scheme+host+port+path
  prefix with its parent sitemap file
- `PROTOCOL_URL_FRAGMENT` — `loc` contains a fragment (`info`)
- `PROTOCOL_URL_USERINFO` — `loc` contains userinfo (`info`)
- `PROTOCOL_IMAGE_COUNT_EXCEEDED` — more than 1 000 images per page entry
- `PROTOCOL_VIDEO_FIELD_INVALID` — video extension field fails protocol rules
  (e.g. `duration` outside 1–28 800 s, `rating` outside 0.0–5.0, more than 32
  `<video:tag>`, missing required child)
- `PROTOCOL_NEWS_FIELD_INVALID` — news extension field fails protocol rules
- `PROTOCOL_NEWS_COUNT_EXCEEDED` — more than 1 000 `<news:news>` entries per file
- `PROTOCOL_TEXT_URL_TOO_LONG` — text sitemap URL exceeds 2 048 chars
- `PROTOCOL_TEXT_BLANK_LINE` — blank line in text sitemap; strict-only `info`

### Hreflang codes (`HREFLANG_*`)
All `layer = "protocol"` (semantic). Schema-layer structural failures of an
`xhtml:link` surface under the generic `SCHEMA_INVALID` code, never a
hreflang-prefixed one (see `docs/sitemap-spec.md` §5.4).
- `HREFLANG_FORMAT_INVALID` — token not in the accepted family (`lang`,
  `lang-REGION`, `lang-Script`, `lang-Script-REGION`, `x-default`); catches
  empty, region-only (`US`), arbitrary tokens (`english`)
- `HREFLANG_SEPARATOR_INVALID` — wrong separator/structure (`en_US`, `en--US`)
- `HREFLANG_NONSTANDARD_CASE` — casing deviates from convention (lang lowercase,
  Script Title-case, REGION UPPERCASE); the original value is preserved in
  evidence
- `HREFLANG_DUPLICATE` — two `xhtml:link` entries in one `<url>` share the
  same hreflang value
- `HREFLANG_XDEFAULT_INVALID` — `x-default` present but malformed (`X-DEFAULT`,
  `x_default`, whitespace-padded) or duplicated
- `HREFLANG_XDEFAULT_MISSING` — `x-default` absent when other hreflang
  entries are present
- `HREFLANG_LINK_ATTR_INVALID` — missing/invalid required attribute (`rel`
  absent or ≠ `alternate`, `hreflang` or `href` absent)
- `HREFLANG_HREF_RELATIVE` — `href` is relative; strict-only `warning`

The three codes below are **whole-sitemap / cross-URL** checks
(`subject_type = "document"`, `warning`). They read the alternate graph the
sitemap *declares* (offline, from the sitemap bytes alone; the live per-page
return-link check is the deferred Layer E `PAGE_HREFLANG_MISMATCH`). Each
individual `<xhtml:link>` may be syntactically valid yet a search engine can
still ignore an incomplete cluster.
- `HREFLANG_MISSING_SELF_REFERENCE` — a URL declares alternate-language links
  but none points back at its own URL. Every page in an hreflang set must
  self-reference or the whole set may be disregarded.
- `HREFLANG_NON_RECIPROCAL` — A links to B as an alternate but B does not link
  back to A. Return links are mandatory; a one-way annotation is ignored.
  **Corpus-boundary policy:** reciprocity is only judged when B is a URL the
  sitemap also submits (an *internal* node). When B lies OUTSIDE the audited
  corpus (an *external* alternate — another host or another sitemap), the
  sitemap cannot state B's return links, so reciprocity is *unknown* and the
  edge is EXCLUDED rather than flagged (no false positive). Self-reference and
  language-consistency read only the corpus's own declarations, so they still
  apply to external targets.
- `HREFLANG_INCONSISTENT_LANGUAGE` — the same target URL is annotated with two
  or more conflicting language tokens across the corpus. Comparison is
  case-insensitive (BCP 47), so a pure casing difference is left to
  `HREFLANG_NONSTANDARD_CASE`, not treated as a language conflict.

### Classification / unsupported input codes
- `UNSUPPORTED_ROOT` — root element is neither `urlset` nor `sitemapindex`
- `UNSUPPORTED_HTML_MASQUERADE` — document looks like HTML at the URL that
  was expected to serve a sitemap
- `UNSUPPORTED_FEED` — sitemap index child points at a feed in an unrecognised
  dialect (a `<feed>` in a non-Atom namespace); supported feeds (RSS 2.0 /
  Atom 0.3/1.0) are parsed into rows instead

### Decompression codes
Emitted under `layer = "decompression"` by `validate_sitemap()` when it inflates
a gzip stream or extracts a bounded local `.tar.gz` archive. The parse API
(`read_sitemap()`) surfaces the same events as classed conditions instead
(architecture.md §3); Layer F promotes them to findings.
- `UNSUPPORTED_MALFORMED_GZIP` — gzip stream is corrupt or truncated (`error`,
  `subject_type = source`)
- `UNSUPPORTED_MALFORMED_ARCHIVE` — tar.gz extraction failed on a truncated /
  garbage tar (`error`, `subject_type = archive-member`)
- `DECOMPRESS_TOO_MANY_FILES` — the archive exceeds the 100-file cap (ADR-003;
  `error`, `subject_type = source`)
- `DECOMPRESS_NOT_SITEMAP` — an archive member is not a parseable sitemap and was
  skipped, one per member (`info`, `subject_type = archive-member`)

### Encoding codes (`ENCODING_*`)
Emitted under `layer = "classification"`.
- `ENCODING_BOM_DECLARATION_CONFLICT` — BOM and XML declaration disagree;
  `info` → `warning` in strict
- `ENCODING_CONFLICT` — HTTP charset, BOM, and XML declaration are
  inconsistent; `info`

### Index expansion codes (`INDEX_*`)
- `SITEMAP_INDEX_NESTED` — a `sitemapindex` appears as a child of another
  `sitemapindex` (non-conformant; still expanded with a `warning`)
- `INDEX_CYCLE_DETECTED` — a child URL creates a cycle (self-ref, A→B→A, etc.)
- `INDEX_DEPTH_EXCEEDED` — recursion depth exceeded the configured limit (3)
- `INDEX_CHILD_COUNT_EXCEEDED` — child count cap reached

### Robots codes (`ROBOTS_*`)
Emitted under `layer = "robots"` (`subject_type = "page-url"`) by the opt-in
robots allow/disallow check (`validate_sitemap(check_robots = TRUE)`). The check
tests every absolute http(s) `<loc>` a sitemap advertises against its governing
robots.txt, using the sibling `robotstxtr` package (its faithful Google matcher
and HTTP-status→policy semantics). Each distinct origin's robots.txt is fetched
once under the SSRF-guarded fetch policy; matching is offline, so all advertised
URLs are checked with no sampling. An allowed URL produces no row.
- `ROBOTS_DISALLOWED` — a sitemap-listed URL is disallowed by robots.txt
  (`warning`). Evidence carries the matched rule: `type: value` in `excerpt`
  (e.g. `disallow: /private`) and the one-based robots.txt line in `line`.
  Advertising a URL that robots.txt blocks is a well-known SEO defect.
- `ROBOTS_INDETERMINATE` — robots.txt could not be fetched or evaluated (a
  5xx/timeout/network/TLS failure or an SSRF block), so the decision is
  undetermined (`info`). A 404/410 robots.txt is allow-all and produces no row.

`robotstxtr` is an optional dependency (`Suggests`); when it is not installed
and `check_robots = TRUE`, `validate_sitemap()` signals a classed warning
(`sitemapr_robots_unavailable`) naming the install command rather than emitting
a finding — the findings table describes the sitemap, not the user's setup.

---

## Cross-implementation alignment

sitemapr and its TypeScript sibling `sitemap-validator` are two implementations
of one spec. `findings-registry.csv` is the shared source of truth that keeps
their finding codes comparable. **sitemapr's names are canonical**; the
validator aligns to them (see the tracking issues in each repo). The
`validator_code` column records the validator's *current* spelling so the
alignment is mechanical.

### Naming conventions (canonical)
- **Protocol semantic codes** use the `PROTOCOL_` prefix (not the validator's
  abbreviated `PROTO_`).
- **Encoding codes** use `ENCODING_` and the `classification` layer (not
  `PROTO_*` at the protocol layer).
- **Unsupported/unclassifiable content** uses the `UNSUPPORTED_*` prefix (not
  the validator's `CLASSIFY_*`).
- **Nested-index** is `SITEMAP_INDEX_NESTED` and **unsupported root** is
  `UNSUPPORTED_ROOT` — both match the SPEC prose, which the validator's
  implementation (`INDEX_NESTED_INDEX`, `CLASSIFY_UNSUPPORTED_ROOT`) had drifted
  from.
- Subject types use sitemapr's vocabulary. The validator's `job` subject maps to
  `report`; its `sitemap`/`sitemap-index` map to `document`/`index-child`;
  `url-entry` → `entry`; `text-line` → `entry` (with a `#line:` ref);
  `archive-entry` → `archive-member`.

### Row status semantics (`status` column)
- `active` — emitted by the sitemapr pipeline today (57 codes). Two of them —
  the `ROBOTS_*` codes — fire only on an opt-in `check_robots = TRUE` call.
- `reserved` — canonical and documented, but surfaced as a condition rather than
  a findings row in v1 (the two `FETCH_*` codes).
- `deferred-v0.2` — belongs to the `page` Layer E inspection epic (the `PAGE_*`
  codes); defined so the two catalogs stay aligned, not yet emitted.
- `validator-only` — exists in `sitemap-validator` with no sitemapr equivalent
  yet; carried so the contract is complete and to guide future adoption.

---

## Open reconciliation items

- **`ROBOTS_INDETERMINATE`** ↔ validator `ROBOTS_FETCH_FAILED` (best-match).
  sitemapr collapses the two "cannot decide" outcomes into ONE `info` code:
  robots.txt would not fetch (a 5xx/timeout/network/TLS failure or an SSRF
  block). The sibling validator currently splits this across two codes,
  `ROBOTS_FETCH_FAILED` (fetch failed) and `ROBOTS_NOT_TESTABLE`, both carried
  here as `validator-only` rows. Per the "sitemapr names canonical" rule the
  validator adopts `ROBOTS_INDETERMINATE`, collapsing its two codes; until it
  does, this row stays `reconcile = open`. `ROBOTS_DISALLOWED` reconciles
  cleanly (both ports share the name).

### Resolved reconciliations

- **`UNSUPPORTED_MALFORMED_GZIP` / `UNSUPPORTED_MALFORMED_ARCHIVE`** (two rows)
  ↔ validator `DECOMPRESS_FAILED` (plus `DECOMPRESS_TOO_MANY_FILES`,
  `DECOMPRESS_NOT_SITEMAP`). **Resolved → sitemapr keeps its container
  distinction on the `UNSUPPORTED_` axis and adopts the validator's failure-mode
  codes on the `DECOMPRESS_` axis (net superset, no specificity dropped).** The
  decompression layer is now implemented (gzip inflation + bounded `.tar.gz`
  extraction with the 200 MB-decompressed / 100-file ADR-003 guards), and
  `validate_sitemap()` promotes each failure mode to an active finding: a
  malformed gzip stream → `UNSUPPORTED_MALFORMED_GZIP` (the container
  distinction sitemapr keeps over the validator's single `DECOMPRESS_FAILED`), a
  malformed tar → `UNSUPPORTED_MALFORMED_ARCHIVE`, the 100-file cap →
  `DECOMPRESS_TOO_MANY_FILES`, and a non-sitemap archive member →
  `DECOMPRESS_NOT_SITEMAP`. sitemapr thus emits a superset of the validator's
  `DECOMPRESS_*` failure modes while retaining the gzip-vs-archive container
  distinction the validator collapses. The 200 MB / 50 MB byte-ceiling guards
  stay classed conditions and reconcile separately via
  `FETCH_BODY_CEILING_EXCEEDED` (see below); `DECOMPRESS_TOO_LARGE` is *not* in
  this set. The `reconcile` flag is cleared on both rows.

- **`ENCODING_BOM_DECLARATION_CONFLICT`** ↔ validator `PROTO_ENCODING_CONFLICT`
  (was: mis-paired to validator `PROTO_ENCODING_CONFLICT_STRICT`; model
  mismatch). **Resolved → sitemapr's model wins.** Both ports detect the same
  BOM-vs-XML-declaration conflict, but model it differently: sitemapr emits one
  code at `info` and *elevates its severity* to `warning` in strict
  (`findings_strict_elevations`); the validator emits *two different codes* for
  the same conflict — `PROTO_ENCODING_CONFLICT` (non-strict, `info`) and
  `PROTO_ENCODING_CONFLICT_STRICT` (strict, `warning`). sitemapr's model is
  cleaner on two axes: severity is a mode elevation on one code rather than a
  second code, and the conflict *type* is distinguished
  (`ENCODING_BOM_DECLARATION_CONFLICT` for BOM/declaration vs `ENCODING_CONFLICT`
  for HTTP-charset), which the validator overloads into a single
  `PROTO_ENCODING_CONFLICT`. Resolution: the validator drops
  `PROTO_ENCODING_CONFLICT_STRICT` and elevates the severity of
  `PROTO_ENCODING_CONFLICT` in strict instead (SMV-pkxdhqvq); no sitemapr change
  (it already works this way). Both sitemapr encoding-conflict codes therefore
  reconcile to `PROTO_ENCODING_CONFLICT` (sitemapr finer on the conflict-type
  axis). The `PROTO_BOM_DETECTED` / `PROTO_ENCODING_NOT_UTF8` extras are separate,
  already-clean concepts (carried as the `ENCODING_BOM_DETECTED` /
  `ENCODING_NOT_UTF8` validator-only rows) and need no reconciliation.
- **`FETCH_BODY_CEILING_EXCEEDED`** ↔ validator `DECOMPRESS_TOO_LARGE` (was:
  mis-paired to validator `FETCH_BODY_TOO_LARGE`). **Resolved → sitemapr name
  wins, `fatal`.** sitemapr's ceiling guards *decompressed/effective* bytes — a
  memory-safety abort against a runaway/decompression-bomb resource (ADR-003) —
  which is the same intent as the validator's `DECOMPRESS_TOO_LARGE`, not its
  `FETCH_BODY_TOO_LARGE` (raw *wire* body, a guard sitemapr deliberately retired
  when it moved to a buffered fetch with a single effective-byte backstop). The
  old alias pointed at the retired wire-body concept and was a silent mis-map.
  The two ports split their size guards on orthogonal axes — sitemapr by *surface*
  (one per-resource ceiling, at the fetch layer) and the validator by *mechanism*
  (`FETCH_BODY_TOO_LARGE` wire + `DECOMPRESS_TOO_LARGE` decompressed) — so this is
  a best-match pairing, not an identity: `FETCH_BODY_TOO_LARGE` has no sitemapr
  equivalent and is now carried `validator-only`. sitemapr keeps `fatal` (its
  convention for a source-level abort → partial result) and the fetch layer.
- **`SCHEMA_UNKNOWN_NAMESPACE`** ↔ validator `PROTO_UNSUPPORTED_NAMESPACE` (was:
  mis-paired to validator `SCHEMA_NAMESPACE_MISSING`; severity `error` vs
  `warning`). **Resolved → sitemapr name/layer win, `warning`.** sitemapr's code
  fires once per *unrecognized namespace present* in the document — the same
  event as the validator's `PROTO_UNSUPPORTED_NAMESPACE`, not the validator's
  `SCHEMA_NAMESPACE_MISSING` (which flags a *required* namespace being *absent*).
  The old alias conflated "unknown ns present" with "required ns missing" and was
  a silent mis-mapping. Severity lands on `warning`: the sitemaps protocol is
  extensible, so an uncatalogued namespace is content sitemapr could not validate
  and a search engine may ignore — advisory, not a conformance failure (parallel
  to the `HREFLANG_NONSTANDARD_CASE` reasoning). sitemapr keeps the code in the
  **schema** layer (the catalog is a schema concern); the validator renames
  `PROTO_UNSUPPORTED_NAMESPACE → SCHEMA_UNKNOWN_NAMESPACE` and moves it
  protocol → schema (SMV-pkxdhqvq). The validator's `SCHEMA_NAMESPACE_MISSING`
  (required-namespace-absent, surfaced from XSD errors) has no distinct sitemapr
  code — that condition folds into sitemapr's generic `SCHEMA_INVALID` (see the
  `missing-namespace.xml` golden row) — so it is now carried as a `validator-only`
  registry row.
- **`INDEX_CHILD_COUNT_EXCEEDED`** ↔ validator `INDEX_CHILD_LIMIT` (was: severity
  + granularity mismatch). **Resolved → sitemapr name wins, `error`.** Both codes
  fire on the *same* event — the index child cap is reached and remaining children
  are dropped/skipped from expansion — so they are a clean 1:1 pairing. Dropping
  children silently loses coverage, so `error` (not the validator's `warning`) is
  correct; the validator renames `INDEX_CHILD_LIMIT → INDEX_CHILD_COUNT_EXCEEDED`
  and bumps `warning → error`. The validator's other two child-cap codes are
  *distinct concepts*, not finer spellings of this one, and stay validator-only:
  `INDEX_TOO_MANY_CHILDREN` is a soft advisory (index references >1,000 children
  per Google's old guideline, nothing dropped) and `INDEX_TOO_MANY_INDEXES` is a
  job-level advisory (site has many index files). The `reconcile` flag is cleared;
  `INDEX_TOO_MANY_CHILDREN` is now carried as a `validator-only` registry row.
- **`HREFLANG_NONSTANDARD_CASE`** (was: sitemapr `warning` vs validator `info`).
  **Resolved → `info`** on both sides. BCP 47 (RFC 5646 §2.1.1) treats language
  tags as case-insensitive, so an off-case tag (`en-us`) is a fully valid,
  engine-honored tag — a deviation from the RECOMMENDED canonical form, not a
  conformance failure. `warning` over-stated it; `info` is the standards-faithful
  severity. sitemapr downgraded `warning → info`; the `reconcile` flag is
  cleared.

Codes that fold cleanly (documented here, no `reconcile` flag needed): the
validator's `HREFLANG_SCHEMA_INVALID` folds into sitemapr's `SCHEMA_INVALID`
(sitemapr routes hreflang structural failures through the generic schema code);
the validator's `PROTO_TEXT_SCHEME_INVALID` folds into `PROTOCOL_URL_NOT_ABSOLUTE`
(sitemapr reuses the loc codes for text sitemaps).

---

## Determinism guarantee

The same input, same schema-catalog version, and same mode must produce an
identical finding set across repeated calls. This is asserted in the test
suite by running each fixture through the pipeline twice and diffing the
result (SPEC §29.3).

Code ordering within the findings tibble is: `layer` order (per the layer
vocabulary above), then `severity` descending (`fatal` first), then
`subject_ref` lexicographically, then `code`. This ordering is stable and
part of the contract.
