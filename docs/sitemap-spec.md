# Sitemap domain spec (library-scoped)

The single reference for **what a sitemap is and how `sitemapr` must treat every
part of it**. Where `docs/PRD.md` says *why* we build this and
`docs/architecture.md` says *how the code is layered*, this file says *what the
domain rules are* — the protocol truth, field semantics, extension schemas,
limit model, classification rules, and the validation checks that follow.

It distills three sources, reconciled (see `docs/references.md` for URLs):
1. **sitemaps.org** protocol + FAQ — the baseline of record.
2. **Google** Search Central + **Bing** Webmaster guidance — layered on top as
   warnings/info, never hard errors (except where they restate a protocol limit).
3. The sibling **`sitemap-validator` SPEC.md** — domain logic, stripped of its
   web-service scope.

**Relationship to sibling SPEC numbering.** Section references like *(SPEC §19)*
point at the sibling `sitemap-validator/SPEC.md` so a reader can trace a rule to
its origin. They are citations, not a dependency — this file is now the
authority for the library.

**Cross-references, not duplication.** The A–F layer model lives in
`architecture.md` §3; the XSD/mixed-profile design in `architecture.md` §6; the
findings tibble columns, layer vocabulary, `subject_ref` scheme, and stable code
taxonomy in `docs/findings-contract.md`. This spec references them and adds the
domain rules they assume.

> **Status: accepted.** The open decisions (a–e, §11) were resolved on
> 2026-06-28; ADR-003 §3 and `findings-contract.md` are amended to match. New
> finding codes introduced here are landed in `findings-contract.md` in the same
> change set.

---

## 1. Source types and formats

`sitemapr` accepts and classifies (SPEC §9):

| Form | Notes |
|---|---|
| XML `<urlset>` | Core sitemap; optional extension namespaces (§5) |
| XML `<sitemapindex>` | Index of child sitemaps; expanded per §8 |
| Plain text | One URL per line, UTF-8, no markup; **never parsed as XML** (§7.2) |
| gzip (`.xml.gz`, `.txt.gz`) | Transparently decompressed, then classified by inner bytes |
| local `.tar.gz` archive | Bounded extraction (`architecture.md` §9); members classified individually |

**RSS 2.0 / Atom** are accepted *formats* at the sitemaps.org and Bing level
(Bing accepts XML, RSS 2.0, Atom 0.3 and 1.0, Text). For **v1 they are out of
scope** as parse targets: a sitemap-index child that points at an RSS/Atom feed
is recorded as `UNSUPPORTED_FEED`, not parsed. (Revisit post-v1.)

Classification is by **bytes + structure, never by filename or `Content-Type`
alone** (§7.2, SPEC §11.4). Unsupported inputs yield **typed findings**, never
generic failures (HTML-at-sitemap-URL, malformed gzip, unsupported archive
layout, unsupported root element, unsupported namespace).

---

## 2. Limit model (three axes)

Limits fall on three distinct axes that were previously conflated. Separating
them is the core design decision of this spec. All limits are **configurable**
(args → `getOption("sitemapr.*")`); none is hardcoded (ADR-003 §3).

### Axis 1 — per-resource size

The crucial distinction the sibling SPEC encoded but our early design blurred:
there are **two different 50 MB rules** (SPEC §19 vs §11.3/§28).

| Bound | Value | Kind | On hit |
|---|---|---|---|
| Sitemap / index **uncompressed** size | **50 MB** (52,428,800 bytes) | **soft** — protocol conformance | finding `PROTOCOL_SIZE_EXCEEDED` (`error`); **keep reading** so other findings still surface |
| Per-resource **safety ceiling** (effective decompressed bytes) | **500 MB**, configurable | **hard** — resource safety | finding `FETCH_BODY_CEILING_EXCEEDED` (`fatal`); stop reading this source, return a **partial** result |

Both bounds are measured on **uncompressed/decompressed bytes**, not on-wire
bytes. The 50 MB protocol limit is a property of the *uncompressed* content
(sitemaps.org FAQ: the cap "applies whether compressed or not — measured
uncompressed"), so a small gzip that inflates past 50 MB still violates it. The
500 MB ceiling likewise guards decompressed/effective bytes — the thing that
actually occupies memory and that a gzip bomb inflates.

- The **50 MB uncompressed** rule is the sitemaps.org/Google/Bing protocol limit.
  It is a *property of the content being validated*, so it is a non-fatal Layer D
  **finding**, not a fetch abort. This is the behavior the sibling SPEC §19
  already had.
- The **500 MB ceiling** replaces the sibling SPEC's hard on-wire abort
  (§11.3/§28 "50 MB compressed on-wire" + §11.5 "discard truncated, mark
  failed"). Those carried **abuse-control framing** (§27 archive-bomb defense)
  that, per the threat-model discussion, "largely evaporates for a no-network
  CRAN library": users fetch their *own* sitemaps, so a passive oversize attack
  is a self-inflicted edge case. We therefore keep a *generous* hard ceiling
  purely as a memory backstop and let the protocol finding do the validating.

**Decision (a):** the ceiling is measured on **decompressed/effective bytes**.
This folds the sibling SPEC's split 50-MB-compressed / 200-MB-decompressed pair
into one configurable knob (default 500 MB) on the thing that occupies memory.

**Decision (b):** local `.tar.gz` extraction keeps its own **200 MB** decompressed
cap (`architecture.md` §9), tighter than the 500 MB single-resource ceiling — a
multi-file local archive is a different bomb surface than one fetched body. It is
exposed through the same configurable knob family; the asymmetry is intentional.

### Axis 2 — per-resource counts

All **soft** (protocol/extension conformance findings; reading continues):

| Count | Limit | Source | Finding code |
|---|---|---|---|
| URL entries per sitemap | 50,000 | sitemaps.org / Google / Bing | `PROTOCOL_URL_COUNT_EXCEEDED` |
| Child sitemaps per index | 50,000 | sitemaps.org / Google / Bing | `INDEX_CHILD_COUNT_EXCEEDED` |
| `<loc>` length | < 2,048 chars | sitemaps.org | `PROTOCOL_URL_TOO_LONG` (XML) / `PROTOCOL_TEXT_URL_TOO_LONG` (text) |
| `<image:image>` per `<url>` | 1,000 | Google | `PROTOCOL_IMAGE_COUNT_EXCEEDED` |
| `<news:news>` per file | 1,000 | Google | `PROTOCOL_NEWS_COUNT_EXCEEDED` |
| `<video:tag>` per video | 32 | Google | covered by `PROTOCOL_VIDEO_FIELD_INVALID` |

### Axis 3 — aggregate traversal (documented for v1, not built yet)

When an index is "uncollapsed," the protocol's theoretical maximum is enormous:
50,000 sitemaps × 50,000 URLs = **2.5 billion URLs per index**, and ~2.5 trillion
per domain across multiple indexes (Bing states these figures explicitly). The
per-resource ceiling (Axis 1) must **not** be inflated to this — that would let a
single resource consume the whole corpus.

Instead, aggregate scale is bounded at the **traversal layer** by *streaming*:
child sitemaps are processed one at a time into a running findings accumulator,
never materialized together. On top of that sits a configurable **traversal
budget** (max child sitemaps / max total URLs per call); crossing it yields a
**partial result + finding**, consistent with Axis 1's graceful degradation.

| Bound | Value | Kind |
|---|---|---|
| Sitemap-index recursion depth | 3 | hard — `INDEX_DEPTH_EXCEEDED` |
| Discovery candidates evaluated | 25 | hard — candidate rejected |
| Submitted-list input size | 10 | hard — input-layer cap |
| Aggregate traversal budget (child sitemaps / total URLs) | **documented only for v1** | future |

> The aggregate budget is **documented, not scaffolded**, for v1 — there is no
> traversal code to enforce it in yet. The 2.5 B/2.5 T corpus figure is recorded
> as the known upper bound that will eventually force URL storage to spill to
> disk rather than stay in memory (a later-segment concern).

### Transport limits (not a content axis)

| Limit | Default | Source |
|---|---|---|
| Request timeout | 30 s | ADR-003 |
| Max redirect hops | 5 | ADR-003 / SPEC §11.3 |

SSRF guard runs on the initial URL **and every redirect hop** (ADR-003 §2). A
`data:` or `file:` URI appearing as a `<loc>` is a **protocol-layer finding and
is never fetched** (SPEC §11.2 leaked rule).

---

## 3. XML classification (Layer B)

Root classification happens **before** schema-profile selection (SPEC §13):

- Supported roots: `urlset`, `sitemapindex`. Any other root → `UNSUPPORTED_ROOT`.
- Profile selection considers **both root kind and namespace set** —
  namespace-only matching is insufficient.
- Namespace collection captures: default namespace, prefixed declarations, the
  root-element namespace, and which **supported extension namespaces are present
  vs actually used** (used-prefix scan runs on the parsed tree).
- HTML-at-a-sitemap-URL and unknown formats are decided at Layer B by byte
  sniffing (§1), emitting `UNSUPPORTED_HTML_MASQUERADE` / `UNSUPPORTED_ROOT`.

Encoding-conflict resolution priority (SPEC §11.6), high → low:
**(1) BOM → (2) XML declaration `encoding=` → (3) HTTP `Content-Type` charset →
(4) default UTF-8.** Any two-signal conflict emits `ENCODING_CONFLICT` (`info`)
naming the conflicting signals and the chosen resolution; the **BOM-vs-XML-decl**
pair — and only that pair — elevates to `warning` in strict mode
(`ENCODING_BOM_DECLARATION_CONFLICT`).

---

## 4. Core field semantics

Required vs optional (sitemaps.org):

- **`<urlset>`**: required `<url>` → required `<loc>`; optional `<lastmod>`,
  `<changefreq>`, `<priority>`.
- **`<sitemapindex>`**: required `<sitemap>` → required `<loc>`; optional
  `<lastmod>`.

| Field | Rule | Invalid → |
|---|---|---|
| `<loc>` | Absolute `http`/`https`, host present, < 2,048 chars, RFC-3986/3987, entity-escaped (`& ' " < >`). Same host + same-or-lower directory as the sitemap's own URL (scope). | `PROTOCOL_URL_NOT_ABSOLUTE`, `PROTOCOL_URL_NO_HOST`, `PROTOCOL_URL_OUT_OF_SCOPE`, `PROTOCOL_URL_INVALID_ESCAPE`, `PROTOCOL_URL_TOO_LONG` |
| `<lastmod>` | W3C Datetime (ISO 8601 profile): full `2004-12-23T18:00:15+00:00` or date-only `YYYY-MM-DD`. | `PROTOCOL_LASTMOD_INVALID` (`error`); date-only → `PROTOCOL_LASTMOD_DATE_ONLY` (strict-only `info`) |
| `<changefreq>` | Enum: `always hourly daily weekly monthly yearly never`. | `PROTOCOL_CHANGEFREQ_INVALID` (`error`) |
| `<priority>` | Decimal in **[0.0, 1.0]** inclusive; default 0.5. | `PROTOCOL_PRIORITY_OUT_OF_RANGE` (`error`) |

`read_sitemap()` exposes `lastmod` as real **POSIXct** so callers filter with
dplyr rather than bespoke args (`architecture.md` §7; PRD §4).

### 4.1 `lastmod` quality heuristics (Bing-driven) — corpus-level findings

Bing treats `<lastmod>` as a **key recrawl signal** and **disregards it** when
the dates look dishonest. These are **corpus-level** findings — they require
scanning *all* entries, not one — a category distinct from per-entry checks:

| Heuristic | Severity | Code |
|---|---|---|
| All / a high proportion of `<lastmod>` values identical | `warning` | `PROTOCOL_LASTMOD_ALL_IDENTICAL` |
| `<lastmod>` ≈ sitemap fetch/generation time across URLs | `info` (→ `warning` strict) | `PROTOCOL_LASTMOD_LOOKS_GENERATED` |

Date-only `lastmod` (already `PROTOCOL_LASTMOD_DATE_ONLY`) is reinforced by
Bing's "include date *and* time" recommendation.

### 4.2 Google / Bing divergence (warn, never error)

| Field | sitemaps.org | Google | Bing | `sitemapr` treatment |
|---|---|---|---|---|
| `changefreq` | hint | **ignored** | **ignored** | valid value → no finding; never reward presence/absence; at most `info` that engines ignore it |
| `priority` | hint (intra-site) | **ignored** | **ignored** | same |
| `lastmod` | even approximate helps | used **only if verifiably accurate** | **key signal; disregarded if dishonest** | parse + validate format; quality heuristics §4.1 |

---

## 5. Extensions

Each extension namespace URI is **version-pinned and must match literally** (the
schema-profile cache keys on the exact sorted namespace set — `architecture.md`
§6). Do **not** normalize versions.

| Extension | Namespace URI |
|---|---|
| Image | `http://www.google.com/schemas/sitemap-image/1.1` |
| News | `http://www.google.com/schemas/sitemap-news/0.9` |
| Video | `http://www.google.com/schemas/sitemap-video/1.1` |
| Hreflang | `http://www.w3.org/1999/xhtml` (the `xhtml:link` element) |

**Combining** (Google): declare each as a prefixed `xmlns` on `<urlset>`;
extension blocks nest inside `<url>` after `<loc>`; **order is irrelevant**;
file-size / URL-count limits (§2) still apply.

### 5.1 Image
- `<url>` → `<image:image>` (≤ 1,000 per `<url>`) → required `<image:loc>`.
- `<image:loc>` may be a different host (must be Search-Console-verified +
  robots-crawlable — not something the library can check; informational).

### 5.2 News (recency-sensitive)
- `<url>` → `<news:news>` (≤ 1,000 per file) with required:
  - `<news:publication>` → `<news:name>` + `<news:language>` (ISO 639 2–3 letter;
    exceptions `zh-cn`, `zh-tw`).
  - `<news:publication_date>` (W3C date; date or datetime+TZ forms).
  - `<news:title>` (headline only).
- **Recency window: articles from the last 2 days only** — older entries should
  be dropped. (Time-relative; surface as `info`/`warning`, not a hard error.)
- **Accept-but-ignore** deprecated elements (`news:access`, `news:genres`,
  `news:keywords`, `news:stock_tickers`) rather than reject.

### 5.3 Video
- `<url>` → `<video:video>` (multiple allowed). Required children:
  `<video:thumbnail_loc>`, `<video:title>`, `<video:description>` (≤ 2,048 chars),
  and **at least one of** `<video:content_loc>` / `<video:player_loc>`.
- Bounded optionals: `<video:duration>` integer **1–28800** s; `<video:rating>`
  float **0.0–5.0**; `<video:tag>` ≤ **32** per video; enum-like
  `family_friendly`/`requires_subscription`/`live` ∈ {`yes`,`no`};
  `restriction`/`platform` require a `relationship="allow|deny"` attribute.
- The full video page defines more optional fields (`category`, `gallery_loc`,
  `uploader`, structured `tvshow`/`id`); treat the set above as the common core
  and accept-but-ignore the long tail.
- Concrete violations are reported under `PROTOCOL_VIDEO_FIELD_INVALID`.

### 5.4 Hreflang (`xhtml:link`) — sitemap context only (v1)
Schema layer allows the element + attribute presence + the token *family* via a
custom pattern; the **semantic** layer enforces the rest (SPEC §17.5):

- Element `xhtml:link`; `rel="alternate"`, `hreflang`, `href` all present;
  `href` absolute in strict (relative → `warning`, continue, in non-strict).
- **Token format** (`HREFLANG_FORMAT_INVALID`): accept `lang`, `lang-REGION`,
  `lang-Script`, `lang-Script-REGION`, and `x-default`. Reject empty,
  whitespace-padded, underscore-separated (`en_US`), bad separators (`en--US`),
  region-only (`US`), arbitrary tokens (`english`). Lang = ISO 639-1; region =
  ISO 3166-1 alpha-2.
- **Casing** is meaningful for reporting: lang lowercase, Script Title-case,
  REGION UPPERCASE, `x-default` exactly lowercase. Normalize internally for
  comparison but **preserve and report the original** value; flag deviations.
- **`x-default`** is first-class, recommended, subject to reciprocity; reject
  `X-DEFAULT`/`x_default`/padded; flag duplicate `x-default` in one set.
- **Self-reference + reciprocity** (Google): each `<url>` should list every
  alternate including itself; non-reciprocal annotations are ignored by engines.
  Full cross-URL reciprocity clustering is **v2+**, but the v1 data model must be
  able to support it without migration.
- Within a single `<url>`: report duplicate hreflang→same href, duplicate
  hreflang→different href, multiple `x-default`, missing required attrs.

**Decision (c): canonical hreflang code set — 8 codes, all `layer = "protocol"`.**
The sibling SPEC §17.9 set and the original `findings-contract.md` set were each
missing checks the other had; the canonical set is their superset, because
`XDEFAULT_INVALID` (malformed) and `XDEFAULT_MISSING` (absent) — and the
attribute codes — are genuinely different checks:

| Code | Catches |
|---|---|
| `HREFLANG_FORMAT_INVALID` | token not in the accepted family (empty, region-only `US`, arbitrary `english`) |
| `HREFLANG_SEPARATOR_INVALID` | wrong separator/structure (`en_US`, `en--US`) |
| `HREFLANG_NONSTANDARD_CASE` | casing off (lang not lowercase / Script not Title / REGION not UPPER); value preserved |
| `HREFLANG_DUPLICATE` | same hreflang token repeated within one `<url>` |
| `HREFLANG_XDEFAULT_INVALID` | `x-default` present but malformed (`X-DEFAULT`, `x_default`, padded) or duplicated |
| `HREFLANG_XDEFAULT_MISSING` | `x-default` absent when other alternates are present |
| `HREFLANG_LINK_ATTR_INVALID` | missing/invalid required attribute (`rel` absent or ≠ `alternate`, `hreflang`/`href` absent) |
| `HREFLANG_HREF_RELATIVE` | `href` is relative (strict-only `warning`; non-strict continues) |

The SPEC's `HREFLANG_SCHEMA_INVALID` is **dropped**: schema-layer (XSD)
structural failures of an `xhtml:link` surface under the generic `SCHEMA_INVALID`
code with `layer = "schema"`, preserving the schema-vs-protocol layer split
(`architecture.md` §3; SPEC §17.5). All eight codes above are semantic
(`layer = "protocol"`).

---

## 6. Schema validation (Layer C) — pointer

Real XSD 1.0 validation is mandatory for XML (text uses protocol validation
only). The bundled-catalog + runtime-generated mixed-profile design, the
absolute-path rule, the cache key `(catalog_version, root_kind,
sorted_namespace_set)`, and the XXE-off mandate are specified in
`architecture.md` §6 (and ADR-001 for the no-XSD-1.1 decision). Required initial
assets: core sitemap, sitemap index, image, news, video, hreflang (all six).

`strict` (default) runs XSD and fails on violation, then runs protocol;
`non-strict` parses best-effort, still reports schema violations (downgraded
severity), still runs protocol where safe.

---

## 7. Protocol/semantic validation beyond XSD (Layer D)

Rules XSD 1.0 cannot express (SPEC §19):

1. **Counts/sizes** — Axis 1 & 2 (§2): URL count > 50,000, uncompressed size
   > 50 MB, `<loc>` length, per-extension caps.
2. **Duplicate / equivalent `<loc>`** — a **sitemapr lint**, not a protocol
   rule (sitemaps.org is silent on duplicates and on URL comparison; ADR-005).
   Two tiers by confidence, both `warning`: byte-identical repeats →
   `PROTOCOL_DUPLICATE_LOC`; non-identical raw forms that share the
   RFC-3986/3987-canonical key → `PROTOCOL_URL_EQUIVALENT` (names the resolved
   URL). The
   canonical key is `sitemapr`-owned (assembled from `rurl` components, *not*
   `rurl::clean_url` — `architecture.md` §5).
3. **Field rules** — `lastmod` / `changefreq` / `priority` (§4); must run
   **independently in non-strict** where XSD may not have run.
4. **URL rules** — absolute http/https, host present, scope (same host +
   same-or-lower directory), malformed percent-escapes
   (`PROTOCOL_URL_INVALID_ESCAPE`); `data:`/`file:` `<loc>` never fetched;
   cross-domain host-mismatch detection for both `urlset` and `sitemapindex`
   (SPEC ROADMAP `S05-PROTO-XML`).
5. **URL encoding conformance** — sitemaps.org mandates URLs be "URL-escaped"
   and follow RFC-3986 (URIs) / RFC-3987 (IRIs). A `<loc>` whose canonical form
   differs from its raw bytes → `PROTOCOL_URL_NOT_ESCAPED` (`info` for a valid
   IRI whose URI form crawlers fetch; `warning` for characters illegal in both a
   URI and an IRI). ADR-005.
6. **Document encoding/escaping** — XML entity escaping (Layer C), BOM handling,
   UTF-8 / encoding conflicts (§3).

### 7.2 Text sitemaps (dedicated path, never XML — SPEC §18)
- Non-empty; split on `\n` / `\r\n` / `\r`.
- Each line: a URL, scheme `http`/`https`, parseable, host present, ≤ 2,048 chars.
- Blank lines: silently skipped in non-strict; in **strict** each emits an `info`
  with its (1-based) line number and processing continues.
- Invalid lines reported individually with line number + excerpt **truncated to
  200 chars** (vs 500 for XML evidence — `findings-contract.md`).

---

## 8. Sitemap-index expansion

For `<sitemapindex>` (SPEC §20): validate the index, extract child `<loc>`s,
dedupe children, **detect cycles**, record depth, enforce depth + count caps,
preserve parent→child provenance.

- **Cycle detection** catches self-reference, repeated child in one index, and
  cross-index loops (A→B→A) → `INDEX_CYCLE_DETECTED`.
- **Index nesting** (`sitemapindex` child of a `sitemapindex`) is **forbidden by
  sitemaps.org** (Google silent). On encountering it: emit `SITEMAP_INDEX_NESTED`
  (`warning`) on the child, **still expand** it and enforce caps, and record the
  nesting in provenance. (May become `error` post-v1.)
- Findings on a parent index vs its children stay distinguishable via
  `subject_ref` (`findings-contract.md`).

---

## 9. Discovery (Layer note)

From a bare-domain / site-root entrypoint, candidate order (SPEC §10):
robots.txt `Sitemap:` directives → generic guessed paths → CMS-oriented guesses
→ dedupe + classify. robots.txt `Sitemap:` discovery is **enabled** (ADR-006,
default `use_robots = TRUE`); the guessed-path catalog is also enabled by default
(`use_known_paths = TRUE`). robots *rule application* (`Disallow`/`Allow`)
remains out of scope (ADR-002). Directives take precedence over catalog guesses
on dedupe.

Generic guess catalog (≥): `/sitemap.xml`, `/sitemap_index.xml`,
`/sitemap-index.xml`, `/sitemap.xml.gz`, `/sitemap.txt`, `/sitemap/index.xml`,
`/sitemaps.xml`, `/news-sitemap.xml`, `/sitemap-news.xml`. `/sitemap/` is
**deliberately excluded** from guesses (HTML/redirect noise) but **must** be
attempted if it appears as a robots `Sitemap:` directive.

CMS catalog: only **WordPress** (`/wp-sitemap.xml`) and **Shopify**
(`/sitemap.xml`) are settled (SPEC §31.3 open; ROADMAP confirms these two).

A guessed path returning **404 is a rejected candidate** (reason `not-found`),
**not** a validation error. Discovery distinguishes
submitted / discovered / guessed / accepted / rejected.

---

## 10. Findings taxonomy — delta to `findings-contract.md`

The column contract, layer vocabulary, severities (`fatal`/`error`/`warning`/
`info`), `subject_ref` scheme, strict/non-strict model, determinism guarantee,
and stable-code policy are defined in `docs/findings-contract.md` and are
**authoritative** — this spec does not restate them.

Codes this spec introduces or changes (to be applied in a `findings-contract.md`
amendment alongside the ADR-003 update):

| Code | Layer | Severity | Why new |
|---|---|---|---|
| `PROTOCOL_SIZE_EXCEEDED` | protocol | error | 50 MB uncompressed had no code; the soft half of the two-limit split |
| `FETCH_BODY_CEILING_EXCEEDED` | fetch | fatal | 500 MB safety ceiling; first `FETCH_*` code (none existed) |
| `PROTOCOL_NEWS_COUNT_EXCEEDED` | protocol | error | 1,000 `<news:news>`/file cap |
| `PROTOCOL_URL_TOO_LONG` | protocol | error | 2,048-char `<loc>` in XML (text variant already exists) |
| `PROTOCOL_LASTMOD_ALL_IDENTICAL` | protocol | warning | Bing lastmod-honesty heuristic (corpus-level) |
| `PROTOCOL_LASTMOD_LOOKS_GENERATED` | protocol | info | Bing lastmod-honesty heuristic (corpus-level) |
| `HREFLANG_NONSTANDARD_CASE`, `HREFLANG_XDEFAULT_INVALID`, `HREFLANG_LINK_ATTR_INVALID` | protocol | error/warning | added to the canonical hreflang set (§5.4); `HREFLANG_SCHEMA_INVALID` dropped |

The two `LASTMOD` heuristics introduce a **corpus-level** finding category
(scanning all entries of one sitemap), distinct from per-entry checks — worth a
note in the contract's subject-type discussion (`subject_type = "document"`).

---

## 11. Decisions (resolved 2026-06-28)

| # | Decision | Resolution |
|---|---|---|
| a | Ceiling on decompressed vs on-wire bytes (§2 Axis 1) | **decompressed/effective bytes**; 50 MB protocol limit also measured uncompressed |
| b | Archive decompressed cap vs 500 MB resource ceiling (§2 Axis 1) | **keep archives at 200 MB** (tighter); same configurable knob family; asymmetry intentional |
| c | Hreflang finding-code set (§5.4) | **8-code canonical set**; `HREFLANG_SCHEMA_INVALID` dropped in favor of generic `SCHEMA_INVALID` |
| d | Aggregate traversal budget (§2 Axis 3) | **documented only** for v1; scaffold in the traversal segment |
| e | CMS discovery catalog beyond WP + Shopify (§9) | **WP + Shopify only** for v1; rest tracked as open upstream (SPEC §31.3) |

These are reflected in **ADR-003** (Axis 1 replaces the single "Max on-wire body
50 MB" row + the `sitemapr_truncated` paragraph) and **`findings-contract.md`**
(the §10 codes). The remaining open item is purely upstream: the CMS catalog (e)
is unsettled in the sibling project, not in `sitemapr`.
