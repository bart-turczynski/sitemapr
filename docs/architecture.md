# Architecture

This document captures durable project context, constraints, and design
decisions. See `docs/decisions/` for individual ADRs.

---

## 1. Product position

`sitemapr` is a **library**, not a web application. It ports the deterministic
parsing and validation engine from the TypeScript `sitemap-validator` reference
into a CRAN-publishable R package. All product infrastructure (report pages,
database, queue/worker, object storage, public submission API, Java schema
service) stays out of scope.

---

## 2. Standards baseline

| Standard | Role in `sitemapr` |
|---|---|
| Sitemap Protocol 0.9 (`sitemaps.org`) | Core XML/text/index rules |
| W3C XML 1.0, XML Namespaces, XML Schema 1.0 | XML/schema/date behavior |
| W3C Date-Time profile | `lastmod` values |
| RFC 3986 / RFC 3987 | URI/IRI parsing, normalization, IRI→URI mapping |
| Google image/video/news/hreflang docs | Extension semantics |

WHATWG URL behavior may guide parser edge cases where web reality diverges, but
any conflict with the sitemap.org/RFC baseline is an explicit product decision.

---

## 3. Layer model (A–F)

```
A  source access        fetch + redirect + SSRF guard
B  format classification  byte-level sniff (not Content-Type or extension)
C  XSD schema           xml2::xml_validate against bundled profiles (XSD 1.0)
D  protocol/semantic    R checks for rules XSD cannot express
E  per-URL page         HTTP status, canonical, robots meta  [post-v1]
F  findings assembly    collect, de-dup, sort; not itself a pass/fail
```

v1 implements layers **A, B, C, D, and F**. Layer E is deferred.

Errors produced by A/B (parse APIs) are classed conditions, never findings
tibble rows. Only `validate_sitemap()` populates the findings tibble (F).

---

## 4. v1 vertical slices (module map)

Each slice corresponds to a tracer-bullet issue in the issue tracker.

| Slice | Entry → Exit | Key components |
|---|---|---|
| Input normalization | User call → source records | Entrypoint policy, `rurl`, provenance |
| Discovery | Site root → accepted/rejected candidates | Guess catalog, `httr2`, `sitemap_tree()` |
| Fetch & classification | Source record → classified byte stream | SSRF guard, `httr2`, byte-level sniffer |
| Parse formats | Byte stream → tidy tibble | XML/text/gzip/tar.gz parsers, `xml2` |
| Index expansion | `sitemapindex` → expanded children | Recursion, cycle detection, depth/count caps |
| Schema validation (Layer C) | Parsed doc → schema findings | Bundled XSD profiles, runtime-generated mixed profiles |
| Protocol validation (Layer D) | Parsed doc → protocol findings | Counts, field rules, URL scoping, hreflang policy, encoding |
| Findings assembly (Layer F) | Per-source findings → final tibble | `validate_sitemap()` output contract |

---

## 5. URL-stack contract

`sitemapr` and `rurl` have a clear division of labor:

| Concern | Owner |
|---|---|
| Parse URL into components | `rurl::safe_parse_urls()` |
| IDNA host normalization | `rurl` (via `punycoder`) |
| Path dot-segment / percent-encoding normalization | `rurl` |
| IP-host detection | `rurl` |
| Public suffix / registered domain | `rurl` (via `pslr`) |
| Sitemap entrypoint policy (bare domain → `https://`) | `sitemapr` |
| SSRF guard (range and pattern matching) | `sitemapr` |
| `loc` full-URL identity key (for dedup, scoping) | `sitemapr` (assembled from `rurl` components; not `rurl::clean_url`) |
| Sitemap protocol URL rules (absolute http/https, host present, scoping) | `sitemapr` Layer D |

`rurl::clean_url` is **not** used as the `loc` identity key (or as the fetch
URL): it is a display helper that drops port, query, fragment, and userinfo,
several of which are meaningful for sitemap duplicate detection and fetch URL
assembly. `sitemapr` builds its own canonical form from the `rurl` component
set, and the same string serves as both the fetch target and the identity key
(SITE-vrgszbnu): userinfo, host, path, and **query** are kept (a dynamic
endpoint or a paginated `sitemapindex` child such as `?page=2` is a distinct
resource); the scheme's **default port** (`:80`/`:443`) is collapsed so it is
identity-equivalent to no port; and the **fragment** is dropped, since it is
never sent over HTTP and identifies no separate fetched resource (RFC 3986
§3.5). Tracking-parameter stripping is deliberately not attempted — the server
is the authority for what a query means.

`pslr` and `punycoder` are normally indirect dependencies (through `rurl`).
They are imported directly only if an implementation need arises for raw Public
Suffix List or Punycode/IDNA operations outside a full URL parse.

---

## 6. Schema design (Layer C)

Bundled schemas live in `inst/schemas/` (read-only after install — never written
at runtime). Runtime-generated mixed-namespace wrapper XSDs are written to
`tempdir()` and reference the bundled schemas by **absolute path**
(`system.file("schemas", …, package = "sitemapr")`), never by a relative path
into the installed tree.

Profile cache key: `(catalog_version, root_kind, sorted_namespace_set)`.
Common combinations (core+image, core+news, core+video, core+hreflang,
core+all-four, sitemapindex) may be pre-generated into `inst/schemas/generated/`
at build time.

All schema parsing uses **XSD 1.0** via `xml2::xml_validate()` / libxml2.
XSD 1.1 is explicitly out of scope (ADR-001). Rules that exceed XSD 1.0's
expressive power are implemented in Layer D.

XXE safety: `xml2::read_xml()` does not expand external entities without
`NOENT`/`DTDLOAD`. These options are never passed in `sitemapr` code.

---

## 7. Output contracts

### `read_sitemap()` → tidy tibble

Columns: `loc`, `lastmod` (POSIXct), `changefreq`, `priority`,
`images` (list-column), `video` (list-column), `news` (list-column),
`alternates` (list-column), `source_sitemap`.

This typed tibble is a **projection** for callers, not the input to validation.
The typed/coerced columns (`lastmod` → POSIXct, `priority` → numeric) are lossy
in dimensions some Layer D field rules must inspect, so validation consumes a
faithful, string-preserving parse instead — mirroring Layer C, which validates
the raw doc. See ADR-004.

`source_sitemap` provenance values (v1): `submitted-directly`,
`submitted-list`, `guessed-path`, `child-of-index`, `extracted-archive`.

### `sitemap_tree()` → discovery/index structure

Columns: `depth`, `parent_sitemap`, `sitemap_url`, `page_count`, `gzip`,
`status`, `reason`, `provenance`.

Includes accepted and rejected discovery candidates as well as expanded index
children.

### `validate_sitemap()` → findings tibble

See `docs/findings-contract.md` for the full column contract.

---

## 8. Dependency rationale

| Package | Role | Minimum version |
|---|---|---|
| `xml2` | XML parsing + XSD validation (libxml2) | TBD in M0 |
| `httr2` | Fetching, redirects, retry/backoff, throttling, UA | TBD |
| `rurl` | URL engine (parsing, normalization, IP detection, PSL) | 1.4.0 |
| `pslr` | Public suffix list (normally indirect via `rurl`) | ≥ 1.0.2 |
| `punycoder` | Punycode/IDNA (normally indirect via `rurl`) | ≥ 1.2.0 |
| base R | `gzfile()`/`gzcon()`, `untar()` | — |

No system Java, no `JAVA_HOME`, no subprocess, no `SystemRequirements` beyond
what `xml2` already declares.

---

## 9. Archive safety (local `.tar.gz`)

Extraction limits (configurable):

| Limit | Default |
|---|---|
| Max archive size on-disk | 50 MB |
| Max file count per archive | 100 |
| Max total decompressed size | 200 MB |

Additional rules:
- Skip directories and special entries.
- Reject path-traversal components (e.g., `../`).
- Skip non-sitemap files with an `info`-severity finding.
- Support inner `.gz` within the archive.
- Handle empty or malformed tars with a typed error finding.

---

## 10. CRAN constraints

- All tests run offline; no network calls in `R CMD check`.
- No `SystemRequirements` beyond what `xml2` already declares.
- Bundled assets in `inst/` (schemas, fixtures) carry license/provenance
  files before submission (a `R CMD check` / CRAN-policy blocker without them).
- Memory: per-file discipline; never materialize the full expanded index tree.
  A spec-legal 50 MB file must be DOM-parseable in full for `xml_validate`.
