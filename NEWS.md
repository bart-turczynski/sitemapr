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
* `max_active` opts into bounded-concurrency index expansion in `read_sitemap()`,
  `audit_sitemap()`, and `sitemap_tree()`: up to that many child sitemaps are
  fetched at once while the per-host pace is respected. It is a scheduling
  optimization only — the rows, findings, tree, and budget-truncation point are
  byte-identical to the sequential default (ADR-008).
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
* Whole-sitemap hreflang cluster findings surface across the corpus: a missing
  self-referencing alternate, a non-reciprocal return link, and inconsistent
  language annotations for the same target URL.
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

## Resource bounds

* The traversal-wide aggregate budgets in `index_limits()` are now **finite by
  default**: `max_total_sitemaps` is 50 000 (was `Inf`) and `max_total_urls` is
  25 000 000 (was `Inf`). Only `max_depth` and the per-index `max_children` were
  bounded before, so a pathological index graph could drive an unbounded
  traversal in an embedding caller. Both ceilings sit above what a traversal of
  protocol-legal sitemaps reaches in practice, and reaching one stops the
  traversal and returns the accumulated partial result with an
  `INDEX_TOTAL_SITEMAPS_EXCEEDED` / `INDEX_TOTAL_URLS_EXCEEDED` finding. Pass
  `Inf` explicitly, or set `options(sitemapr.max_total_sitemaps = Inf)`, to keep
  the previous unbounded behavior.
* Each finding code now contributes at most 100 individual rows to an assembled
  report; the remainder are accounted for in a single report-scoped
  `REPORT_TRUNCATED` row naming each capped code and its omitted count. A
  blanket `Disallow: /` over a 50 000-URL sitemap previously produced 50 000
  near-identical `ROBOTS_DISALLOWED` rows. Configure with
  `options(sitemapr.max_findings_per_code = )`; `Inf` opts out.
* Robots findings are built in one vectorized pass instead of one tibble per
  URL, which dominated the cost of a high-cardinality robots result.

## Per-engine rulesets

* `validate_sitemap_ruleset()` and `validate_sitemaps_ruleset()` validate a
  sitemap under a named search engine's rules instead of the sitemaps.org
  baseline, via a `sitemap_ruleset` argument. `sitemap_rulesets()` enumerates
  the selectable values (`"sitemaps.org"`, `"google"`, `"bing"`, `"yandex"`).
  Selecting an engine is always explicit — nothing falls through to an overlay,
  and the default stays `"sitemaps.org"` (ADR-009).
* The result gains four **additive** columns under an engine ruleset:
  `ruleset`, `ruleset_revision`, `context`, and `provenance`. A baseline call
  returns exactly the pinned ten-column schema v1, byte-for-byte unchanged, so
  existing callers see nothing new.
* `provenance` records how each rule's authority was established and, crucially,
  whether the finding may be a hard verdict: `documented`,
  `inherited_protocol` and `application_choice` are executable, while
  `inferred`, `documentation_gap`, `documentation_conflict` and `advisory` are
  diagnostic and never produce an engine-specific validity failure. One fact,
  one tag.
* `ruleset_context()` and `ruleset_context_for_child()` build the independent
  context axes a finding is evaluated under (`submission_channel`,
  `discovery_provenance`, `property_scope`, and structured
  `authority_evidence`). Context is per source: a sitemap-index child inherits
  nothing implicitly.
* `ruleset_revision()` returns a ruleset's published revision string, so a
  cross-repo consumer can pin against a known version of the rules.
* Three engine-specific finding codes ship with the surface, all Yandex and all
  emitted only under that overlay: `PROTOCOL_URL_DECODED_TOO_LONG` (the decoded
  whole-URL length limit, distinct from the 2 048-character raw
  `PROTOCOL_URL_TOO_LONG`), `PROTOCOL_TAG_DATA_LIMIT_EXCEEDED` (the per-tag byte
  guard, distinct from the whole-file `PROTOCOL_SIZE_EXCEEDED`), and
  `ENGINE_UNSUPPORTED_SITEMAP_FORMAT` (a format sitemapr parses but the selected
  engine does not accept). Every other code applies under every ruleset by
  inheritance.

## Reporting

* `report_sitemap()` now renders four per-finding columns it previously
  computed and dropped: the producer's `remediation_hint` (as a "Fix" line —
  the robots-by-`noindex` trap synthesis exists to produce these), the
  `context` payload (as a collapsible block), and the `ruleset` /
  `ruleset_revision` and `provenance` of a finding produced under an engine
  overlay (as badges). Executable and diagnostic provenance are visually
  distinct, so a `documentation_gap` or `advisory` finding cannot read as a
  hard verdict (ADR-009). Baseline runs carry none of the additive columns and
  render exactly as before.

## Network safety

* SSRF guard blocks requests to private, loopback, link-local, and
  cloud-metadata addresses, including decoding of NAT64, IPv4-translated, and
  IPv4-compatible IPv6 embeddings.
* The guard also decodes the three IPv6 transition mechanisms — 6to4
  (`2002::/16`), Teredo (`2001::/32`, whose embedded IPv4 is XOR-obfuscated),
  and ISATAP (a `*:5efe` marker under any prefix) — and classifies the IPv4
  address each one wraps. All three pack that address outside the low 32 bits,
  so the previous decoders missed them and, for example,
  `2002:a9fe:a9fe::` (6to4-wrapped `169.254.169.254`) was allowed. A wrapped
  *public* address still passes: these prefixes are globally reachable, so only
  what they carry decides the outcome.
* An IPv6 literal that cannot be expanded to exactly 8 hextets (`fe80:::1`,
  `::12345`) is now refused with the reason `malformed-address` instead of
  reaching the default allow. Such literals never survived URL parsing, so no
  reachable fetch changes; the guard simply no longer depends on the parser
  rejecting them first.
* The guard classifies the IPv6 unspecified and loopback addresses on the
  expanded address rather than the literal string, so every spelling of those
  128 bits is treated alike: `0::1`, `::0:1`, `0:0:0:0:0:0:0:1` and
  `::0.0.0.1` are all recognised as loopback, and the matching forms of `::`
  as unspecified. Previously only the exact literals `::1` and `::` matched,
  and every other spelling was classified as neither special nor embedded
  IPv4 and reached the default allow. Fetches were not affected, because
  `rurl` canonicalises such literals before the guard sees them; the guard is
  now correct on its own rather than relying on that (SITE-vovtwvuh).
* The guard's IPv6 link-local and AWS cloud-metadata rules now match on the
  expanded address too, completing the change above. Because a hextet may be
  written with leading zeros, matching the literal string mis-decided both
  rules: `fd00:0ec2::254` was allowed through while the identical
  `fd00:ec2::254` was blocked, and addresses such as `fe8::` were reported as
  link-local despite lying far outside `fe80::/10`. Both are now decided by
  value — `fe80::/10` and `fd00:ec2::/32` — so every spelling agrees, matching
  the ADR-003 §1 matrix (SITE-mhfmtdxa).

## Request customization

* `request_policy()` configures the HTTP requests sitemapr issues on every hop
  and is accepted by every reading, validation, and discovery entry point via
  the `policy` argument. Configure custom headers, authentication
  (`request_auth_basic()` / `request_auth_bearer()`), a proxy (`request_proxy()`),
  TLS options, bounded retry with backoff (`request_retry()`), and host-aware
  throttling (`request_throttle()`).
* Safety controls are never overridable: the per-hop SSRF guard, redirect
  control, and non-2xx error policy are re-asserted after all caller
  customization, so a policy can add headers or auth but cannot re-enable
  redirect following or defeat the SSRF re-check.
