# Sitemap references

Canonical external sources that govern `sitemapr`'s domain behavior. The rules
themselves are distilled into `docs/sitemap-spec.md`; this file records *where
each rule comes from* so a reader can verify or re-derive any decision.

When two sources disagree, `docs/sitemap-spec.md` records the divergence and the
chosen behavior. The baseline of record is **sitemaps.org**; Google and Bing
guidance layers on top and is encoded as warnings/info, never as hard errors,
except where it merely restates a protocol limit. This describes the **§1–§11
baseline**; the per-engine rulesets in `docs/sitemap-spec.md` **§12** (governed by
`ADR-009`) add **Yandex** and may carry opt-in engine-specific *validity* rules
under an explicitly selected `sitemap_ruleset`.

---

## Protocol baseline

| Source | URL | Governs |
|---|---|---|
| Sitemaps.org protocol | https://www.sitemaps.org/protocol.html | Core XML/text/index format, required vs optional elements, field semantics, 50,000 / 50 MB / `<loc>` length limits, scope rules, index-nesting prohibition |
| Sitemaps.org FAQ | https://www.sitemaps.org/faq.html | Clarifications: uncompressed-size measurement, lastmod-approximation guidance, scope examples |

## Google Search Central

| Source | URL | Governs |
|---|---|---|
| Build & submit a sitemap | https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap | Accepted formats, absolute-URL requirement, "Google ignores `<changefreq>`/`<priority>`", lastmod-only-if-verifiably-accurate, directory-scope behavior |
| Large sitemaps & indexes | https://developers.google.com/search/docs/crawling-indexing/sitemaps/large-sitemaps | 50,000 `<loc>` per index, index same-site/same-or-lower-dir scope, GSC 500-index-files-per-site operational cap |
| Image sitemaps | https://developers.google.com/search/docs/crawling-indexing/sitemaps/image-sitemaps | `image` namespace (`/1.1`), `<image:image>`/`<image:loc>`, ≤ 1,000 images per `<url>` |
| News sitemaps | https://developers.google.com/search/docs/crawling-indexing/sitemaps/news-sitemap | `news` namespace (`/0.9`), required `<news:news>` subtree, 2-day recency window, ≤ 1,000 `<news:news>` per file |
| Video sitemaps | https://developers.google.com/search/docs/crawling-indexing/sitemaps/video-sitemaps | `video` namespace (`/1.1`), required/optional children, `duration` 1–28800, `rating` 0.0–5.0, ≤ 32 `<video:tag>` |
| Combine extensions | https://developers.google.com/search/docs/crawling-indexing/sitemaps/combine-sitemap-extensions | Declaring multiple namespaces on one `<urlset>`; extension order after `<loc>` irrelevant |
| Localized versions (hreflang) | https://developers.google.com/search/docs/specialty/international/localized-versions#sitemap | `xhtml:link rel="alternate" hreflang=…`, self-reference, reciprocity-or-ignored, `x-default`, hreflang token format |
| GSC Sitemaps report | https://support.google.com/webmasters/answer/7451001 | Search Console submission model; documented sitemap fetch-error categories (404/4xx, HTTP error) — **not** an exhaustive per-status acceptance table (§12.4) |
| Sitemaps `lastmod` ping deprecation (Jun 2023) | https://developers.google.com/search/blog/2023/06/sitemaps-lastmod-ping | Google deprecated the anonymous sitemap-ping endpoint; the sitemaps.org "HTTP 200" ping acknowledgement is no longer current Google behavior (§12.4) |

## Bing

| Source | URL | Governs |
|---|---|---|
| Bing Webmaster — Sitemaps help | https://www.bing.com/webmasters/help/Sitemaps-3b5cf6ed | Accepted formats (XML, RSS 2.0, Atom 0.3 **and** 1.0, Text), robots.txt `Sitemap:` discovery. (Page is a JS SPA; content captured from user-supplied markdown.) |
| Bing blog — sitemaps in AI-powered search (Jul 2025) | https://blogs.bing.com/webmaster/July-2025/Keeping-Content-Discoverable-with-Sitemaps-in-AI-Powered-Search | **Bing uses `<lastmod>` as a key recrawl signal**; ignores `changefreq`/`priority`; freshness matters more under AI search; ISO 8601 with date+time recommended |
| Bing blog — importance of lastmod (Feb 2023) | https://blogs.bing.com/webmaster/february-2023/The-Importance-of-Setting-the-lastmod-Tag-in-Your-Sitemap | Normative source on lastmod honesty: Bing **disregards** lastmod if dates look dishonest (all set to current/generation date); consequences of inaccurate lastmod |
| Bing blog — 50 MB size increase (Nov 2016) | https://blogs.bing.com/webmaster/November-2016/Increasing-the-size-limit-of-Sitemaps-file-to-addr | Current Bing uncompressed size limit = **52,428,800 bytes** (50 MB), superseding the 2008 10 MB value (§12.6) |
| Bing blog — anonymous submission removed (May 2022) | https://blogs.bing.com/webmaster/may-2022/Spring-cleaning-Removed-Bing-anonymous-sitemap-submission | Bing removed anonymous sitemap submission; the sitemaps.org anonymous-ping mechanism is no longer current Bing behavior (§12.4) |
| Bing blog — cross-domain Sitemaps (Feb 2008) — **historical/obsolete** | https://blogs.bing.com/webmaster/February-2008/Microsoft-to-support-cross-domain-Sitemaps | **Superseded.** Source of the obsolete 10 MB limit and the 2008 robots.txt cross-domain trust workflow; retained only to label those as historical — must **not** enter the `bing` ruleset (§12.6) |

## Yandex (per-engine ruleset — `docs/sitemap-spec.md` §12)

| Source | URL | Governs |
|---|---|---|
| Yandex Webmaster — Sitemap file requirements & formats | https://yandex.com/support/webmaster/en/controlling-robot/sitemap | Supported formats (XML + TXT; **RSS/Atom not supported**), UTF-8, 50,000 links, 50 MB uncompressed, 50,000 index children, URL-length statement (2,048 = 1,024 domain + 1,024 path), `priority` load-order |
| Yandex Webmaster — Sitemap error dictionary | https://yandex.com/support/webmaster/en/error-dictionary/sitemap | "Incorrect page address" / "URL length exceeds the limit (1024 characters)"; "Data limit exceeded in tag X"; BOM / "Unknown tag" warnings; invalid optional-metadata warnings; "Incorrect URL (doesn't match the Sitemap file location)" |
| Yandex Webmaster — Download/submit the Sitemap | https://yandex.com/support/webmaster/en/indexing-options/sitemap | Submission is bound to a selected verified site; exactly `200 OK` required for retrieval; redirect surfaced as a condition to remove |
| Yandex sitemap file-analysis tool *(tester surface)* | https://webmaster.yandex.com/tools/sitemap/ | Empirical resolution of the §12.5/§12.7 tester-grounded cells — entered as `application_choice`/`advisory`/`inherited_protocol`, never `documented` (§12.0 prohibits a `documented (tester)` tag): decoded ~1,024 hard cap; ~1,200–1,500 raw soft guard; BOM optional; raw IRI/IDN accepted; nonfatal invalid metadata. Login-gated, no stable transcript — durable evidence is the reproducible probe corpus (§12.0 caveat). Production deltas tracked in `SITE-jufaqaql` |

## Sibling project (port source of record)

| Artifact | Location | Governs |
|---|---|---|
| `sitemap-validator` SPEC.md | GitHub `bart-turczynski/sitemap-validator` `SPEC.md` (33 sections) | The TypeScript reference engine's full spec. `sitemapr` ports its **domain logic** (validation layers, classification, schema/mixed-profile model, hreflang rules, protocol checks, index expansion, findings model, operational limits). Web-service sections (jobs, storage, reports, submission API, robots HTTP service, rate-limiting) are **out of scope** for the library. |
| `sitemap-validator` ROADMAP.md | GitHub `bart-turczynski/sitemap-validator` `ROADMAP.md` | Story-level build order; confirms WordPress + Shopify as the only settled CMS discovery catalogs; names finding-code conventions |

Provenance note: everything copied into `inst/` (XSD schemas, fixtures) inherits
its license from sitemaps.org / the `sitemap-validator` repo and needs an
`inst/schemas/LICENSE` (or `inst/COPYRIGHTS`) before CRAN submission — see
`docs/PRD.md` §6.
