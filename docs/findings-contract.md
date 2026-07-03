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

`"page"` and `"robots"` are reserved for the v0.2 per-URL inspection epic and
are not emitted by the v1 pipeline. Encoding findings (`ENCODING_*`) are
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

The v0.2 `page`/`robots` layers introduce a `page-url` subject scoped to an
individual crawled page; its `subject_ref` form is defined when Layer E lands.

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
  is downgraded to `warning` in `non-strict`. This keys on the layer, so both
  `SCHEMA_INVALID` and `SCHEMA_UNKNOWN_NAMESPACE` follow it.
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
- `FETCH_BODY_CEILING_EXCEEDED` — the per-resource safety ceiling (default
  500 MB of decompressed/effective bytes) was exceeded; the body is discarded
  and the source returns a partial result. `fatal`. (See ADR-003 §3.) In
  `read_sitemap()` / `sitemap_tree()` the same event surfaces as a classed
  `sitemapr_body_ceiling` condition rather than a findings row.
- `FETCH_TIMEOUT` — the request exceeded the wall-clock timeout (default 30 s);
  no usable body. `fatal`. Surfaces as a `sitemapr_timeout` condition in the
  parse APIs.

Both fetch codes are **reserved**: documented and canonical, but surfaced as
conditions rather than findings rows in the v1 parse APIs.

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

### Classification / unsupported input codes
- `UNSUPPORTED_ROOT` — root element is neither `urlset` nor `sitemapindex`
- `UNSUPPORTED_HTML_MASQUERADE` — document looks like HTML at the URL that
  was expected to serve a sitemap
- `UNSUPPORTED_FEED` — sitemap index child points at an RSS/Atom feed URL
  (out of scope for v1)
- `UNSUPPORTED_MALFORMED_GZIP` — gzip stream is corrupt or truncated (reserved)
- `UNSUPPORTED_MALFORMED_ARCHIVE` — tar.gz extraction failed (reserved)

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
- `active` — emitted by the sitemapr v1 pipeline today (43 codes).
- `reserved` — canonical and documented, but surfaced as a condition rather than
  a findings row in v1 (the two `FETCH_*` codes, `UNSUPPORTED_MALFORMED_*`).
- `deferred-v0.2` — belongs to the `page`/`robots` Layer E inspection epic;
  defined so the two catalogs stay aligned, not emitted in v1.
- `validator-only` — exists in `sitemap-validator` with no sitemapr equivalent
  yet; carried so the contract is complete and to guide future adoption.

---

## Open reconciliation items

Seven rows carry `reconcile = open`, grouped into the six decisions below: the
concept exists on both sides but the mapping is not a clean rename. These are
the decisions the validator-alignment work must settle; until then, do not treat
the two codes as interchangeable.

1. **`SCHEMA_UNKNOWN_NAMESPACE`** ↔ validator `SCHEMA_NAMESPACE_MISSING`
   (schema/error) **and** `PROTO_UNSUPPORTED_NAMESPACE` (protocol/warning). The
   validator splits "required namespace missing" from "unsupported namespace
   present" across two layers; sitemapr has one schema-layer code. Decide
   whether sitemapr adopts the split or the validator collapses to one code.
2. **`INDEX_CHILD_COUNT_EXCEEDED`** ↔ validator `INDEX_CHILD_LIMIT` +
   `INDEX_TOO_MANY_CHILDREN` (+ `INDEX_TOO_MANY_INDEXES`). The validator has
   two/three finer child-cap codes at `warning`; sitemapr has one at `error`.
   Reconcile both the granularity and the severity.
3. **`HREFLANG_NONSTANDARD_CASE`** — sitemapr emits `warning`; the validator
   emits `info`. Same concept, different severity.
4. **`ENCODING_BOM_DECLARATION_CONFLICT`** ↔ validator
   `PROTO_ENCODING_CONFLICT_STRICT`. sitemapr emits `info` in non-strict and
   elevates to `warning` in strict; the validator marks it strict-only
   (suppressed in non-strict). Reconcile the emission model, plus the
   `PROTO_BOM_DETECTED` / `PROTO_ENCODING_NOT_UTF8` extras the validator has.
5. **`UNSUPPORTED_MALFORMED_GZIP` / `UNSUPPORTED_MALFORMED_ARCHIVE`** (two rows)
   ↔ validator `DECOMPRESS_FAILED` (plus `DECOMPRESS_TOO_LARGE`,
   `DECOMPRESS_TOO_MANY_FILES`, `DECOMPRESS_NOT_SITEMAP`). sitemapr reserves two
   coarse codes; the validator has a richer, active `DECOMPRESS_*` family. Since
   sitemapr's are unimplemented, adopting the validator's set is the likely
   resolution — an exception to "sitemapr names win."
6. **`FETCH_BODY_CEILING_EXCEEDED`** ↔ validator `FETCH_BODY_TOO_LARGE`.
   sitemapr's is a 500 MB *decompressed* ceiling (ADR-003); the validator's is a
   fetch-body size limit. Confirm the thresholds describe the same guard before
   treating the codes as equivalent.

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
