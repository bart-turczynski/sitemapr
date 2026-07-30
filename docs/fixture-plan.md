# v1 Fixture and golden corpus plan

This document defines the fixture strategy for `sitemapr` v1. All `testthat`
tests must run offline and pass `R CMD check --as-cran` without network
access. External parity harnesses (against `usp` and `sitemap-validator`) run
outside CRAN and produce checked-in golden outputs.

---

## 1. Upstream assets to reuse

### 1.1 Schemas → `inst/schemas/`

**Clean-room sitemapr-authored** (SITE-cgdtkbpc). Each bundled XSD expresses the
element model of a public protocol — element names, types, cardinalities,
enumerations, and patterns are the protocol's functional facts, not copied schema
text — so none carries third-party copyright and all ship under the package
license (MIT). The build is reproducible: `data-raw/schemas/build-schemas.R` is
the single source of truth — it copies the authored sources from
`data-raw/schemas/authored/`, LF-normalizes, well-formedness-checks, and
regenerates `inst/schemas/SOURCES.md` + `inst/schemas/LICENSE`. `data-raw/` is
`.Rbuildignore`'d.

Atomic schemas bundled (one per namespace):
- `sitemap.xsd`, `siteindex.xsd` — core urlset + sitemapindex (Sitemap
  Protocol 0.9)
- `sitemap-image.xsd` (image 1.1), `sitemap-video.xsd` (video 1.1),
  `sitemap-news.xsd` (news 0.9), `sitemap-pagemap.xsd` (PageMap 1.0)
- `xhtml-hreflang.xsd` — minimal `xhtml:link` element for hreflang alternates.

Not bundled:
- Google `sitemap-mobile/1.0` — deprecated and withdrawn upstream (404).

Pre-composed core+extension profiles and runtime mixed profiles
(`inst/schemas/generated/`, `tempdir()`) are produced by the catalog/generation
slices (SITE-ebsprhtb, SITE-mwoykldd), not hand-copied here.

**License/provenance:** authoring our own schemas instead of vendoring upstream
resolves the CRAN license blocker that S6.1 (SITE-bjkuujcw) left open — the
Google reference XSDs are `Copyright Google Inc.` *All Rights Reserved* (no
redistribution grant) and the sitemaps.org XSDs are CC BY-SA 2.5 (copyleft),
neither of which can be relicensed into an MIT package. `inst/schemas/SOURCES.md`
(per-file namespace, role, spec link, sha256) and `inst/schemas/LICENSE` ship with
the schemas. Behavioral equivalence with the upstream XSDs is verified by the
dev-only `data-raw/schemas/check-parity.R` oracle and the shipping
`test-schema-conformance.R`; the corpus is shared via
`tests/testthat/helper-schema-corpus.R`.

### 1.2 Fixtures → `tests/testthat/fixtures/`

Source: `bart-turczynski/sitemap-validator` → `fixtures/`

These are language-agnostic XML/text files. Copy as-is; the R test suite
references them as local paths. Do not add a network call in any test that
could instead use a fixture.

---

## 2. In-tree fixture corpus (CRAN-safe, offline)

Every scenario in this section must have at least one `testthat` test asserting
the expected output or condition. Most also have a committed fixture file under
`tests/testthat/fixtures/`, and the Fixture column names it — as a path relative
to that directory when the file lives in a subdirectory such as `corpus/`.

Some scenarios cannot be expressed as a committed file, and for those the
Fixture column says how the input is built instead and the row names the test
that covers it. There are three reasons this happens, and a row states which
one applies:

- **`in-memory`** — the input is a value, not a document: the rule under test
  takes parsed rows or a URL string, so writing a file would only add a parse
  step. Most of §2.2's URL rules are like this.
- **`synthetic`** — a committed file would have to be pathologically large (the
  repository's pre-commit guard rejects blobs over 5 MB, and CRAN caps package
  size), or a limit is lowered in the test so a small input crosses it.
- **mocked response** — the scenario depends on HTTP response metadata, which no
  local file can carry. Called out explicitly where it appears (see §2.7).

### 2.1 Standards-baseline scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Minimal valid XML urlset | `valid-minimal.xml` | Parse succeeds; 1 row |
| Maximal field set (all optional fields) | `valid-full-fields.xml` | All columns populated |
| Valid sitemapindex | `valid-index.xml` | Tree with parent→child |
| Text sitemap | `valid-text.txt` | Parse succeeds |
| Gzip-compressed XML | `corpus/compressed/valid.xml.gz` | Transparent decompression |
| Local `.tar.gz` archive | `corpus/compressed/valid.tar.gz` | Bounded extraction |

### 2.2 URL and IRI scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Unicode path (IRI → URI mapping) | `url-iri-path.xml` | `PROTOCOL_URL_NOT_ESCAPED` info; identity key uses URI form |
| Char illegal in URI and IRI (`{` `}`) | `url-unescaped-illegal.xml` | `PROTOCOL_URL_NOT_ESCAPED` warning |
| Punycode/IDNA host | in-memory | Host lowercased, IDNA applied — `test-input.R` ("unicode host is normalized via IDNA, original retained") and `test-url.R` ("parse_url_adapter emits Punycode host for Unicode input") |
| Default port stripped (`:80` / `:443`) | in-memory | Port absent from identity key — `test-url.R` ("build_loc_key collapses the scheme's default port to identity"); a *non*-default port is retained, and a mismatched `http:443` is not collapsed |
| Byte-identical `loc` repeat | `urlset-duplicate-loc.xml` | `PROTOCOL_DUPLICATE_LOC` warning |
| Canonically equal `loc`, differing bytes (`:443` vs default) | in-memory | `PROTOCOL_URL_EQUIVALENT` warning |
| Fragment in `loc` | `url-fragment.xml` | `PROTOCOL_URL_FRAGMENT` info |
| Userinfo in `loc` | in-memory | `PROTOCOL_URL_USERINFO` info — `test-protocol-validate.R` ("userinfo produces an info PROTOCOL_URL_USERINFO") |
| Relative `loc` | `url-relative.xml` | `PROTOCOL_URL_NOT_ABSOLUTE` |
| Non-http(s) scheme in `loc` | `url-non-https.xml` | `PROTOCOL_URL_NOT_ABSOLUTE` |
| `loc` out of scope | in-memory | `PROTOCOL_URL_OUT_OF_SCOPE` — `test-protocol-validate.R` ("a different-host loc produces PROTOCOL_URL_OUT_OF_SCOPE", plus the above-directory, in-scope and unknown-sitemap-URL cases) |
| Invalid percent-encoding | `url-invalid-escape.xml` | `PROTOCOL_URL_INVALID_ESCAPE` |

### 2.3 Date-Time scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Full datetime with timezone | in-memory | Valid POSIXct, no finding (executed: `2024-01-01T12:00:00+02:00` yields no findings and a `POSIXct` `lastmod`). A datetime *without* a timezone is invalid — `test-protocol-validate.R` ("a datetime lastmod without a timezone is invalid") |
| Date-only `lastmod` | `lastmod-date-only.xml` | Valid; strict `info` |
| Invalid `lastmod` value | `lastmod-invalid.xml` | `PROTOCOL_LASTMOD_INVALID` |
| Future `lastmod` | in-memory | Passes; there is no future-date rule in v1 (executed: `2099-01-01T12:00:00+00:00` yields no findings). Use a **full datetime** to test this: a date-only future value such as `2099-01-01` fires strict-only `PROTOCOL_LASTMOD_DATE_ONLY` from the row above, which would read as a future-date rule that does not exist |

### 2.4 Field value scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| `priority` = 0.0 and 1.0 | `priority-boundary.xml` | Valid |
| `priority` out of range | `priority-out-of-range.xml` | `PROTOCOL_PRIORITY_OUT_OF_RANGE` |
| Valid `changefreq` values | in-memory | All seven enum values accepted, no findings — `test-protocol-validate.R` ("every valid changefreq enum value is accepted"). The enum is case-sensitive: `Daily` is invalid |
| Invalid `changefreq` value | `changefreq-invalid.xml` | `PROTOCOL_CHANGEFREQ_INVALID` |

### 2.5 Mixed-namespace and extension scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Image extension only | `ns-image.xml` | Layer C validates; images list-column populated |
| News extension only | `ns-news.xml` | Layer C validates; news list-column populated |
| Video extension only | `ns-video.xml` | Layer C validates; video list-column populated |
| Hreflang only | `ns-hreflang.xml` | Layer C validates; alternates populated |
| All four extensions | `ns-all-four.xml` | Runtime-generated mixed profile validates |
| Image > 1000 per page | synthetic (1 001 images built in the test) | `PROTOCOL_IMAGE_COUNT_EXCEEDED` — `test-protocol-validate.R` ("more than 1000 images per URL is PROTOCOL_IMAGE_COUNT_EXCEEDED"); the cap is configurable via `limits`, so a committed 1 001-image document is unnecessary |
| Broken video field | `ns-video-invalid-in-mixed.xml` | `PROTOCOL_VIDEO_FIELD_INVALID` (executed: the file also yields `SCHEMA_INVALID` and two `HREFLANG_*` findings, being a mixed-namespace document). The individual video rules — neither `player_loc` nor `content_loc`, the 32-tag cap, over-long description, bad enum value — are covered in-memory in `test-protocol-validate.R` |
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

These are imported cross-port fixtures (SITE-uivyzfhe), so the paths below are
relative to `tests/testthat/fixtures/` rather than bare names, and every outcome
is pinned in `fixtures/corpus-golden.tsv`.

| Scenario | Fixture | Expected behavior |
|---|---|---|
| BOM-prefixed UTF-8 | `corpus/encoding/utf8-bom.xml` | Passes; no `ENCODING_*` finding |
| Declared UTF-8, no BOM | `corpus/encoding/declared-utf8-no-bom.xml` | Passes |
| Declared ISO-8859-1, no BOM | `corpus/encoding/declared-iso8859-no-bom.xml` | Passes; the declaration is the only signal |
| Neither BOM nor declaration | `corpus/encoding/no-encoding.xml` | Passes; UTF-8 default |
| BOM vs XML declaration conflict | `corpus/encoding/bom-conflict.xml` | `ENCODING_BOM_DECLARATION_CONFLICT` — `info` in `non-strict`, elevated to `warning` in `strict`; fires in both modes |
| UTF-16 LE with BOM | `corpus/encoding/utf16-le-bom.xml` | Classed `sitemapr_xml_parse_error` — a documented limitation, not a finding |

**Not expressible as a corpus fixture: HTTP charset vs BOM/declaration
conflict.** `ENCODING_CONFLICT` requires a response `Content-Type` charset that
disagrees with the document's own signals, and the corpus harness drives every
file through `validate_sitemap()` on a *local path*. A local file has no
response, so `http_charset` is always `NA` there (see `encoding_findings()` in
`R/encoding-facts.R`) and neither HTTP leg of the conflict predicate can fire.
The scenario is covered by mocked-response tests instead — `test-encoding-facts.R`
("an HTTP charset disagreeing with the declaration fires") and
`test-protocol-validate.R` ("an HTTP-charset disagreement is the general
ENCODING_CONFLICT") — so it is exempt from the §2 one-fixture-per-scenario rule.

### 2.8 Compression and archive scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Valid gzip (`.xml.gz`) | `corpus/compressed/valid.xml.gz` | Transparent decompression |
| Valid gzip (`.txt.gz`) | in-memory (built with `gzfile()`) | Text sitemap after decompression — `test-decompress.R` ("a gzipped text sitemap parses identically to the uncompressed one") |
| Malformed gzip | `corpus/compressed/invalid.gz` | `UNSUPPORTED_MALFORMED_GZIP`, pinned in `fixtures/corpus-golden.tsv` |
| `.tar.gz` within size limit | `corpus/compressed/valid.tar.gz` | Bounded extraction; correct rows |
| `.tar.gz` exceeding file count | synthetic (three members, `archive_limits(max_file_count = 2L)`) | **Raises** classed `sitemapr_archive_limit` — it is not a quietly enforced cap — `test-parse-archive.R` ("exceeding the file-count limit raises sitemapr_archive_limit"). The on-disk and decompressed ceilings raise the same class |
| Path-traversal in archive | synthetic (a `../evil.xml` member written in the test) | The unsafe entry is rejected with a **`warning` problem** (not an error finding) and is never parsed, while the archive's safe members still contribute rows — `test-parse-archive.R` ("a path-traversal member is rejected with a warning problem"). Absolute and drive-letter member names are unsafe the same way |

### 2.9 Index recursion scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Simple index with two children | `index-simple.xml` | Tree depth 1 |
| Nested index (index in index) | `index-nested.xml` | `SITEMAP_INDEX_NESTED` warning; still expanded |
| Self-referential index | `index-self-ref.xml` | `INDEX_CYCLE_DETECTED` |
| A → B → A cycle | `index-cycle-ab.xml` | `INDEX_CYCLE_DETECTED` |
| Max depth exceeded | `index-deep.xml` | `INDEX_DEPTH_EXCEEDED` |
| Child count at cap | covered by the over-cap case below | The cap is inclusive: the child *at* the cap is included. Proven by the over-cap test, which declares three children under `max_children = 2L` and asserts exactly two were fetched — `test-index-expansion.R` ("the per-index child-count cap truncates and records one event"). No separate at-cap fixture is needed |
| Child count exceeding cap | `index-over-cap.xml` | `INDEX_CHILD_COUNT_EXCEEDED` |

### 2.10 HTML masquerade and unsupported inputs

| Scenario | Fixture | Expected behavior |
|---|---|---|
| HTML page at sitemap URL | `html-masquerade.html` | `UNSUPPORTED_HTML_MASQUERADE` |
| Unsupported root element | `unsupported-root.xml` | `UNSUPPORTED_ROOT` |
| Sitemap index child → RSS feed | `index-rss-child.xml` | `UNSUPPORTED_FEED` |
| Truncated / incomplete XML document | in-memory | **Raises** classed `sitemapr_xml_parse_error` — a condition, *not* a `SCHEMA_INVALID` finding (executed: an unclosed `<urlset>` raises). Truncation raises for every container: a truncated gzip stream raises `sitemapr_decompression_error` (`test-decompress.R`) and a truncated tar body raises `sitemapr_malformed_archive` (`test-parse-archive.R`). Never silently parsed either way. For a document that parses but violates the schema, see `schema-invalid-urlset.xml`. (A mid-stream *stall* is a fetch timeout → `sitemapr_timeout`, not a truncation condition — see `scenario-fixture-map.md`.) |
| Oversized sitemap (> 50 MB uncompressed) | synthetic (`byte_size` passed to `validate_protocol()` directly) | `PROTOCOL_SIZE_EXCEEDED`, `error`, `subject_type` `document`; body still parsed so other findings surface — `test-protocol-validate.R` ("an oversized document produces PROTOCOL_SIZE_EXCEEDED"). No file is committed because a >50 MB document exceeds both the 5 MB pre-commit blob guard and CRAN's package-size limit. A gzip fixture *would* work for a top-level document — the source records the **decompressed** length (executed: a `.xml.gz` of 90 962 uncompressed bytes compressing to 5 282 records `byte_size` 90 963) — but not for a sitemap-index child, where `index_source_byte_size()` returns `NA` because the recorded size is the compressed transfer size |
| Body over 500 MB safety ceiling | synthetic (ceiling lowered in test) | `FETCH_BODY_CEILING_EXCEEDED` (`fatal`); `sitemapr_body_ceiling` condition in parse APIs; partial result |

### 2.11 Text sitemap scenarios

| Scenario | Fixture | Expected behavior |
|---|---|---|
| Valid text sitemap | `valid-text.txt` | Rows with `loc`; other cols `NA` |
| Blank lines in text sitemap | `text-blank-lines.txt` | Strict `info`; silent in non-strict |
| URL > 2048 chars | `text-long-url.txt` | `PROTOCOL_TEXT_URL_TOO_LONG` |
| Non-http(s) line | `corpus/text/invalid-urls.txt` | `PROTOCOL_URL_NOT_ABSOLUTE`, pinned in `fixtures/corpus-golden.tsv` |

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
- Schemas: clean-room sitemapr-authored under the package license (MIT), built
  by `data-raw/schemas/build-schemas.R`, which regenerates
  `inst/schemas/SOURCES.md` (namespace, role, spec link, sha256) and
  `inst/schemas/LICENSE` in the same commit. We do **not** vendor the upstream
  XSDs: the Google reference schemas are `Copyright Google Inc.` *All Rights
  Reserved* and the sitemaps.org schemas are CC BY-SA 2.5, neither relicensable
  into MIT. Equivalence with upstream is checked by `check-parity.R` (dev-only)
  and `test-schema-conformance.R` (shipping).
- Fixtures: add `inst/fixtures/COPYRIGHTS` or a comment in `inst/COPYRIGHTS`
  at the package root noting origin (authored vs. adapted).
- Failure to include provenance is a `R CMD check` / CRAN-policy blocker.

---

## 5. Open questions for M0

- Which fixture files already exist in `sitemap-validator/fixtures/` vs.
  need to be authored from scratch? Inventory before M0.
- Schema sourcing/licensing: resolved. S6.1 (SITE-bjkuujcw) vendored upstream
  XSDs; SITE-cgdtkbpc replaced them with clean-room sitemapr-authored schemas
  (MIT), closing the Google `All Rights Reserved` / sitemaps.org CC BY-SA blocker.
  No open licensing question remains.
- Does the `usp` parity harness need a Python virtual-env in CI, or can it
  run via `reticulate`? Decision affects CI setup in M0.
