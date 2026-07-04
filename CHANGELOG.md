# Changelog

All notable changes to this project will be documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For the R-package-facing changelog (rendered on the pkgdown site), see
[`NEWS.md`](NEWS.md); this file mirrors it in Keep a Changelog form.

## [Unreleased]

### Added

- **Reading** — `read_sitemap()` reads XML `urlset`/`sitemapindex` and text
  sitemaps from a URL or local file (`.xml`, `.txt`, `.gz`, `.tar.gz`) into one
  tidy tibble row per URL, with image/video/news/hreflang-alternate
  list-columns. Transparent gzip decompression, bounded safe `.tar.gz`
  extraction, cycle-safe depth- and count-capped index expansion, and XXE-safe
  parsing.
- **Validation** — `validate_sitemap()` returns a stable, reproducible findings
  tibble (`code`, `severity`, `layer`). Layer C schema validation against
  bundled clean-room XSD profiles (core plus image, video, news, pagemap,
  xhtml-hreflang) with on-demand synthesized wrapper XSDs for arbitrary
  namespace combinations. Layer D protocol validation: `<loc>` URL rules and IRI
  identity, `<loc>` equivalence and RFC-3986/3987 encoding conformance, count
  and field-value rules, hreflang token policy, extension field rules, text
  per-line rules, and unsupported-input/encoding diagnostics. `mode` toggles
  strict vs non-strict. RSS/Atom feeds reported as unsupported.
- **Discovery** — `sitemap_tree()` discovers a site's sitemaps from a root URL
  (robots.txt `Sitemap:` directives, explicit seeds, and an ordered generic/CMS
  guessed-path catalog), returning an accepted/rejected candidate tree;
  `sitemap_tree_from_bytes()` classifies an already-fetched document.
- **Network safety** — SSRF guard blocking private, loopback, link-local, and
  cloud-metadata addresses, including NAT64 / IPv4-translated / IPv4-compatible
  IPv6 embedding decoding.

[Unreleased]: https://github.com/bart-turczynski/sitemapr/commits/main
