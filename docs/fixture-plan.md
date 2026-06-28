# v1 Fixture and golden corpus plan

This document defines the fixture strategy for `sitemapr` v1. All `testthat`
tests must run offline and pass `R CMD check --as-cran` without network
access. External parity harnesses (against `usp` and `sitemap-validator`) run
outside CRAN and produce checked-in golden outputs.

---

## 1. Upstream assets to reuse

### 1.1 Schemas → `inst/schemas/`

Source: `bart-turczynski/sitemap-validator` → `schemas/`

Profiles to copy:
- `sitemap-core.xsd` — core urlset
- `sitemap-index.xsd` — sitemapindex
- `sitemap-image.xsd`, `sitemap-news.xsd`, `sitemap-video.xsd`,
  `sitemap-hreflang.xsd` — standalone extensions
- `sitemap-core-image.xsd`, `sitemap-core-news.xsd`, `sitemap-core-video.xsd`,
  `sitemap-core-hreflang.xsd` — pre-composed core+extension profiles

Pre-generate common mixed profiles at build time and include in
`inst/schemas/generated/`:
- `core-image-news-video-hreflang.xsd` (all four extensions)
- Any combination requested by at least two Golden corpus fixtures

**License/provenance requirement (CRAN blocker):** An `inst/schemas/LICENSE`
or a provenance note in `inst/COPYRIGHTS` must ship in the same commit as
the schema files. Bundling without clear provenance is a CRAN policy violation.

### 1.2 Fixtures → `tests/testthat/fixtures/`

Source: `bart-turczynski/sitemap-validator` → `fixtures/`

These are language-agnostic XML/text files. Copy as-is; the R test suite
references them as local paths. Do not add a network call in any test that
could instead use a fixture.

---

## 2. In-tree fixture corpus (CRAN-safe, offline)

Every scenario in this section must have at least one fixture file in
`tests/testthat/fixtures/` and at least one `testthat` test asserting the
expected output or condition.

### 2.1 Standards-baseline scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Minimal valid XML urlset | `valid-minimal.xml` | Parse succeeds; 1 row |
| Maximal field set (all optional fields) | `valid-full-fields.xml` | All columns populated |
| Valid sitemapindex | `valid-index.xml` | Tree with parent→child |
| Text sitemap | `valid-text.txt` | Parse succeeds |
| Gzip-compressed XML | `valid.xml.gz` | Transparent decompression |
| Local `.tar.gz` archive | `valid.tar.gz` | Bounded extraction |

### 2.2 URL and IRI scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Unicode path (IRI → URI mapping) | `url-iri-path.xml` | `loc` decoded then normalized |
| Punycode/IDNA host | `url-idna-host.xml` | Host lowercased, IDNA applied |
| Default port stripped (`:80` / `:443`) | `url-default-port.xml` | Port absent from identity key |
| Full URL duplicate (same loc, different ports) | `url-duplicate-loc.xml` | `PROTOCOL_DUPLICATE_LOC` |
| Fragment in `loc` | `url-fragment.xml` | `PROTOCOL_URL_FRAGMENT` info |
| Userinfo in `loc` | `url-userinfo.xml` | `PROTOCOL_URL_USERINFO` info |
| Relative `loc` | `url-relative.xml` | `PROTOCOL_URL_NOT_ABSOLUTE` |
| Non-http(s) scheme in `loc` | `url-non-https.xml` | `PROTOCOL_URL_NOT_ABSOLUTE` |
| `loc` out of scope | `url-out-of-scope.xml` | `PROTOCOL_URL_OUT_OF_SCOPE` |
| Invalid percent-encoding | `url-invalid-escape.xml` | `PROTOCOL_URL_INVALID_ESCAPE` |

### 2.3 Date-Time scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Full datetime with timezone | `lastmod-datetime-tz.xml` | Valid POSIXct |
| Date-only `lastmod` | `lastmod-date-only.xml` | Valid; strict `info` |
| Invalid `lastmod` value | `lastmod-invalid.xml` | `PROTOCOL_LASTMOD_INVALID` |
| Future `lastmod` | `lastmod-future.xml` | Passes (no future-date rule in v1) |

### 2.4 Field value scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| `priority` = 0.0 and 1.0 | `priority-boundary.xml` | Valid |
| `priority` out of range | `priority-out-of-range.xml` | `PROTOCOL_PRIORITY_OUT_OF_RANGE` |
| Valid `changefreq` values | `changefreq-valid.xml` | All enum values accepted |
| Invalid `changefreq` value | `changefreq-invalid.xml` | `PROTOCOL_CHANGEFREQ_INVALID` |

### 2.5 Mixed-namespace and extension scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Image extension only | `ns-image.xml` | Layer C validates; images list-column populated |
| News extension only | `ns-news.xml` | Layer C validates; news list-column populated |
| Video extension only | `ns-video.xml` | Layer C validates; video list-column populated |
| Hreflang only | `ns-hreflang.xml` | Layer C validates; alternates populated |
| All four extensions | `ns-all-four.xml` | Runtime-generated mixed profile validates |
| Image > 1000 per page | `ns-image-count.xml` | `PROTOCOL_IMAGE_COUNT_EXCEEDED` |
| Broken video field | `ns-video-invalid.xml` | `PROTOCOL_VIDEO_FIELD_INVALID` |
| Unknown namespace (not imported) | `ns-unknown.xml` | `SCHEMA_UNKNOWN_NAMESPACE` |

### 2.6 Hreflang scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Valid hreflang set with `x-default` | `hreflang-valid.xml` | Passes |
| `x-default` missing | `hreflang-no-xdefault.xml` | `HREFLANG_XDEFAULT_MISSING` |
| Duplicate hreflang value in one entry | `hreflang-duplicate.xml` | `HREFLANG_DUPLICATE` |
| Invalid lang token (underscore separator) | `hreflang-invalid-sep.xml` | `HREFLANG_FORMAT_INVALID` |
| Relative `href` in hreflang | `hreflang-relative-href.xml` | Strict-only `HREFLANG_HREF_RELATIVE` |

### 2.7 Encoding scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| BOM-prefixed UTF-8 | `encoding-bom-utf8.xml` | Passes |
| BOM vs XML declaration conflict | `encoding-bom-vs-decl.xml` | Strict `warning` |
| HTTP charset vs BOM conflict | `encoding-charset-conflict.xml` | `ENCODING_CONFLICT` info |

### 2.8 Compression and archive scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Valid gzip (`.xml.gz`) | `valid.xml.gz` | Transparent decompression |
| Valid gzip (`.txt.gz`) | `valid.txt.gz` | Text sitemap after decompression |
| Malformed gzip | `malformed.xml.gz` | `UNSUPPORTED_MALFORMED_GZIP` |
| `.tar.gz` within size limit | `valid.tar.gz` | Bounded extraction; correct rows |
| `.tar.gz` exceeding file count | `too-many-files.tar.gz` | Count cap enforced |
| Path-traversal in archive | `path-traversal.tar.gz` | Rejected entry; error finding |

### 2.9 Index recursion scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Simple index with two children | `index-simple.xml` | Tree depth 1 |
| Nested index (index in index) | `index-nested.xml` | `SITEMAP_INDEX_NESTED` warning; still expanded |
| Self-referential index | `index-self-ref.xml` | `INDEX_CYCLE_DETECTED` |
| A → B → A cycle | `index-cycle-ab.xml` | `INDEX_CYCLE_DETECTED` |
| Max depth exceeded | `index-deep.xml` | `INDEX_DEPTH_EXCEEDED` |
| Child count at cap | `index-at-cap.xml` | Last child included |
| Child count exceeding cap | `index-over-cap.xml` | `INDEX_CHILD_COUNT_EXCEEDED` |

### 2.10 HTML masquerade and unsupported inputs

| Scenario | Fixture | Expected behavior |
|---|---|---|
| HTML page at sitemap URL | `html-masquerade.html` | `UNSUPPORTED_HTML_MASQUERADE` |
| Unsupported root element | `unsupported-root.xml` | `UNSUPPORTED_ROOT` |
| Sitemap index child → RSS feed | `index-rss-child.xml` | `UNSUPPORTED_FEED` |
| Truncated / incomplete XML document | `truncated.xml` | Malformed XML → `SCHEMA_INVALID`; never silently parsed. (A mid-stream *stall* is a fetch timeout → `sitemapr_timeout`, not a truncation condition — see `scenario-fixture-map.md`.) |
| Oversized sitemap (> 50 MB uncompressed) | `oversize.xml.gz` | `PROTOCOL_SIZE_EXCEEDED` finding; body still parsed so other findings surface |
| Body over 500 MB safety ceiling | synthetic (ceiling lowered in test) | `FETCH_BODY_CEILING_EXCEEDED` (`fatal`); `sitemapr_body_ceiling` condition in parse APIs; partial result |

### 2.11 Text sitemap scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Valid text sitemap | `valid-text.txt` | Rows with `loc`; other cols `NA` |
| Blank lines in text sitemap | `text-blank-lines.txt` | Strict `info`; silent in non-strict |
| URL > 2048 chars | `text-long-url.txt` | `PROTOCOL_TEXT_URL_TOO_LONG` |
| Non-http(s) line | `text-non-https.txt` | `PROTOCOL_URL_NOT_ABSOLUTE` |

### 2.12 Determinism (SPEC §29.3)

Each fixture above is run through the full pipeline twice in the same test;
the two findings tibbles are compared with `identical()`. This is a single
parametrized test, not a separate fixture set.

---

## 3. External parity harnesses (non-CRAN)

These harnesses are **not** `testthat` tests. They run in CI outside
`R CMD check` and produce outputs that are checked in as golden fixtures.

### 3.1 Parser parity: `sitemapr` vs `usp`

- Fixture set: the complete `tests/testthat/fixtures/valid-*.xml` corpus
  (excluding deliberately invalid files).
- Run each fixture through `usp` (the Python `ultimate-sitemap-parser`) and
  `sitemapr::read_sitemap()`. Compare `loc` sets; any discrepancy is a
  blocker.
- Golden output: `tests/testthat/goldens/parity-usp/` — one JSON file per
  fixture containing the `usp` `loc` set.
- `usp` is a `devtools::dev_dependency()` (Python); it is **never** in
  `Suggests`.

### 3.2 Validator conformance: `sitemapr` vs `sitemap-validator`

- Fixture set: the `sitemap-validator` reference valid/invalid corpus.
- Run each fixture through `sitemap-validator` (Node) and
  `sitemapr::validate_sitemap()`. Compare pass/fail and finding codes
  (not messages).
- Golden output: `tests/testthat/goldens/parity-sv/` — one JSON per fixture.
- `sitemap-validator` is a CI-only Node tool; never a package dependency.

### 3.3 Memory bound harness

- Fixture: a generated spec-max file (50 000 URLs, ~50 MB uncompressed).
- Run `validate_sitemap()` and measure peak RSS.
- Assert peak RSS ≤ documented per-file footprint.
- This fixture is **too large to commit**; it is generated by a CI script
  and not included in the repo.

---

## 4. Licensing and provenance

Before any asset in `inst/` lands in a commit:
- Schemas from `sitemap-validator`: add `inst/schemas/LICENSE` citing the
  source repo and its license.
- Fixtures from `sitemap-validator`: add `inst/fixtures/COPYRIGHTS` or
  a comment in `inst/COPYRIGHTS` at the package root.
- The sitemap.org XSDs carry their own terms — check and document.
- Failure to include provenance is a `R CMD check` / CRAN-policy blocker.

---

## 5. Open questions for M0

- Which fixture files already exist in `sitemap-validator/fixtures/` vs.
  need to be authored from scratch? Inventory before M0.
- Are the sitemap.org XSDs included in the TS repo, or are they hosted
  externally? Verify license terms.
- Does the `usp` parity harness need a Python virtual-env in CI, or can it
  run via `reticulate`? Decision affects CI setup in M0.
