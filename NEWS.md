# sitemapr 0.0.0.9000

First development release: a deterministic toolkit for reading and validating XML, text, and index sitemaps against the Sitemap Protocol 0.9 and related W3C and RFC standards.

## Reading

* `read_sitemap()` reads a sitemap from a URL or a local file (`.xml`, `.txt`, `.gz`, `.tar.gz`) into one tidy tibble row per URL, with list-columns for the image, video, news, and hreflang extensions.
* XML `urlset`/`sitemapindex` and one-URL-per-line text sitemaps are supported, with transparent gzip decompression and bounded, safe local `.tar.gz` extraction.
* A top-level sitemap index is expanded recursively, cycle-safe and capped, and every child sitemap's rows carry provenance.
* `max_active` opts into bounded-concurrency index expansion in `read_sitemap()`, `audit_sitemap()`, and `sitemap_tree()`, with results identical to the sequential default (ADR-008).
* XML parsing is XXE-safe: external entities are never expanded.
* Windows drive-letter and UNC paths are recognized as local files on every platform, so a missing one fails as a missing file rather than an invalid URL.
* Case folding is ASCII-only, so scheme, host, header and hreflang matching survives a Turkish or Azeri locale (SITE-rkstwdsr).

## Validation

* `validate_sitemap()` returns a stable, deterministic findings tibble, one row per issue with a `code`, `severity`, and `layer`.
* Schema validation (Layer C) runs against bundled XSD profiles for the core protocol and the image, video, news, pagemap, and xhtml-hreflang extensions.
* Protocol validation (Layer D) checks `<loc>` URL rules, encoding conformance, counts, field values, hreflang tokens, extension fields, and text-sitemap lines.
* Hreflang cluster findings flag a missing self-reference, a non-reciprocal return link, and inconsistent language annotations across the corpus.
* `mode = "non-strict"` downgrades schema violations to warnings and drops strict-only findings.
* RSS/Atom feeds are reported as an unsupported-feed finding rather than misparsed.
* A missing or unreadable local file given as the only source aborts with a classed `sitemapr_local_read_error` naming the path; with several sources it is a `FETCH_FAILED` finding.

## Page and robots checking (Layer E)

* `check_robots` in `validate_sitemap()` and `validate_sitemaps()` opts into checking the advertised URLs against the host's `robots.txt`, as `robots_user_agent` (`"*"` by default).
* `validate_sitemap_robots()` and `validate_sitemaps_robots()` run that check under a `robots_context()`, with engine presets from `robots_context_preset()` (ADR-009).
* `validate_sitemap_ruleset(x, sitemap_ruleset, robots_context =)` selects both engine-aware axes in a single call, and passing both `robots_context` and a non-default `robots_user_agent` is an error.
* A matcher backend `robotstxtr` reports as unavailable yields `ROBOTS_INDETERMINATE` for every URL rather than a guessed allow.
* `robots_context()` rejects a product token its matcher backend does not accept, which needs `robotstxtr` >= 0.3.0.
* `inspect_pages` opts into budgeted, deterministically sampled page inspection of transport outcome, canonical, `noindex` signals, and hreflang reciprocity, under eleven `page`-layer codes.
* `page_mode`, `page_sample`, `page_budget`, and `page_user_agent` control page inspection, which always fetches sequentially (ADR-008).
* Both checks default to `FALSE`, and with them off the result is identical to a call without them.
* A run with `inspect_pages = TRUE` carries a `page_coverage` attribute reporting what was actually covered and which caps bit.

## Discovery

* `sitemap_tree()` discovers a site's sitemaps from a root URL as a tree of accepted and rejected candidates.
* Candidates come from robots.txt `Sitemap:` directives, explicit seeds, and an ordered catalog of guessed paths; `sitemap_tree_from_bytes()` classifies an already-fetched document (ADR-006).
* `probe_url()` reports what a single URL is without expanding it, and returns fetch or parse failures in a `sitemapr_probe` record rather than raising them.

## Resource bounds

* `index_limits()` now caps a traversal by default at 50 000 sitemaps and 25 000 000 URLs, returning a partial result with an `INDEX_TOTAL_*_EXCEEDED` finding; pass `Inf` to opt out.
* Each finding code contributes at most 100 rows to a report, the rest counted in one `REPORT_TRUNCATED` row; set `options(sitemapr.max_findings_per_code = )` to change it.
* Robots findings are built in one vectorized pass, so a high-cardinality robots result is much faster.
* A truncated, crafted, or size-mismatched `.gz` sitemap fails with the classed decompression error instead of exhausting memory or hanging R.

## Per-engine rulesets

* `validate_sitemap_ruleset()` and `validate_sitemaps_ruleset()` validate under a named engine's rules via `sitemap_ruleset`, enumerated by `sitemap_rulesets()` (ADR-009).
* `validate_sitemap_ruleset(context =)` rejects anything that is not a `ruleset_context()`.
* An engine ruleset adds four columns, `ruleset`, `ruleset_revision`, `context`, and `provenance`; a baseline call keeps the ten-column schema unchanged.
* `provenance` tags whether a finding is an executable verdict or diagnostic only.
* `ruleset_context()` and `ruleset_context_for_child()` build the per-source context axes a finding is evaluated under.
* `gsc_submission()` and `robots_cross_submission()` are presets over `ruleset_context()` for Search Console and `robots.txt` submissions.
* **Breaking:** `subject_ref` keeps the document's own scheme, percent-encodes fragment URLs, and numbers `#index-child` refs; refs persisted in the old `sitemap://` form need migrating.
* `ENCODING_NOT_UTF8` reports a sitemap that is not UTF-8, judged from its encoding signals, and `ENCODING_BOM_DETECTED` reports a byte-order mark.
* `ruleset_revision()` returns a ruleset's published revision string.
* `sitemap_contract()` reports the findings-contract generation, the registry revision, and the supported `sitemap-validator` and `robotstxtr` version ranges (ADR-009).
* Three Yandex-only codes ship: `PROTOCOL_URL_DECODED_TOO_LONG`, `PROTOCOL_TAG_DATA_LIMIT_EXCEEDED`, and `ENGINE_UNSUPPORTED_SITEMAP_FORMAT`.

## Reporting

* `report_sitemap()` now renders each finding's remediation hint, context, ruleset and provenance, with diagnostic provenance visually distinct (ADR-009).
* A new **Checks** section lists each check as passed, reported an issue, or not exercised, counting a layer as run only on positive evidence.
* A new **Recommendations** section flags absent or stale `lastmod`, ignored `priority` and `changefreq`, and documents nearing protocol size bounds.
* The findings tibble may carry a `layers_run` attribute naming layers that ran without leaving rows, such as `"robots"` and `"schema"`.

## Network safety

* An SSRF guard blocks requests to private, loopback, link-local, and cloud-metadata addresses, including NAT64, IPv4-translated, and IPv4-compatible IPv6 embeddings.
* The guard also decodes 6to4, Teredo, and ISATAP addresses and classifies the IPv4 address each one wraps.
* An IPv6 literal that does not expand to 8 hextets is refused as `malformed-address`.
* The guard decides IPv6 unspecified and loopback addresses by value, so every spelling of `::1` and `::` is caught (SITE-vovtwvuh).
* The guard decides IPv6 link-local and AWS metadata addresses by value, so leading-zero spellings agree (SITE-mhfmtdxa).
* The guard blocks more spellings of the GCP metadata host, including a trailing dot, the bare `metadata`, and UTS #46 equivalents (SITE-rafvyfvp).

## Request customization

* `request_policy()`, accepted as `policy` by every reading, validation, and discovery entry point, sets headers, auth, proxy, TLS, retry, and throttling.
* A request policy cannot override the per-hop SSRF guard, redirect control, or non-2xx error policy.

## Requirements

* sitemapr requires R >= 4.1.0, as its dependency `httr2` does.
* `rurl` now resolves from CRAN, at `rurl` >= 3.0.1 (SITE-ieajhiee).
