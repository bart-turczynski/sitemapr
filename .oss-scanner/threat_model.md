# Threat model

## What this project does and where untrusted input enters
sitemapr is a pure-R package (no `src/`, no native code) that fetches, parses and validates XML,
text, RSS/Atom and index sitemaps against Sitemap Protocol 0.9 and related W3C and RFC standards.
It follows redirects itself, expands sitemap indexes, discovers sitemaps from `robots.txt` and a
catalog of guessed paths, and can optionally fetch the pages a sitemap lists. URL parsing is
delegated to `rurl`; HTTP to `httr2`/`curl`; XML, HTML and XSD to `xml2`/libxml2.

Untrusted input:
- **Every byte fetched over the network**: sitemap, index and feed bodies (plain or gzip), the
  `Location` header of each redirect, `Content-Type`, `robots.txt` bodies (their `Sitemap:` lines
  become fetch targets), and page HTML when page inspection is on.
- **URLs taken from that content**: index child `<loc>` values, `robots.txt` `Sitemap:` lines,
  redirect targets and page URLs. Each is fetched without the caller seeing it first.
- **The contents of local files** passed to the readers (`.xml`, `.txt`, `.gz`, `.tar.gz`), and
  raw bytes passed to `sitemap_tree_from_bytes()`.
- **The URL string `x` itself**: callers may pass a URL a third party chose, so the structural SSRF
  guard runs on it as well as on every later hop.

Entry points: `read_sitemap()`, `read_sitemaps()`, `sitemap_tree()`, `sitemap_tree_from_bytes()`,
`validate_sitemap()`, `validate_sitemaps()`, `validate_sitemap_robots()`,
`validate_sitemap_ruleset()`, `audit_sitemap()`, `report_sitemap()`, `probe_url()`.

Trusted: the calling R code and every option it sets (`fetch_limits()`, `index_limits()`,
`discovery_limits()`, the `sitemapr.*` options, a `request_policy()` with its headers, auth,
proxy, TLS options and `prepare` hook); a local path the caller names in `x`; and the package's
bundled data (`inst/schemas/`, `inst/findings-registry.csv`).

## Components that matter most / least
Most important:
- `R/ssrf.R`: the structural SSRF guard. Scheme gate (http/https only), IPv4 CIDR table,
  numeric/hex/octal literal rejection on the raw host, IPv6 expansion and every IPv6-to-IPv4
  embedding decoder (mapped, translated, compatible, NAT64, 6to4, Teredo, ISATAP), the metadata
  hostnames, and `ssrf_raw_host_of()`, which recovers the raw host from the URL string.
- `R/fetch.R`: manual redirect following (`fetch_follow()`, `fetch_batch_follow()`,
  `page_fetch_follow()`), the per-hop guard call `fetch_hop_ssrf_guard()`, the https-to-http
  fallback in `fetch_connection_failure()`, the body ceiling `read_capped_body()`, and the order
  in which caller policy and sitemapr's own transport controls are applied in
  `fetch_build_request()`.
- `R/url.R` (`parse_url_adapter()`): the guard trusts the host this returns. A host read
  differently here than by libcurl is a guard bypass.
- `R/decompress.R` (streamed gzip inflate under a ceiling, trailer and CRC checks) and
  `R/parse-archive.R` (in-memory tar reader, member-name rejection, archive limits).
- `R/parse-xml.R`, `R/parse-feed.R`, `R/schema-validate.R`, `R/schema-profile.R`: libxml2 is
  called with default options so external entities and DTDs are not loaded; the schema step
  writes wrapper XSDs to `tempdir()` that import bundled schemas by absolute path.
- `R/index-expansion.R`, `R/discovery.R`, `R/robots.R`, `R/page-*.R`: everything that turns
  fetched content into further requests, and the depth, count and budget caps on them.

Less important, still in scope: the text parser (`R/parse-text.R`), the sniffer (`R/sniff.R`), the
validators (`R/protocol-validate.R`, `R/validate-sitemap.R`, hreflang), and the HTML report
(`R/report.R`), which renders sitemap content into a self-contained HTML file.

Out of scope: `httr2`, `curl`, `xml2`, libxml2, zlib, `rurl` and `robotstxtr`, unless sitemapr
calls them unsafely (for example passes a libxml2 option that loads external entities, or trusts
a field `rurl` documents as unreliable). `tools/`, `scripts/`, `data-raw/`, `docs/` and the tests
are out of scope.

The SSRF matcher in `R/ssrf.R` duplicates the guards in the sibling packages `ssrfr` and
`robotstxtr`, kept in sync by hand. A bypass found here probably applies there too; say so in the
report.

## How to exercise it
- The image has the source at `/src`, the package installed, all Imports and Suggests installed
  (including `robotstxtr` from its GitLab tag), and no network.
- Full suite: `Rscript -e 'testthat::test_local("/src")'`. One area:
  `Rscript -e 'testthat::test_local("/src", filter = "ssrf")'` (also `fetch`, `decompress`,
  `parse-archive`, `parse-xml`, `index-expansion`, `page-fetch`).
- No native code, so `R -d gdb` or `R -d valgrind` are only useful to pin down a crash inside
  libxml2 or zlib reached through sitemapr.
- The guard without a network:
  `Rscript -e 'library(sitemapr); str(sitemapr:::ssrf_check_parsed(sitemapr:::parse_url_adapter("http://[::ffff:7f00:1]/")))'`.
  A blocked URL passed to a public reader aborts with class `sitemapr_ssrf_blocked` before any
  request: `read_sitemap("http://169.254.169.254/latest/")`.
- Redirects and responses offline: the tests mock HTTP with `httr2::local_mocked_responses()`
  (see `tests/testthat/test-fetch.R` and `test-page-fetch.R`). A mocked 3xx with a `Location`
  header drives the manual redirect loop and the per-hop guard.
- Parsers on raw bytes: `sitemapr:::parse_sitemap_xml(bytes)`, `sitemapr:::parse_feed(bytes)`,
  `sitemapr:::parse_sitemap_text(bytes)`, `sitemapr:::gzip_decompress(bytes, max_bytes = 1e6)`,
  `sitemapr:::parse_sitemap_archive("/tmp/x.tar.gz")`, and the public
  `sitemap_tree_from_bytes(bytes, source_url = "https://example.com/sitemap.xml")`.
- Fixtures: `tests/testthat/fixtures/` (`xxe-attempt.xml`, `index-cycle-ab.xml`,
  `index-over-cap.xml`, `index-deep.xml`, `html-masquerade.html`, ...) and the byte-sensitive
  corpus in `tests/testthat/fixtures/corpus/` (`compressed/`, `encoding/`, `xml/`, `text/`,
  `hreflang/`). Cucumber scenarios are the `.feature` files in `tests/testthat/`.

## How you rate severity
There is no native code in this package, so memory-corruption findings apply only where sitemapr's
use of a dependency makes them reachable.
- **Critical**: an SSRF-guard bypass under the default policy (`ssrf_guard = TRUE`) that reaches
  loopback (`127.0.0.0/8`, `::1`) or a cloud-metadata endpoint (`169.254.169.254`,
  `metadata.google.internal`, `fd00:ec2::254`), whether through `x`, a redirect, an index child, a
  `robots.txt` `Sitemap:` line, a discovery guess or a page URL; a URL taken from fetched content
  that makes sitemapr read a local file or use a scheme other than http or https; memory
  corruption in libxml2 or zlib that sitemapr makes reachable from untrusted bytes.
- **High**: a guard bypass to any other blocked range (RFC 1918, link-local, `100.64.0.0/10`,
  `0.0.0.0/8`, any IPv6 form that embeds one, an obfuscated numeric literal); a hop that reaches
  the network without passing the guard first; a host that `parse_url_adapter()` or
  `ssrf_raw_host_of()` reads differently from the host libcurl connects to; XXE, DTD or
  external-entity loading, or an XSD import, include or `schemaLocation` taken from the document
  that reaches the filesystem or network; a tar member written outside memory or to disk.
- **Medium**: denial of service from a small input: a gzip or archive inflating past its ceiling
  (`sitemapr.max_decompressed`, `archive_limits()`), index expansion escaping its depth, child or
  total budgets or looping on a cycle, unbounded CPU or memory in a parser or validator
  (catastrophic regex backtracking, quadratic work on a large urlset, an infinite loop in a
  decoder), a crash of the R process (a segfault, not an R error); script injection into the
  HTML that `report_sitemap()` writes, from sitemap content.
- **Low**: wrong rows or findings with no security consequence, including standards
  nonconformance; anything that needs the caller to misuse a documented API, raise a limit, or
  pass a hostile `request_policy()` or option.

## Anything to leave alone
- Classed R errors on invalid input (`sitemapr_xml_parse_error`, `sitemapr_decompression_error`,
  `sitemapr_malformed_archive`, `sitemapr_ssrf_blocked`, `sitemapr_body_ceiling`, ...). An R
  error is the designed outcome, not a crash.
- The documented opt-out `ssrf_guard = FALSE` (`probe_url()` and the internal fetchers), and any
  behavior reachable only with it set.
- Raised limits. Every bound is caller-overridable by design, with no hard floor (ADR-003 §3):
  `fetch_limits(timeout, max_redirects, max_bytes)` and `sitemapr.timeout`,
  `sitemapr.max_redirects`, `sitemapr.max_bytes`; `index_limits()` and
  `sitemapr.max_index_depth`, `sitemapr.max_index_children`, `sitemapr.max_total_sitemaps`,
  `sitemapr.max_total_urls`; `discovery_limits()` and `sitemapr.max_candidates`;
  `sitemapr.max_decompressed`; `sitemapr.archive.max_bytes`, `sitemapr.archive.max_files`,
  `sitemapr.archive.max_decompressed`; the page-inspection `page_budget`;
  `sitemapr.max_findings_per_code = Inf`.
- Hostnames that resolve to private addresses, DNS rebinding, and deployment-specific NAT64
  prefixes: the guard is structural only and never resolves names (ADR-003 §1).
- The fetch is buffered: httr2 reads the whole response before the 500 MB per-resource ceiling
  is checked (ADR-003 §3). Report a body that gets past the ceiling, not the buffering itself.
- A local path or `file://` URL that the caller names in `x` is read as a local file, by design.
- An inferred `https://` for a bare host falls back to `http://` on a connection failure. That
  is the documented entry-point policy.
- The `sitemapr.completion_order` and `sitemapr.inflight_probe` options are test seams.
- Outdated dependencies with no exploit path through sitemapr.

Patches: minimal R fixes in the package's style (air-formatted, 80 columns, classed `rlang`
conditions). Add a `testthat` regression test next to the existing tests for that area (for
example `tests/testthat/test-ssrf.R`, `test-fetch.R`, `test-decompress.R`). Add a `NEWS.md` entry
under the development version, citing the standard and clause when the fix is a conformance
fix.
