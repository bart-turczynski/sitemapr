# sitemapr 0.0.0.9000

First development release. `sitemapr` is a deterministic toolkit for reading and
validating XML, text, and index sitemaps against the Sitemap Protocol 0.9 and
related W3C and RFC standards.

## Reading

* `read_sitemap()` reads a sitemap from a URL or a local file (`.xml`, `.txt`,
  `.gz`, `.tar.gz`) into one tidy tibble row per URL, with `lastmod`,
  `changefreq`, `priority`, and list-columns for the image, video, news, and
  hreflang-alternate extensions.
* XML `urlset`/`sitemapindex` and one-URL-per-line text sitemaps are supported,
  with transparent gzip decompression and bounded, safe local `.tar.gz`
  extraction.
* A top-level sitemap index is expanded recursively — cycle-safe, depth- and
  count-capped — so every reachable child sitemap's rows carry provenance.
* XML parsing is XXE-safe: external entities are never expanded.

## Validation

* `validate_sitemap()` returns a stable findings tibble — one row per issue with
  a `code`, `severity`, and the `layer` that produced it. The same source and
  mode always yield a row-for-row identical result.
* Schema validation (Layer C) against bundled, clean-room XSD profiles for the
  core protocol and the image, video, news, pagemap, and xhtml-hreflang
  extensions. Wrapper XSDs for arbitrary namespace combinations are synthesized
  and cached on demand.
* Protocol validation (Layer D): `<loc>` URL rules with IRI identity, `<loc>`
  equivalence and RFC-3986/3987 encoding conformance, count and field-value
  rules, hreflang token policy, extension field rules, per-line text-sitemap
  rules, and unsupported-input/encoding diagnostics.
* `mode = "non-strict"` downgrades schema violations to warnings and drops
  strict-only findings.
* RSS/Atom feeds are detected and reported as an unsupported-feed finding rather
  than misparsed.

## Discovery

* `sitemap_tree()` discovers a site's sitemaps from a root URL, returning a
  discovery tree (one row per candidate, marked `accepted` or `rejected`).
* Candidates come from robots.txt `Sitemap:` directives (ADR-006), explicit
  seed entry points, and an ordered catalog of generic and CMS-oriented guessed
  paths; results are deduped and capped. `sitemap_tree_from_bytes()` classifies
  an already-fetched document.

## Network safety

* SSRF guard blocks requests to private, loopback, link-local, and
  cloud-metadata addresses, including decoding of NAT64, IPv4-translated, and
  IPv4-compatible IPv6 embeddings.
