# sitemapr — Product Requirements Document

Status: Draft v0.2
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

Section references like §8 point at the upstream `sitemap-validator` SPEC.

**Inputs & normalization (§8).** Accept a sitemap URL, a site/root URL, a
robots.txt URL, a local file (XML/text/`.gz`/`.tar.gz`), or a vector of sitemap
URLs. Every input is normalized through the `rurl` stack — default scheme to
`https://`, lowercase scheme/host, strip default ports, resolve `.`/`..`, keep
query/fragment, reduce a site URL to its origin, rewrite a robots input to
`…/robots.txt` — and both the original and normalized values are retained.

**Discovery (§10).** From a site/robots input: robots.txt `Sitemap:` directives
→ generic guessed paths → CMS guessed paths → dedup. The guess catalog is a
fixed, data-driven list, not open-ended. Output distinguishes accepted vs
rejected candidates with reasons (a 404 guess is rejected `not-found`, **not** a
finding), exposed via a `sources` attribute and `sitemap_tree()`.

**Fetch & safety.**
- Limits (§28 defaults, configurable via args/`options()`, never hardcoded):
  30 s timeout, ≤5 redirects, ≤25 candidates, ≤50,000 children, ≤50 MB on-wire.
- `httr2` retry-with-backoff + throttling; default UA
  `sitemapr/<version> (+<contact-url>)`.
- A mid-stream timeout discards the partial body and never parses a truncated
  document (§11.5).
- **SSRF guard** on every user-supplied and post-redirect URL (§11.2): reject
  loopback/RFC-1918/link-local/cloud-metadata/unspecified, IPv4-mapped-IPv6, and
  octal literals, plus non-HTTP(S). Structural only — no DNS resolution, so
  DNS-rebinding is out of scope (see §9 decision).
- Classification is **byte-level** (§11.4): content decides format, not the
  extension or `Content-Type`.
- Per-source **fetch metadata** (§11.1: requested/final URL, status, redirect
  chain, content-type, charset, bytes, timing, error class, format, root,
  namespaces, profile ID) rides on the `sources` attribute.

**Errors — parse vs validate.** Parse APIs (`read_sitemap()`/`sitemap_tree()`)
signal classed conditions: an entry-point fetch failure is an error; a child
`4xx`/`5xx` is a warning, skipped, and logged in a `problems` attribute (partial
parse still succeeds); a missing robots.txt is non-fatal. Only
`validate_sitemap()` emits findings — the parse APIs never do.

**Parsing (§9, §20).**
- Formats: XML `urlset`/`sitemapindex` (recursive), text, gzip
  (`.xml.gz`/`.txt.gz`), and — local files only — `.tar.gz`. Per-file,
  memory-bounded.
- Archive extraction is bounded (§11.3: ≤50 MB archive, ≤100 files, ≤200 MB
  decompressed) and safe: skip dirs/special entries, reject path-traversal, skip
  non-sitemap files (with an `info`), support inner `.gz`, type empty/malformed
  tars.
- Index recursion deduplicates children, detects cycles (self-ref, repeated
  child, A→B→A), enforces a max depth (3) and the count caps, and preserves the
  parent→child chain. A `sitemapindex` nested in a `sitemapindex` is
  non-conformant (`SITEMAP_INDEX_NESTED` warning) but still expanded.

**Output.**
- `read_sitemap()` → tidy tibble: `loc`, `lastmod` (POSIXct), `changefreq`,
  `priority`, extension data (`images`/`video`/`news`/`alternates`) as
  list-columns, and `source_sitemap` provenance (§8.3 values:
  `submitted-directly`/`submitted-list`/`discovered-robots`/`guessed-path`/
  `child-of-index`/`extracted-archive`).
- `sitemap_tree()` → index structure (depth, sitemap_url, page_count, gzip).

**Validation — layer model (§6).** A–F: **A** source access, **B** format
classification, **C** XSD schema, **D** protocol/semantic, **E** per-URL page
inspection (v0.2), **F** reporting (assembly of findings, not a pass). v0.1's
validation layers are **C and D**; A/B happen during fetch/parse and F is the
findings tibble.
- **Layer C (schema):** real XSD validation against bundled profiles (core,
  core+{image,news,video,hreflang}, sitemapindex) plus **runtime-generated
  profiles** for arbitrary mixed-namespace combinations.
- **Layer D (protocol/semantic):**
  - Limits & fields: ≤50,000 URLs / ≤50 MB uncompressed, duplicate-`loc`,
    `priority` ∈ [0.0, 1.0], `changefreq` enum, W3C-datetime `lastmod` (date-only
    valid; `info` in strict), invalid-escaping, image ≤1000/page, video field
    rules; URL scoping via `rurl`/`pslr`/`punycoder`.
  - **hreflang (§17):** a sitemap-specific token policy, *not* BCP-47/
    `xs:language` — a custom XSD pattern (`lang`, `lang-REGION`, `lang-Script`,
    `lang-Script-REGION`, `x-default`) plus a semantic layer (separators,
    whitespace, casing reported-but-preserved, intra-entry duplicates/conflicts,
    `x-default`). Cross-URL reciprocity is v0.2; no IANA snapshot shipped. Typed
    `HREFLANG_*` codes.
  - **Encoding (§11.6):** BOM → XML declaration → HTTP charset → UTF-8; conflicts
    emit `info` (a BOM↔declaration clash is `warning` in strict).
  - **Text sitemaps (§18):** dedicated path, `\n`/`\r\n`/`\r` splitting, URL
    ≤2048 chars, scheme ∈ {http, https}, host present, per-line errors; blank
    lines silent in non-strict, `info` (with line number) in strict.
  - **Unsupported inputs → typed findings** (§9.5, §13.1): HTML-masquerade,
    `UNSUPPORTED_ROOT`, unknown namespace, malformed gzip/archive.

**Modes (§14.2): `strict` (default) / `non-strict`** — a failure-behavior
switch, not a rule filter. `strict` fails on schema violations; `non-strict`
does a best-effort parse when XSD fails but still reports the violations and runs
safe protocol checks. Independently, some rules are strict-only (date-only
`lastmod`, blank-line, relative hreflang `href`) and don't fire under
`non-strict`.

**Findings model (§21).** Tidy tibble — `code`, `severity`
(`fatal`/`error`/`warning`/`info`), `layer` (`input`/`fetch`/`discovery`/
`classification`/`decompression`/`schema`/`protocol`/`index-expansion`/`report`),
`subject_type` + `subject_ref` (stable ref, e.g. `…#entry:42`), `message`,
`evidence`, `mode`, `is_strict_only`, optional `remediation_hint`. `evidence` is
a normalized snippet (never raw output): `excerpt` ≤500 chars (≤200 for text
lines) + `line`/`column`. The `mode`/`is_strict_only` split is the SPEC's own
model and resolves the earlier ambiguity.

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
  live in `inst/schemas/` (read-only once installed — **never written to at
  runtime**). Runtime-generated wrappers are written to `tempdir()` and reference
  the bundled schemas by **absolute** path (`system.file("schemas", …)`), never
  by a relative path into the installed tree. Wrappers are cached keyed on
  (catalog version, root kind, sorted namespace set) — mirrors `sitemap-validator`
  SPEC §16.4–16.5. Common combinations may instead be pre-generated at build time
  into `inst/` (that write happens before install, so it is allowed).
- **DOM-based validation → memory.** `xml_validate` parses the whole document;
  the `sitemap-validator` app already hit OOM on BBC's 5.9M-URL set. Adopt
  **per-file discipline from day one** (each file is spec-capped at 50k URLs /
  50 MB); never materialize the expanded tree; stream/chunk protocol counts on
  large files. Note this bounds but does not eliminate Layer C's footprint: a
  single spec-legal 50 MB file must still be DOM-parsed in full for
  `xml_validate`, so per-validation peak memory is ~the 50 MB cap × libxml2's DOM
  overhead. This is the one engineering risk that carries over from the TS app.

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
validate_sitemap("example.com", mode = c("strict", "non-strict"))
#> tibble: code, severity, layer, subject_type, subject_ref,
#>         message, evidence, mode, is_strict_only
```

Filtering (include/exclude/recent) is intentionally **not** bespoke args — with
`lastmod` as real POSIXct, users filter with dplyr. Extension data stays as
structured list-columns rather than `|`-joined strings.

---

## 5. Dependencies
- `xml2` — parsing + native XSD validation (libxml2).
- `httr2` — fetching (gzip, redirects, user-agent).
- robots.txt parsing — **candidate Imports** `spiderbar` (Google's robots parser,
  Rust) *or* `robotstxt`; exactly one will be chosen (decision open in §9). Either
  way it replaces the Java robots microservice.
- `rurl` / `pslr` / `punycoder` — URL normalization, scoping, and validation
  (the moat; replaces `urltools`).
- base R: `gzfile()` / `gzcon()` for gzip, `untar()` for `.tar.gz` local
  archives (bounded extraction — see §2 / SPEC §11.3).

All candidate Imports are already on CRAN (verified 2026-06-27: `rurl` 1.2.0,
`pslr` 1.0.1, `punycoder` 1.1.0, `spiderbar` 0.2.5, `robotstxt` 0.7.15, `xml2`
1.6.0), so nothing gates the CRAN submission once the robots dependency is
picked; record the minimum versions in `DESCRIPTION`.

No system Java, no `JAVA_HOME`, no subprocess — a major CRAN portability win.

---

## 6. Reusable assets from `sitemap-validator`
- **`schemas/`** → `inst/schemas/` (core, index, core-{image,news,video,
  hreflang}, standalone extensions). Language-agnostic; drop in as-is.
- **`fixtures/`** → `testthat` corpus. The SPEC §29.1 corpus is the target
  checklist — beyond hreflang/encoding/compressed/valid-invalid XML it requires
  recursive index loop, nested index, HTML-at-sitemap-URL, mid-stream truncation,
  encoding-conflict (BOM vs declaration vs charset), and `lastmod`/`changefreq`/
  `priority` variants. Enables offline, CRAN-safe tests.
- **SPEC.md layer model (A–F) + finding-layer codes** → findings schema + stable
  rule-code taxonomy (`schema`/`protocol`/`classification`/… layers; codes like
  `UNSUPPORTED_ROOT`, `SITEMAP_INDEX_NESTED`, `HREFLANG_FORMAT_INVALID`). Codes
  are stable across releases (SPEC §21.5); a change is a documented break.
- **SPEC §16 mixed-schema model** → runtime profile generation + caching design.

**Licensing of bundled assets.** Everything copied into `inst/` needs clear
provenance and a CRAN-compatible license. The sitemap.org XSDs carry their own
terms, and the `schemas/`/`fixtures/` come from the TS `sitemap-validator`. Add
an `inst/schemas/LICENSE` (or a provenance note in `inst/COPYRIGHTS` /
`Authors@R` comments) before M4 — left implicit, this is a `R CMD check` /
CRAN-policy blocker.

---

## 7. Milestones (proposed)
1. **M0 — scaffold + metadata.** Fill DESCRIPTION (Title/Description/Authors),
   add real deps **with minimum versions pinned** (all already on CRAN — see §5),
   replace `R/scaffold.R` and cucumber stub. Seed `inst/schemas/` and
   `tests/testthat/fixtures/`, and land their license/provenance file (§6) in the
   same commit as the assets.
2. **M1 — parser.** `read_sitemap()` + `sitemap_tree()`: discovery (SSRF guard +
   byte-level sniffing), recursion with cycle detection / depth cap / dedup,
   gzip/text/XML + `.tar.gz`, tidy tibble with extension list-columns + provenance,
   per-file memory discipline. Offline fixture tests.
3. **M2 — schema validator (Layer C).** Bundled profiles + runtime-generated
   mixed profiles + cache; XXE-safe parse options; findings tibble. Multi-
   namespace fixture exercising the strict-wildcard composition.
4. **M3 — protocol validator (Layer D).** Counts/limits, field rules, URL
   scoping via the URL stack, the §17 hreflang token policy, encoding-conflict
   resolution, text-sitemap rules, and typed unsupported-input findings.
5. **M4 — docs + CRAN prep.** README, vignette, `cran-comments`, `R CMD check`
   clean, examples. No upstream-dependency gate remains (all Imports are on
   CRAN); the only release prerequisites are the asset license (§6) and a clean
   check against the success criteria (§8).
6. **(later) v0.2 — page inspection.** Deferred per SPEC scope split.

---

## 8. Success criteria (definition of done)
Beyond binary CRAN acceptance, v0.1 is "done" when:
- **Parser parity:** `read_sitemap()` extracts the same `loc` set as `usp` on a
  shared fixture corpus, plus the extension list-columns `usp` omits.
- **Validator conformance:** Layer C/D agree with the `sitemap-validator`
  reference on its own valid/invalid fixtures (matching pass/fail + rule codes).
- Both comparisons above run **outside CRAN** — they are an acceptance harness
  (a non-CRAN validation job) whose outputs are frozen into checked-in **golden
  fixtures**. Neither Python `usp` nor the TS validator becomes a package
  test/`Suggests` dependency; the in-tree `testthat` suite asserts only against
  the captured fixtures.
- **Offline + clean:** `R CMD check --as-cran` passes with no network access in
  tests (fixtures only) and no notes beyond timing.
- **Memory bound holds:** a spec-max (50k URL / 50 MB) file validates within the
  documented per-file footprint without OOM.
- **Determinism (SPEC §29.3):** the same input under the same schema-catalog
  version and mode yields an identical finding set — asserted by running each
  fixture through the pipeline twice and comparing.

---

## 9. Open decisions
- Name: **resolved → `sitemapr`** (CRAN-free, your-namespace-free; unrelated
  non-R `sitemapr` repos exist in other GitHub namespaces — acceptable noise).
- Whether to depend on `spiderbar` vs `robotstxt` for discovery (lean
  `spiderbar`: Google's actual parser).
- **SSRF enforcement scope:** does the library itself block private/loopback/
  metadata targets (SPEC §11.2), or document it as the embedding caller's
  responsibility? A library that fetches arbitrary user URLs arguably should ship
  the guard on by default (with an opt-out). Note the reference guard is purely
  **structural** (URL/IP-literal inspection, no DNS resolution), so a hostname
  resolving to a private IP — and DNS-rebinding — is *not* caught; decide whether
  the R port adds resolve-then-check or accepts the same limitation. Decide before
  M1.
- Generated-profile cache: **resolved → `tempdir()` at runtime** (keyed cache),
  with optional build-time pre-generation of common combos into `inst/`. Open
  sub-question: which combos are worth pre-generating.
- How rich to make `non-strict` mode's best-effort partial findings.
