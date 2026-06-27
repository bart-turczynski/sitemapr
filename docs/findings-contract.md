# Findings contract

This document defines `validate_sitemap()`'s output tibble as a
**compatibility contract**. Column names, layer vocabulary, `subject_ref`
format, and finding codes are stable across releases. Adding a new column or
a new code value is a documented addition. Removing or renaming any of the
above is a documented breaking change.

---

## Output tibble columns

| Column | Type | Description |
|---|---|---|
| `code` | `character` | Machine-readable finding code (see §§ below). Stable across releases; changes are breaking. |
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
| `"classification"` | Byte-level format sniffing |
| `"decompression"` | Gzip / archive extraction |
| `"schema"` | XSD Layer C validation |
| `"protocol"` | Protocol/semantic Layer D checks |
| `"index-expansion"` | Sitemap index recursion, cycle detection, depth/count caps |
| `"report"` | Finding assembly, dedup, cross-source aggregation |

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

---

## Strict-vs-non-strict behavior

`mode` and `is_strict_only` together encode the SPEC's failure-behavior model:

- **`mode`** records the mode the call was made in (`"strict"` or
  `"non-strict"`), not whether the rule *is* strict-only.
- **`is_strict_only = TRUE`** means the rule fires only in strict mode; under
  `non-strict`, no row is emitted for this code at all.
- **`is_strict_only = FALSE`** means the rule fires in both modes (though it
  may produce different severities between modes — a schema violation becomes
  `"warning"` in `non-strict` rather than `"error"`/`"fatal"`).

Strict-only codes (v1):
- Date-only `lastmod` (produces `info` in strict, not emitted in non-strict)
- Blank lines in text sitemaps (produces `info` in strict)
- Relative `href` in hreflang entries (produces `warning` in strict)

---

## Finding code taxonomy

Codes are namespaced by layer prefix. The full v1 code set is defined as
implementation proceeds; codes listed here are the **known v1 set** from the
`sitemap-validator` SPEC and PRD.

### Schema codes (`SCHEMA_*`)
- `SCHEMA_INVALID` — document fails XSD validation (Layer C)
- `SCHEMA_UNKNOWN_NAMESPACE` — namespace not recognized and not imported into
  the runtime-generated profile

### Protocol codes (`PROTOCOL_*`)
- `PROTOCOL_URL_COUNT_EXCEEDED` — more than 50 000 URL entries
- `PROTOCOL_DUPLICATE_LOC` — two entries share the same normalized `loc`
- `PROTOCOL_PRIORITY_OUT_OF_RANGE` — `priority` outside `[0.0, 1.0]`
- `PROTOCOL_CHANGEFREQ_INVALID` — `changefreq` not in the enum
- `PROTOCOL_LASTMOD_INVALID` — `lastmod` not a valid W3C Date-Time value
- `PROTOCOL_LASTMOD_DATE_ONLY` — date-only `lastmod`; strict-only `info`
- `PROTOCOL_URL_INVALID_ESCAPE` — invalid percent-encoding in a URL field
- `PROTOCOL_URL_NOT_ABSOLUTE` — `loc` is not an absolute `http`/`https` URL
- `PROTOCOL_URL_NO_HOST` — `loc` has no host component
- `PROTOCOL_URL_OUT_OF_SCOPE` — `loc` does not share scheme+host+port+path
  prefix with its parent sitemap file
- `PROTOCOL_URL_FRAGMENT` — `loc` contains a fragment (`info`)
- `PROTOCOL_URL_USERINFO` — `loc` contains userinfo (`info`)
- `PROTOCOL_IMAGE_COUNT_EXCEEDED` — more than 1 000 images per page entry
- `PROTOCOL_VIDEO_FIELD_INVALID` — video extension field fails protocol rules
- `PROTOCOL_NEWS_FIELD_INVALID` — news extension field fails protocol rules
- `PROTOCOL_TEXT_URL_TOO_LONG` — text sitemap URL exceeds 2 048 chars
- `PROTOCOL_TEXT_BLANK_LINE` — blank line in text sitemap; strict-only `info`

### Hreflang codes (`HREFLANG_*`)
- `HREFLANG_FORMAT_INVALID` — lang tag does not match the sitemap-specific
  token pattern (`lang`, `lang-REGION`, `lang-Script`, `lang-Script-REGION`,
  `x-default`)
- `HREFLANG_SEPARATOR_INVALID` — separator in lang tag is not a hyphen
- `HREFLANG_DUPLICATE` — two `xhtml:link` entries in one `<url>` share the
  same hreflang value
- `HREFLANG_XDEFAULT_MISSING` — `x-default` absent when other hreflang
  entries are present
- `HREFLANG_HREF_RELATIVE` — `href` is relative; strict-only

### Classification / unsupported input codes
- `UNSUPPORTED_ROOT` — root element is neither `urlset` nor `sitemapindex`
- `UNSUPPORTED_HTML_MASQUERADE` — document looks like HTML at the URL that
  was expected to serve a sitemap
- `UNSUPPORTED_FEED` — sitemap index child points at an RSS/Atom feed URL
  (out of scope for v1)
- `UNSUPPORTED_MALFORMED_GZIP` — gzip stream is corrupt or truncated
- `UNSUPPORTED_MALFORMED_ARCHIVE` — tar.gz extraction failed

### Index expansion codes (`INDEX_*`)
- `SITEMAP_INDEX_NESTED` — a `sitemapindex` appears as a child of another
  `sitemapindex` (non-conformant; still expanded with a `warning`)
- `INDEX_CYCLE_DETECTED` — a child URL creates a cycle (self-ref, A→B→A, etc.)
- `INDEX_DEPTH_EXCEEDED` — recursion depth exceeded the configured limit (3)
- `INDEX_CHILD_COUNT_EXCEEDED` — child count cap reached

### Encoding codes (`ENCODING_*`)
- `ENCODING_BOM_DECLARATION_CONFLICT` — BOM and XML declaration disagree;
  `warning` in strict
- `ENCODING_CONFLICT` — HTTP charset, BOM, and XML declaration are
  inconsistent; `info`

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
