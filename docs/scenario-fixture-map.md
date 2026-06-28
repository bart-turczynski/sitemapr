# Cucumber scenario → fixture and v1 ticket traceability

This document maps every Cucumber scenario in `tests/testthat/features/` to its
backing fixture (or explains why it is synthetic) and to the v1 fp issue it
exercises. The intent is to keep acceptance scenarios thin and traceable; edge-
case matrices live in `testthat`, not here.

These feature files are pending acceptance drafts from the planning phase. They
are not part of the active `R CMD check` Cucumber run until their mapped fp
tracer-bullet tickets add the package behavior and step definitions.

**Design principles:**
- Every scenario either references a fixture file or is explicitly marked
  "synthetic" (the fixture is a generated/stubbed object in step definitions).
- Every scenario maps to exactly one v1 fp issue or a named post-v1 exclusion.
- Cucumber scenarios cover golden-path behavior and the most important negative
  cases; fine-grained combinations are left to testthat.

---

## input_normalization.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Direct sitemap URL accepted | `valid-minimal.xml` | SITE-qebdxvlt |
| Explicit http scheme preserved | `valid-minimal.xml` (http variant) | SITE-qebdxvlt |
| Schemeless input receives https | synthetic (bare domain input) | SITE-qebdxvlt |
| Site root reduced to origin | synthetic | SITE-qebdxvlt |
| Unicode host normalized via IDNA | `url-idna-host.xml` | SITE-qebdxvlt |
| Host and scheme lowercased | synthetic | SITE-qebdxvlt |
| Path dot-segments resolved | synthetic | SITE-qebdxvlt |
| Local file accepted and classified | `valid-minimal.xml` (local path) | SITE-qebdxvlt |
| URL vector produces multiple records | `valid-minimal.xml` × 2 | SITE-qebdxvlt |
| URL vector deduplication | duplicate of `valid-minimal.xml` URL | SITE-qebdxvlt |
| URL vector cap enforced | synthetic (26-element vector) | SITE-qebdxvlt |
| Full-URL identity key is not clean_url | `url-duplicate-loc.xml` (port variant) | SITE-qebdxvlt |

---

## discovery.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Generic guessed paths tried in catalog order | synthetic (httptest2 stub) | SITE-avdanhik |
| CMS-specific paths included | synthetic | SITE-avdanhik |
| Candidate deduplication | synthetic | SITE-avdanhik |
| 200 response promotes candidate | synthetic | SITE-avdanhik |
| 404 produces rejected not-found, not finding | synthetic | SITE-avdanhik |
| Max candidate cap enforced | synthetic | SITE-avdanhik |
| sitemap_tree includes accepted + rejected | synthetic | SITE-avdanhik |
| sitemap_tree column set | synthetic | SITE-avdanhik |
| robots.txt not fetched | synthetic (request logger stub) | SITE-pgtudaic |

---

## fetch_classification.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Default User-Agent pattern | synthetic (header echo stub) | SITE-efrzatkb |
| Custom User-Agent | synthetic | SITE-efrzatkb |
| Timeout enforced | synthetic (slow server stub) | SITE-efrzatkb |
| Mid-stream timeout discards partial body | synthetic (stalling body stub) | SITE-efrzatkb |
| Redirects followed up to limit | synthetic | SITE-efrzatkb |
| Redirects exceeding limit | synthetic | SITE-efrzatkb |
| SSRF guard on redirect target | synthetic | SITE-veptsgbs |
| Loopback rejected | synthetic | SITE-veptsgbs |
| IPv4-mapped IPv6 rejected | synthetic | SITE-veptsgbs |
| Cloud metadata rejected | synthetic | SITE-veptsgbs |
| SSRF guard disabled via flag | synthetic | SITE-veptsgbs |
| XML classified by bytes, not extension | `valid-minimal.xml` (renamed) | SITE-efrzatkb |
| Gzip classified regardless of extension | `valid.xml.gz` (renamed) | SITE-efrzatkb |
| Fetch metadata on sources attribute | `valid-minimal.xml` | SITE-efrzatkb |
| Child 4xx → warning + partial result | synthetic (stub child 404) | SITE-efrzatkb |

---

## parse_formats.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| XML urlset columns | `valid-minimal.xml` | SITE-saqolkqu |
| lastmod as POSIXct | `valid-full-fields.xml` | SITE-saqolkqu |
| Extension data as list-columns | `ns-image.xml` | SITE-saqolkqu |
| Text sitemap rows | `valid-text.txt` | SITE-saqolkqu |
| Gzip decompression | `valid.xml.gz` | SITE-saqolkqu |
| Local tar.gz extraction | `valid.tar.gz` | SITE-saqolkqu |
| Non-sitemap files skipped in tar.gz | `mixed.tar.gz` | SITE-saqolkqu |
| Path-traversal rejected in tar.gz | `path-traversal.tar.gz` | SITE-saqolkqu |
| Malformed gzip raises condition | `malformed.xml.gz` | SITE-saqolkqu |
| source_sitemap provenance | `index-simple.xml` | SITE-saqolkqu |
| Parse API never emits findings | `valid-full-fields.xml` | SITE-saqolkqu |
| Entry-point 500 → error condition | synthetic | SITE-saqolkqu |
| sources attribute attached | `valid-minimal.xml` | SITE-saqolkqu |

---

## index_expansion.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Index children fetched | `index-simple.xml` | SITE-mzbuuyfy |
| sitemap_tree depth/parent/provenance | `index-simple.xml` | SITE-mzbuuyfy |
| Duplicate child expanded once | `index-duplicate-child.xml` | SITE-mzbuuyfy |
| Self-referential cycle detected | `index-self-ref.xml` | SITE-mzbuuyfy |
| A→B→A cycle detected | `index-cycle-ab.xml` | SITE-mzbuuyfy |
| Max depth 3 enforced | `index-deep.xml` | SITE-mzbuuyfy |
| Child count cap enforced | `index-over-cap.xml` | SITE-mzbuuyfy |
| Nested sitemapindex: warning + expanded | `index-nested.xml` | SITE-mzbuuyfy |
| Parent-child chain in tree | `index-simple.xml` | SITE-mzbuuyfy |

---

## schema_validation.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Valid urlset passes | `valid-minimal.xml` | SITE-qcjvesdw |
| Valid sitemapindex passes | `valid-index.xml` | SITE-qcjvesdw |
| Invalid XML → SCHEMA_INVALID | `schema-invalid-urlset.xml` | SITE-qcjvesdw |
| Image profile validates | `ns-image.xml` | SITE-qcjvesdw |
| News profile validates | `ns-news.xml` | SITE-qcjvesdw |
| Video profile validates | `ns-video.xml` | SITE-qcjvesdw |
| Hreflang profile validates | `ns-hreflang.xml` | SITE-qcjvesdw |
| Mixed all-four validates | `ns-all-four.xml` | SITE-qcjvesdw |
| Broken extension in mixed → SCHEMA_INVALID | `ns-video-invalid-in-mixed.xml` | SITE-qcjvesdw |
| Unknown namespace → SCHEMA_UNKNOWN_NAMESPACE | `ns-unknown.xml` | SITE-qcjvesdw |
| XXE entity expansion blocked | `xxe-attempt.xml` | SITE-qcjvesdw |
| No Java subprocess | `valid-minimal.xml` (process check) | SITE-qcjvesdw |

---

## protocol_validation.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Relative loc | `url-relative.xml` | SITE-nsixzwux |
| Non-http(s) scheme | `url-non-https.xml` | SITE-nsixzwux |
| Out-of-scope loc | `url-out-of-scope.xml` | SITE-nsixzwux |
| Duplicate loc | `url-duplicate-loc.xml` | SITE-nsixzwux |
| Default port stripped for dedup | `url-default-port.xml` | SITE-nsixzwux |
| Fragment info finding | `url-fragment.xml` | SITE-nsixzwux |
| Invalid percent-encoding | `url-invalid-escape.xml` | SITE-nsixzwux |
| IRI accepted, URI identity used | `url-iri-path.xml` | SITE-nsixzwux |
| URL count at cap | `url-count-at-cap.xml` | SITE-nsixzwux |
| URL count over cap | `url-count-over-cap.xml` | SITE-nsixzwux |
| Priority boundaries | `priority-boundary.xml` | SITE-nsixzwux |
| Priority out of range | `priority-out-of-range.xml` | SITE-nsixzwux |
| Invalid changefreq | `changefreq-invalid.xml` | SITE-nsixzwux |
| Date-only lastmod strict info | `lastmod-date-only.xml` | SITE-nsixzwux |
| Date-only lastmod non-strict silent | `lastmod-date-only.xml` | SITE-nsixzwux |
| Invalid lastmod | `lastmod-invalid.xml` | SITE-nsixzwux |
| Valid hreflang | `hreflang-valid.xml` | SITE-nsixzwux |
| Invalid hreflang separator | `hreflang-invalid-sep.xml` | SITE-nsixzwux |
| x-default missing | `hreflang-no-xdefault.xml` | SITE-nsixzwux |
| Duplicate hreflang | `hreflang-duplicate.xml` | SITE-nsixzwux |
| Relative href strict | `hreflang-relative-href.xml` | SITE-nsixzwux |
| Relative href non-strict silent | `hreflang-relative-href.xml` | SITE-nsixzwux |
| Valid text sitemap | `valid-text.txt` | SITE-nsixzwux |
| Blank line strict info | `text-blank-lines.txt` | SITE-nsixzwux |
| Blank line non-strict silent | `text-blank-lines.txt` | SITE-nsixzwux |
| Text URL too long | `text-long-url.txt` | SITE-nsixzwux |
| HTML masquerade | `html-masquerade.html` | SITE-nsixzwux |
| Unsupported root | `unsupported-root.xml` | SITE-nsixzwux |
| Sitemap index → RSS feed | `index-rss-child.xml` | SITE-nsixzwux |

---

## findings_contract.feature

| Scenario | Fixture | v1 issue |
|---|---|---|
| Returns a tibble | `valid-minimal.xml` | SITE-tqtmfqlv |
| Required columns present | `schema-invalid-urlset.xml` | SITE-tqtmfqlv |
| Severity vocabulary | any finding fixture | SITE-tqtmfqlv |
| Layer vocabulary | any finding fixture | SITE-tqtmfqlv |
| subject_ref URI scheme | `url-duplicate-loc.xml` | SITE-tqtmfqlv |
| Evidence excerpt capped at 500 | any XML finding fixture | SITE-tqtmfqlv |
| Evidence excerpt capped at 200 for text | `text-long-url.txt` | SITE-tqtmfqlv |
| mode column reflects call mode | `schema-invalid-urlset.xml` | SITE-tqtmfqlv |
| is_strict_only TRUE for strict-only rules | `lastmod-date-only.xml` | SITE-tqtmfqlv |
| remediation_hint NA when absent | any finding without hint | SITE-tqtmfqlv |
| Strict fails on schema violations | `schema-invalid-urlset.xml` | SITE-tqtmfqlv |
| Non-strict reports but downgrades severity | `schema-invalid-urlset.xml` | SITE-tqtmfqlv |
| Strict-only rules absent in non-strict | `lastmod-date-only.xml` | SITE-tqtmfqlv |
| Codes stable across calls | `url-duplicate-loc.xml` | SITE-tqtmfqlv |
| Determinism across repeated runs | any fixture | SITE-tqtmfqlv |

---

## Post-v1 exclusions noted in features

The following scenarios or behavior areas were considered for this Cucumber
layer and explicitly excluded:

| Exclusion | Reason |
|---|---|
| Per-URL page inspection (HTTP status, canonical, robots meta) | Layer E, post-v1 |
| hreflang cross-URL reciprocity | SPEC §17 post-v1 clause |
| Robots.txt discovery or Disallow rule application | Post-v1; ADR-002 |
| DNS resolve-then-check in SSRF guard | Post-v1; ADR-003 |
| RSS/Atom feed parsing within sitemap index | Out of scope for v1 (UNSUPPORTED_FEED finding instead) |
| IANA language tag snapshot validation | Cross-URL, post-v1 |
