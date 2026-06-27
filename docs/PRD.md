# sitemapr — Product Requirements Document (initial draft)

Status: Draft v0.1
Date: 2026-06-27
Owner: Bart Turczyński
Package: `sitemapr` (CRAN name verified free; `bart-turczynski/sitemapr` GitHub namespace free)

---

## 1. Motivation

### 1.1 The gap
The original question was: *what R library has no alternative but is popular in
other languages?* After surveying candidates and ruling out gaps that R already
fills (Shiny, `pointblank`, `httr2`, `polars`, `charlatan`, `jqr`, `cronR`) or
that have just been closed authoritatively, **sitemap parsing + validation**
emerged as the strongest real, defensible opening.

Candidates rejected during the survey:
- **OpenTelemetry** — gap is closed. r-lib ships `otel` (v0.2.0, May 2026) +
  `otelsdk` on CRAN. Competing with Posit's own team is a losing bet.
- **Pydantic-style validation** — viable but ambitious and easy for a
  well-resourced team to fill; weaker moat.

### 1.2 Why sitemaps, why now
- **No CRAN-grade R package exists.** The only prior art, `xsitemap`
  (pixgarden/fljoly), is GitHub-only, still versioned `0.0.0.9000`, and its
  real code is untouched since **August 2022**. It is effectively abandoned.
- **`xsitemap` is shallow and buggy:** built on legacy `XML` + `httr` +
  `urltools`; extracts only `loc` + `lastmod` (no `changefreq`/`priority`, no
  image/news/video/hreflang extensions); no gzip; an off-by-one bug drops the
  last URL; loses `user_agent` on recursion; bails on indexes ≥50,001 entries;
  network-only tests that would fail `R CMD check`.
- **The Python reference (`ultimate-sitemap-parser` / `usp`) is popular** and
  already in active use here (the local `~/Projects/sitemap-parser` skill wraps
  it). It parses but does **not validate**.
- **A full reference design already exists in-house:** `bart-turczynski/
  sitemap-validator` (March 2026) — a complete, normatively-specced TS/Next.js
  validator. Its `schemas/` and `fixtures/` are language-agnostic and reusable.

### 1.3 The wedge
A **CRAN-published, parser-grade + validator-grade** R library that:
1. parses sitemaps and sitemap indexes (discovery, recursion, gzip, text/XML)
   into a tidy structure with extension data preserved; and
2. **validates** them — both XSD schema conformance (incl. mixed multi-namespace
   documents) and the protocol/semantic rules XSD cannot express.

Differentiation that is hard to copy: the validation layer, the multi-namespace
schema composition, and URL handling built on the existing `rurl` / `pslr` /
`punycoder` ecosystem.

---

## 2. Scope

This is a **library**, not the web app. Port the deterministic engine from
`sitemap-validator`; leave the product infrastructure behind.

### In scope (v0.1)
- Discovery: from a bare domain (robots.txt → common-path guessing), a direct
  sitemap URL, or a local file.
- Parsing: XML `urlset`, XML `sitemapindex` (recursive), text sitemaps, gzip
  (`.xml.gz`); per-file, memory-bounded.
- Extraction into a tidy tibble: `loc`, `lastmod` (POSIXct), `changefreq`,
  `priority`, plus extension data (`images`, `video`, `news`, `alternates`/
  hreflang) as list-columns; `source_sitemap` provenance.
- Structure introspection: index tree (depth, sitemap_url, page_count, gzip).
- Validation:
  - **Layer C (schema):** real XSD validation against bundled local profiles;
    prebuilt profiles for core, core+image, core+news, core+video,
    core+hreflang, sitemapindex; **runtime-generated profiles** for arbitrary
    mixed namespace combinations.
  - **Layer D (protocol/semantic):** per-file limits (≤50,000 URLs, ≤50 MB
    uncompressed), `priority` ∈ [0.0, 1.0], `changefreq` enum, W3C-datetime
    `lastmod`, URL host/path scoping (via `rurl`/`pslr`/`punycoder`),
    hreflang/BCP-47, encoding/escaping, image ≤1000/page, video field rules.
  - strict (default) and non-strict modes.
- Findings model: tidy tibble keyed on the layer model — `layer`, `severity`,
  `rule` (code), `location`, `evidence`, `mode`.

### Out of scope (not a library concern)
Report pages, database, queue/worker, object storage, sampling-by-default,
public submission API, and **both Java services** (schema validator + robots
microservice). v0.2's per-URL page inspection (HTTP status, canonical, robots
meta, X-Robots-Tag, page-level hreflang) is deferred.

---

## 3. Key technical findings (validated empirically)

All confirmed with R `xml2` 1.6.0 (libxml2) during design:

1. **R does XSD validation natively, in-process.** `xml2::xml_validate(doc,
   schema)` performs real XSD validation — no JVM, no subprocess, no JDK. The
   composed `core + import(extension)` profile validates from disk.
2. **The Java backend in `sitemap-validator` is a Node deficiency workaround,
   not an XSD requirement.** It depends on `xsd-schema-validator@^0.11.0`, whose
   README states plainly: *"a (XSD) schema validator for NodeJS that uses Java
   to perform the actual validation… Because Java can do schema validation and
   NodeJS cannot."* It needs `javac`+`java` on PATH (a full JDK) and compiles a
   helper at runtime. It delegates to the JDK's JAXP/**Xerces** validator —
   which is itself **XSD 1.0**, not Saxon. (The ROADMAP's "Java/Saxon" label
   overstates it.) R's libxml2 is at functional parity for these schemas.
3. **libxml2's only real XSD limitation is irrelevant here.** It is XSD 1.0 only
   (no `xs:assert`/`xs:override`/conditional types). The bundled schema set is
   **pure XSD 1.0** — verified: only elements, sequences, enumerations, one
   pattern, restrictions, attributes, and `xs:import`/`xs:include`. No XSD 1.1,
   no identity constraints. The decision to *not* support XSD 1.1 (and to put
   richer/conditional rules in Layer D instead) is recorded in
   `docs/decisions/ADR-001-no-xsd-1.1.md`.
4. **Mixed multi-namespace validation works completely.** `sitemap-core.xsd`
   gates extensions via `<xs:any namespace="##other" processContents="strict">`.
   A runtime-generated wrapper importing image+news+video+hreflang validated a
   document using all four simultaneously (`TRUE`); a broken `video` element
   was caught with a precise namespace-qualified error; an extension whose
   namespace was *not* imported failed ("demanded by the strict wildcard"),
   proving strict deep-validation, not lax skipping. Both `urlset` and
   `sitemapindex` validate and reject correctly.
5. **XXE-safe by default.** `read_xml()` does not expand external entities
   unless `NOENT`/`DTDLOAD` are explicitly passed (probed: default → empty;
   opt-in → canary leaked). Satisfies the SPEC §14.5 XXE mandate for free —
   rule: never pass those options.

### Consequent implementation constraints
- **`schemaLocation` resolves relative to a real file path.** Bundled schemas
  live in `inst/schemas/`; profiles are loaded by path. Runtime-generated
  wrappers must be written to a real file (e.g. session temp dir alongside the
  bundled schemas, or with absolute `schemaLocation`) before validation, then
  cached keyed on (catalog version, root kind, sorted namespace set) — mirrors
  `sitemap-validator` SPEC §16.4–16.5.
- **DOM-based validation → memory.** `xml_validate` parses the whole document;
  the `sitemap-validator` app already hit OOM on BBC's 5.9M-URL set. Adopt
  **per-file discipline from day one** (each file is spec-capped at 50k URLs /
  50 MB); never materialize the expanded tree; stream/chunk protocol counts on
  large files. This is the one engineering risk that carries over from the TS app.

---

## 4. Proposed API (sketch)

```r
# Parse — discover from homepage, recurse indexes, return one tidy tibble
read_sitemap("example.com")                       # bare domain ok
read_sitemap("https://example.com/sitemap_index.xml", discover = FALSE)
#> cols: loc, lastmod <POSIXct>, changefreq, priority,
#>       images <list>, video <list>, news <list>, alternates <list>,
#>       source_sitemap

# Structure introspection
sitemap_tree("example.com")                       # depth, sitemap_url, page_count, gzip

# Validate — schema (Layer C) + protocol/semantic (Layer D)
validate_sitemap("example.com", mode = c("strict", "lax"))
#> tibble: layer, severity, rule, location, evidence, mode
```

Filtering (include/exclude/recent) is intentionally **not** bespoke args — with
`lastmod` as real POSIXct, users filter with dplyr. Extension data stays as
structured list-columns rather than `|`-joined strings.

---

## 5. Dependencies
- `xml2` — parsing + native XSD validation (libxml2).
- `httr2` — fetching (gzip, redirects, user-agent).
- `spiderbar` (Google's robots parser, Rust) or `robotstxt` — robots.txt;
  replaces the Java robots microservice.
- `rurl` / `pslr` / `punycoder` — URL normalization, scoping, and validation
  (the moat; replaces `urltools`).
- base R: `gzfile()`, `untar()` for decompression/archives.

No system Java, no `JAVA_HOME`, no subprocess — a major CRAN portability win.

---

## 6. Reusable assets from `sitemap-validator`
- **`schemas/`** → `inst/schemas/` (core, index, core-{image,news,video,
  hreflang}, standalone extensions). Language-agnostic; drop in as-is.
- **`fixtures/`** → `testthat` corpus (hreflang edge cases, encoding, compressed,
  XML valid/invalid). Enables offline, CRAN-safe tests.
- **SPEC.md layer model (A–F)** → findings schema + rule-code taxonomy
  (`LAYER_SPECIFIC_ISSUE`, e.g. `SCHEMA_INVALID`, `PROTO_DUPLICATE_LOC`,
  `HREFLANG_*`).
- **SPEC §16 mixed-schema model** → runtime profile generation + caching design.

---

## 7. Milestones (proposed)
1. **M0 — scaffold + metadata.** Fill DESCRIPTION (Title/Description/Authors),
   add real deps, replace `R/scaffold.R` and cucumber stub. Seed `inst/schemas/`
   and `tests/testthat/fixtures/`.
2. **M1 — parser.** `read_sitemap()` + `sitemap_tree()`: discovery, recursion,
   gzip/text/XML, tidy tibble with extension list-columns, per-file memory
   discipline. Offline fixture tests.
3. **M2 — schema validator (Layer C).** Bundled profiles + runtime-generated
   mixed profiles + cache; XXE-safe parse options; findings tibble. Multi-
   namespace fixture exercising the strict-wildcard composition.
4. **M3 — protocol validator (Layer D).** Counts/limits, field rules, URL
   scoping via the URL stack, hreflang/BCP-47, encoding.
5. **M4 — docs + CRAN prep.** README, vignette, `cran-comments`, `R CMD check`
   clean, examples.
6. **(later) v0.2 — page inspection.** Deferred per SPEC scope split.

---

## 8. Open decisions
- Name: **resolved → `sitemapr`** (CRAN-free, your-namespace-free; unrelated
  non-R `sitemapr` repos exist in other GitHub namespaces — acceptable noise).
- Whether to depend on `spiderbar` vs `robotstxt` for discovery (lean
  `spiderbar`: Google's actual parser).
- Generated-profile cache location (session temp vs `inst/` build-time
  pre-generation of common combos).
- How rich to make non-strict mode's partial findings.
```
