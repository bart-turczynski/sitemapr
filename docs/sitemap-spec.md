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

This framing describes the **§1–§11 baseline**. **§12** extends it under
`docs/decisions/ADR-009-per-engine-validation-profiles.md` with opt-in per-engine
rulesets (adding **Yandex**, plus per-cell provenance) that, under an explicitly
selected `sitemap_ruleset`, may carry engine-specific *validity* rules — not only
warnings/info.

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
(Bing accepts XML, RSS 2.0, Atom 0.3 and 1.0, Text). They ARE parsed: a feed
(RSS 2.0 / Atom 0.3 / Atom 1.0) is read into the faithful row schema, one row
per item/entry, both as a top-level source and as a sitemap-index child. Only an
UNRECOGNISED feed dialect (a `<feed>` in a non-Atom namespace) is recorded as
`UNSUPPORTED_FEED`, not parsed.

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
extension blocks nest inside `<url>` after `<loc>`; **order among the sibling
extension blocks is irrelevant** (a `<video:video>` may precede an
`<image:image>`, etc.); file-size / URL-count limits (§2) still apply. This does
**not** relax child order *inside* an extension block — see §5.1.

### 5.1 Image
- `<url>` → `<image:image>` (≤ 1,000 per `<url>`) → required `<image:loc>`.
- `<image:loc>` may be a different host (must be Search-Console-verified +
  robots-crawlable — not something the library can check; informational).
- **Child order is significant.** Google's canonical image XSD models
  `<image:image>` as an `xsd:sequence` — `loc → caption → geo_location → title →
  license` — so a document that reorders the optional children (e.g. `<title>`
  before `<caption>`) is `SCHEMA_INVALID`, even though every element name is
  legal. Verified against the live upstream schema
  (`https://www.google.com/schemas/sitemap-image/1.1/sitemap-image.xsd`) by the
  parity oracle (`data-raw/schemas/check-parity.R`).
  - **Cross-port divergence (SITE-ibeevjwt):** sitemap-validator's imported
    `corpus/xml/valid-image.xml` fixture orders `<title>` before `<caption>` and
    its port accepts it. Per Google's canonical `sequence` that ordering is
    invalid, so **sitemapr is canonical**: it classifies the fixture
    `SCHEMA_INVALID`, and the shared golden (`corpus-golden.tsv`) records that.
    The validator port and its (misnamed) fixture are the stale side and should
    be aligned there; sitemapr's schema is unchanged.

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
| `HREFLANG_XDEFAULT_INVALID`, `HREFLANG_LINK_ATTR_INVALID` | protocol | error | added to the canonical hreflang set (§5.4); `HREFLANG_SCHEMA_INVALID` dropped |
| `HREFLANG_NONSTANDARD_CASE` | protocol | info | off-canonical casing (BCP 47 §2.1.1: tags are case-insensitive → advisory, not a conformance failure) |

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

---

## 12. Per-engine sitemap rulesets (ADR-009 extension)

> **Status: extension — 2026-07-16, governed by
> `docs/decisions/ADR-009-per-engine-validation-profiles.md`.** §1–§11 (accepted
> 2026-06-28) are the baseline of record and are **unchanged**. This section is
> **additive**: it layers per-engine rules on top of them in ADR-009's
> vocabulary and does not restate baseline mechanics. Primary-source URLs are
> cited inline. Most durable `docs/references.md` rows already exist (Google
> build-sitemap / large-sitemaps; Bing Jul-2025 post); the rows still to be added
> in the follow-up references slice are the **Yandex** Webmaster sitemap +
> error-dictionary + download pages, the **Bing 2016** size announcement, the
> **GSC sitemap report** page, and the anonymous-ping deprecation notes (Google
> 2023, Bing 2022). Finding-registry changes land in the follow-up findings
> slice, not here.

### 12.0 Scope, vocabulary, and provenance

Validation context is a set of **independent axes** (ADR-009 §1), not one
`profile` scalar — and `profile` stays reserved for the XSD schema-profile sense
(§3, §5, §6). The engine axis is **`sitemap_ruleset`**: baseline `sitemaps.org`
plus the overlays `google`, `bing`, `yandex`. `sitemapr` owns this value set; it
is extensible.

Every rule cell below carries exactly **one** provenance tag (ADR-009 §0):

- **Executable** — may drive a per-engine verdict: `documented` (quoted from the
  engine's current primary source), `inherited_protocol` (explicitly inherited
  from the sitemaps.org baseline in §1–§8), `application_choice` (a named
  `sitemapr` product decision).
- **Diagnostic only** — softens/annotates, **never** a verdict: `inferred`,
  `documentation_gap`, `documentation_conflict`, `advisory`.

A diagnostic-tagged cell MUST NOT produce a hard validity failure under its
ruleset; at most it yields a softened finding. The baseline protocol checks
(§1–§8) are the executable substrate: an overlay either inherits a rule
(`inherited_protocol`), overrides it with the engine's own current rule
(`documented`), or applies a named product decision (`application_choice`).

**Atomicity (one fact, one tag).** Each provenance cell carries **exactly one**
tag for **one atomic fact**. A rule that decomposes into several facts (e.g. a
*documented* fetch-error category plus an *absent* per-status table) is split so
each fact is stated separately with its own single tag; the enforced/executable
fact is the cell's tag, and any accompanying gap/deprecation is stated as prose
context or in the post-table notes, never as a second provenance tag competing in
the same cell.

**Tester provenance is not `documented`.** ADR-009's source-precedence rule says
*current* guidance supersedes *historical* guidance; it does **not** say empirical
tester behavior supersedes current documentation or counts as `documented`
(`documented` = quoted from primary documentation, and **there is no eighth
`documented (tester)` tag**). Where the Yandex file-analysis tool is the evidence,
the atomic claims are tagged thus:

- an officially stated Yandex fact → `documented`;
- a baseline behavior the tester merely confirms (BOM, raw IRI/IDN, date-only
  `lastmod`) → `inherited_protocol`;
- a chosen executable interpretation the probe resolved but the docs do not state
  atomically (decoded length, whole-URL vs path, treating ~1,024 as operative over
  the requirements-page 2,048) → **`application_choice`** (the ADR-legal way to make
  tester-grounded evidence executable);
- a purely tool-observed, non-normative behavior (the soft raw-byte guard, the
  ~100 B optional-element guard) → `advisory` (diagnostic, never a hard verdict).

**Source precedence** (ADR-009 §0): current guidance supersedes historical;
historical values (Bing 2008 10 MB, 2009 XML-only) support only historical
claims, never a current cell. **`mode`** (strict/non-strict) affects
presentation, severity, and filtering only — never facts, validity, ruleset
selection, or scope verdicts (ADR-009 §1).

**Empirical-provenance caveat.** Some Yandex cells are informed by the Yandex
sitemap file-analysis tool (`https://webmaster.yandex.com/tools/sitemap/`). It is
an authoritative Yandex surface but **not** guaranteed identical to the production
crawler, and — per the tester-provenance rule above — it does **not** make a cell
`documented`. Tool evidence enters the tables only as an `application_choice`
(executable) or `advisory` (diagnostic), never as a verdict quoted from docs; such
cells are marked *(tester-grounded)*, and a production-verification backlog exists
(`SITE-jufaqaql`). Fetch/crawl-time behavior (§12.4, crawl-order effects in §12.7)
is production-only and is never asserted from the tester. The tool UI needs a login
and preserves no stable, quotable transcript, so the durable citation is the
reproducible probe corpus + observations to be recorded in the follow-up references
slice, not the tool URL alone.

### 12.1 Per-source context and authority

ADR-009 §1 owns these four **per-source** axes; `sitemapr` owns their (extensible)
value sets:

- **`submission_channel`** — how the artifact was submitted:
  `search_console_api` | `webmaster_tools` | `user` | `import` | `absent` (a child
  that inherits no submission facts — see the per-source invariant below).
  **`discovered` is not a submission value.**
- **`discovery_provenance`** — how it was found: `organic` |
  `robots_txt_reference` | `supplied` | `guessed_path` | `index_child` |
  `archive_derived`. A robots.txt reference *used as cross-site trust* is distinct
  from robots.txt *discovery*. This set reconciles with the existing source
  vocabularies in `architecture.md` — `source_sitemap` (`submitted-directly`,
  `submitted-list`, `guessed-path`, `child-of-index`, `extracted-archive`) and the
  `sitemap_tree()` `provenance` column (`guessed-path`, `robots`, `seed`,
  `child-of-index`): `supplied`≈`seed`/`submitted-*`, `robots_txt_reference`≈`robots`,
  `guessed_path`≈`guessed-path`, `index_child`≈`child-of-index`,
  `archive_derived`≈`extracted-archive`.
- **`property_scope`** — the verified property/site a submission is bound to; it
  does not by itself grant authority beyond that property.
- **`authority_evidence`** — **structured, never boolean**:
  `verified_property_set` | `target_host_robots_reference` | `same_location_default`
  | `absent` | `conflicting`.

**Per-source invariant (ADR-009 §1): a sitemap-index child inherits nothing
implicitly.** Explicit rules:

- *Scope* — a child's own `<loc>` host+path establishes its scope (§12.2); it is
  not inherited from the parent index.
- *Authority* — a child's authority is established **only by that child's own
  evidence**: its own verified property (`verified_property_set`), its own
  target-host robots.txt reference (`target_host_robots_reference`), or a
  same-location default (`same_location_default` — the child's own `<loc>`
  co-located with the robots.txt that references it). A submitted/verified parent
  index confers no authority on a child hosted elsewhere.
- *Conflict* — when a child's evidence is missing or disagrees with the parent's
  (e.g. different host, no own evidence), that child's `authority_evidence` is
  `absent` or `conflicting`; report per child via `subject_ref` (§8;
  `findings-contract.md`), never a single index-wide authority result.

Sources: Google "Submit your sitemap" / "How to cross-submit" / GSC report
(`https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap`,
`https://support.google.com/webmasters/answer/7451001`); Bing sitemaps help;
Yandex "Download the Sitemap".

### 12.2 Three independent scope relations

Three **separate** evaluators and findings — never collapsed into one validity
result or one "downgrade":

**(a) sitemap → listed page** (`<loc>` scope; baseline
`PROTOCOL_URL_OUT_OF_SCOPE`, §4/§7):

| ruleset | rule | provenance |
|---|---|---|
| `sitemaps.org` | same scheme+host+port, same-or-lower directory (protocol scope; note `sitemapr`'s §4/§7 baseline *mechanics* currently enforce the host + directory dimensions) | `documented` |
| `google` | same rule, **but** the page-directory restriction is waived when `submission_channel = search_console_api`, **and** the same-host restriction is likewise relaxed for a cross-site page whose host is covered by verified cross-submission (established by (c)) — context-dependent validity rules, not severity downgrades | `documented` |
| `bing` | inherits the baseline same-host + same-or-lower-directory scope; no modern Bing directory exception is documented (the absence is itself a `documentation_gap`, noted after the table — the *enforced* rule is the inherited one) | `inherited_protocol` |
| `yandex` | same-domain, exact host match **including scheme and `www`**, descendant-directory page scope; **no ownership exception** | `documented` |

**(b) sitemap index → child sitemap** (index-child scope; index nesting
forbidden by sitemaps.org, §8):

| ruleset | rule | provenance |
|---|---|---|
| `sitemaps.org` | children must be on the **same site** as the index ("can only specify Sitemaps that are found on the same site"). The protocol states **no** directory restriction on the child *files* — the same-or-lower-directory rule applies to URLs *within* a sitemap, not to index children | `documented` |
| `google` | same-site retained **and** children must be in the **same-or-lower directory** as the index (Google-specific, from large-sitemaps — not baseline); a cross-site child is allowed only when configured cross-submission establishes it | `documented` |
| `bing` | inherits the baseline same-site rule; modern cross-site child behavior is not documented (a `documentation_gap`, noted after the table — the *enforced* rule is the inherited same-site one) | `inherited_protocol` |
| `yandex` | same-site children; no ownership exception documented | `documented` |

**(c) authority evidence → represented site** (cross-site authority; structured
`authority_evidence` from §12.1):

| ruleset | rule | provenance |
|---|---|---|
| `sitemaps.org` | cross-submit trust: a sitemap may be hosted on a different host when the **target host's robots.txt** references it (`target_host_robots_reference`) — the protocol's "prove you own the host by pointing `robots.txt` at the Sitemap" mechanism; otherwise a same-location default (`same_location_default`) | `documented` |
| `google` | verified property (`search_console_api`) **or** an exact target-host robots.txt reference | `documented` |
| `bing` | submission is for a verified site; the 2008 robots.txt cross-domain trust workflow is **not restated** in current docs — do **not** invent a current exception | `documentation_gap` |
| `yandex` | submission is bound to the selected verified site; no cross-site ownership exception documented | `documented` |

Page scope (a) and index-child scope (b) can yield **different** verdicts for the
same file; they stay independent.

**Combining (a) and (c).** The evaluators stay independent in *what they report*,
but a hard page-scope failure from (a) (`PROTOCOL_URL_OUT_OF_SCOPE`) MUST be
suppressed to an engine-accepted result when (c) establishes authority for that
page's host (Google verified cross-submission; an exact target-host robots.txt
reference; the baseline cross-submit mechanism). Absent authority evidence, (a)'s
out-of-scope finding stands. This keeps the relations independent while preventing
a legitimate cross-site GSC (or robots.txt-cross-submitted) sitemap from emitting a
false hard failure — the authority result governs, it does not merely downgrade
severity. Sources: sitemaps.org "Sitemap file location";
Google build-sitemap + large-sitemaps
(`.../sitemaps/large-sitemaps`); Yandex error-dictionary "Incorrect URL
(doesn't match the Sitemap file location)".

### 12.3 Supported formats by ruleset

Parse capability is **orthogonal** to engine acceptance (§1): `sitemapr` may
parse a format an engine does not accept and emit a ruleset finding. States:
`supported` / `unsupported` / `not_documented`.

| format | `sitemaps.org` | `google` | `bing` | `yandex` |
|---|---|---|---|---|
| XML `urlset` / index | supported | supported | supported | supported |
| Text | supported | supported | supported | **supported** *(tester: clean)* |
| RSS 2.0 | supported | supported | supported | **unsupported** *(tester: recognised as "Sitemap RSS-file", item links extracted, but standard channel children error — parse-then-reject)* |
| Atom 1.0 | supported | supported | supported | **unsupported** *(tester: root `<feed>` rejected, 0 links)* |
| Atom 0.3 | supported | `not_documented` | supported | unsupported |
| mRSS | — | supported (video) | — | unsupported |

`—` is **not** one of the three states: it means *not applicable* (the format is
not part of that engine's format list and has no baseline row — e.g. mRSS predates
neither the sitemaps.org nor the Bing list). **Per-cell provenance:** every
`supported`/`unsupported` cell is `documented` from the engine's current format
list, except that the sitemaps.org column and every overlay cell that merely
repeats it are `inherited_protocol`, and Google **Atom
0.3 = `not_documented`** (absent from Google's current format list — recorded as
absent, not asserted unsupported; a one-shot live-submit check is deferred to
`SITE-jufaqaql`). The Yandex cells are `documented` from its "Formats supported"
page (XML + TXT supported; RSS/Atom not); the tester only **corroborates** them and
adds the RSS *parse-then-reject* mechanism detail (`advisory`, tool-observed). Sources: sitemaps.org "Other Sitemap formats"; Google
build-sitemap; Bing Webmaster sitemaps help; Yandex "Formats supported by
Yandex" + tester (§12.0 caveat). Bing's 2009 XML-only statement is historical
(§12.6), not normative.

### 12.4 Sitemap-fetch handling

Sitemap-fetch status is its **own** sparse table — kept separate from the
robots.txt status policy (robotstxtr / ADR-009) and from ordinary-page status.
Never reuse either matrix here.

| ruleset | rule | provenance |
|---|---|---|
| `yandex` | the sitemap request must return **exactly `200 OK`**; a non-200 is not processed; a redirect is surfaced as a condition to remove (fetch enforcement is production — see `SITE-jufaqaql`) | `documented` |
| `google` | the sitemap must be fetchable by Googlebot, with documented 4xx / HTTP fetch-error categories | `documented` |
| `bing` | no published sitemap-specific HTTP-status map | `documentation_gap` |
| `sitemaps.org` | the protocol page's "HTTP 200" refers to the legacy **ping** acknowledgement, **not** sitemap-file retrieval | `documented` |

Separate atomic facts (not competing tags in the cells above): Google publishes
**no** exhaustive per-status acceptance table (`documentation_gap` — so do **not**
synthesise per-code verdicts); and the sitemaps.org anonymous ping is **deprecated**
(`advisory` — Google 2023, Bing 2022). Do **not** synthesise a per-status
acceptance table for Google/Bing, and do not
promote general HTTP/page-indexing status rules into sitemap-fetch behavior.
Sources: Yandex "File requirements" / "Sitemap isn't processed"; Google GSC
sitemap fetch errors (`.../answer/7451001`); sitemaps.org "Submitting your
Sitemap via an HTTP request".

### 12.5 Encoding and URL requirements

Baseline (`inherited_protocol`, §2/§4/§7): UTF-8 file; entity-escape
`& ' " < >`; URLs URL-escaped, RFC-3986 (URI) / RFC-3987 (IRI); `<loc>` < 2,048
chars. `google`: UTF-8 + fully-qualified absolute URLs, crawled as listed
(`documented`). `bing`: full protocol support, no documented encoding/URL
deviation (`inherited_protocol`; Bing 2025 post).

**Yandex** *(tester-grounded; §12.0 caveat)*:

| aspect | behavior | provenance |
|---|---|---|
| URL length (hard) | the error-dictionary documents a hard limit ("URL length exceeds the limit (1024 characters)"); `sitemapr` enforces it as: a `<loc>` whose **percent-decoded** length exceeds ~1,024 chars is rejected. Length is measured on the **decoded whole URL** (a `%`-encoded value that decodes short is accepted; the query string counts; **not** per path-segment) — this decoded/whole-URL reading, and treating 1,024 as operative over the requirements-page 2,048, is the executable interpretation | `application_choice` (resolves the doc conflict; error-dict 1,024 is the `documented` basis) |
| URL length (soft) | a separate per-tag byte guard, "Data limit exceeded in tag `<loc>`", fires for long **raw** `<loc>` content — the observed WARNING boundary is **~1,200–1,500 raw bytes** (probe: raw 1,500 already warns), i.e. *below* the requirements page's 2,048; surfaced as a warning | `advisory` (tool-observed) |
| BOM | **optional**: a missing BOM is clean, a UTF-8 BOM is tolerated, and only a **non-UTF-8** leading BOM errors ("Invalid byte sequence in BOM") — agrees with the baseline (§3), no per-engine override | `inherited_protocol` |
| raw non-ASCII / IRI | raw Cyrillic (path + query), percent-encoded forms, and a **raw IDN host** are all accepted — the baseline RFC-3987 (IRI) allowance, tester-confirmed | `inherited_protocol` |

Notes: the requirements-page "2,048 total = 1,024 domain + 1,024 path" framing is
**superseded for the hard cap** — the operative hard limit is ~1,024 on the
**decoded** URL (the error-dictionary figure). The requirements-page 2,048 is *not*
a clean observed boundary: the soft raw-byte data-guard already warns at
~1,200–1,500 bytes, so nothing is accepted cleanly up to 2,048. The
`documentation_conflict` is thereby **resolved empirically**. With a short host the
whole-URL-vs-path-component distinction is **not separable** in the probe (the two
predictions coincide), so modelling the hard cap as ~1,024 on the **decoded whole
URL** is an `application_choice` (the error-dictionary "1,024" is the `documented`
basis it rests on); it is **not** itself a documented Yandex statement. The **BOM** result **agrees with
the baseline** and requires **no change to §3**; robots.txt byte behavior is
**not** imported (ADR-009 non-goal). The **raw-IRI** result is compatible with the
baseline RFC-3987 allowance and with `sitemapr`'s existing `info`
`PROTOCOL_URL_NOT_ESCAPED` (§7 item 5, ADR-005) — under the `yandex` ruleset that
`info` may be relabelled *engine-accepted* rather than flagged. Not constructable
(note only): a host > 1,024 chars is impossible (DNS caps a hostname at 253), so
the "1024 domain" bucket cannot be exercised. Sources: Yandex "File
requirements" + error-dictionary + tester; sitemaps.org "Entity escaping" / "XML
tag definitions"; Google build-sitemap.

### 12.6 Limits: document-format vs submission/property

**Document-format limits** (file conformance; §2 already carries these):

| bound | value | rulesets | provenance |
|---|---|---|---|
| URLs per sitemap | 50,000 | baseline / google / bing / yandex | `documented` / `inherited_protocol` |
| child sitemaps per index | 50,000 | baseline / google / bing / yandex | `documented` / `inherited_protocol` |
| uncompressed size | **50 MB** — baseline / Google / Bing state **52,428,800 bytes** (50 MiB); **Yandex** documents "50 MB" without a byte figure | baseline / google / bing / yandex | `documented` |
| `<loc>` length | baseline < 2,048; **yandex ~1,024 decoded** (§12.5) | — | see §12.5 |

**Submission / property limits** (operational, not file conformance):

| bound | value | ruleset | provenance |
|---|---|---|---|
| sitemap-index files per Search Console site | 500 | `google` | `documented` (a **submission** cap, not a file rule) |

**Historical / obsolete** (labeled, non-normative): Bing **2008 10 MB** and
**2009 XML-only** are superseded by the 2016 announcement + current Bing help;
they must **not** enter the `bing` ruleset. Parity: 50 MB is **52,428,800 bytes**
(binary MiB), *not* the round 50,000,000 — `sitemapr` is correct
(`R/protocol-validate.R:250`); the sitemap-validator fix is tracked under
`SMV-idhjmljf`. Sources: sitemaps.org (verbatim "50MB (52,428,800 bytes)");
Google build-sitemap + large-sitemaps; Bing Nov-2016 size announcement + current
help + Jul-2025 post; Yandex "File requirements".

### 12.7 Metadata semantics by ruleset

Syntax validation stays **separate** from engine use (§4); advisory metadata is
**never** turned into a validity failure. Per-field states:
`validated_and_used` | `accepted_advisory` | `accepted_but_ignored` |
`behavior_undocumented`.

| field | `sitemaps.org` | `google` | `bing` | `yandex` |
|---|---|---|---|---|
| `lastmod` | optional | used **only if** consistently accurate | key recrawl signal | accepted; date & datetime; **date-only accepted** (baseline §4; tester-corroborated) |
| `changefreq` | hint | ignored | ignored | accepted; effect `behavior_undocumented` |
| `priority` | intra-site hint | ignored | ignored | accepted; **documented to affect crawl load order** (effect production-only) |

Provenance (each cell maps to one of the four states):
`sitemaps.org` `lastmod`/`changefreq`/`priority` = `accepted_advisory`
(`inherited_protocol`); Google `changefreq`/`priority` = `accepted_but_ignored`
(`documented`), `lastmod` conditional-use ≈ `validated_and_used` when accurate
(`documented`); Bing `changefreq`/`priority` = `accepted_but_ignored`
(`documented`, 2025 supersedes 2023 "largely disregards"), `lastmod` =
`validated_and_used` (`documented`); Yandex `lastmod` = `accepted_advisory`
(accepted date & datetime, `documented`; date-only acceptance is baseline,
`inherited_protocol`), `priority` crawl-order = `documented` (docs) but
**production-unverified** (`SITE-jufaqaql`), `changefreq` = `behavior_undocumented`.

**Yandex** (error-dictionary "Warnings"; tester-corroborated): invalid `lastmod` /
`changefreq` / `priority` (bad format, enum, range, or non-numeric) are **warnings
and the URL stays a valid link** (`accepted_advisory`, `documented`) — never a hard
failure; unknown/unexpected tags are ignored with a warning ("Unknown tag X",
`documented` accept-but-ignore). A generic per-tag byte guard also fires on
over-long optional elements ("Data limit exceeded in tag X", **~100 bytes** for
`lastmod`/`changefreq`/`priority`; **~1,200–1,500 raw bytes** for `<loc>`, §12.5),
surfaced as a warning (`advisory`, tool-observed). Index `lastmod` refers to the child sitemap
**file**, not its pages (baseline; §4/§8; `inherited_protocol`). Sources: sitemaps.org
"XML tag definitions"; Google "Additional notes about XML sitemaps"; Bing 2025
post; Yandex "Formats supported" + "Warnings" + tester.

### 12.8 Findings encoding (model) and non-goals

Per ADR-009 §6, per-engine findings **extend** the shared contract, they do not
fork it: shared codes for shared semantics, plus **additive** versioned
`ruleset` / revision / context / provenance fields; new engine-specific codes
only where a rule is genuinely engine-specific. The existing ten-column result
(§10; `findings-contract.md`) stays a stable, legacy-compatible contract; the
per-engine context is additive, never a silent widening of the pinned table.

This section **does not mint new code strings.** Where a per-engine rule implies
a new code (e.g. a Yandex decoded-length rule distinct from
`PROTOCOL_URL_TOO_LONG`, or the Yandex per-tag data-guard distinct from
`PROTOCOL_SIZE_EXCEEDED`), it is described here and the literal code is
**registered in the findings-registry slice**, not invented in the spec.
Existing codes (`PROTOCOL_URL_OUT_OF_SCOPE`, `PROTOCOL_URL_TOO_LONG`,
`PROTOCOL_URL_NOT_ESCAPED`, `PROTOCOL_SIZE_EXCEEDED`, the `PROTOCOL_LASTMOD_*`
set, `INDEX_CHILD_COUNT_EXCEEDED`, …) are reused where semantics match.

**Non-goals** (ADR-009 §8, restated for the sitemap side): no content/grammar
validation of robots.txt; no crawler-lifecycle emulation; **Bing** sitemap
status/cross-site behavior is **not invented** — undocumented Bing cells stay
`documentation_gap`; general HTTP / page-indexing guidance is **not** promoted
into sitemap-specific behavior; historical values are labeled, never normative.

---

## 13. Per-engine page-directive interpretation (Layer E)

Governing design: `docs/design/layer-e-page-inspection.md` §0.3, §5.1, §5.3.
Where §12 covers rules about the **sitemap document**, this section covers the
interpretation of directives found on the **pages a sitemap advertises** — the
`<meta name=robots>` / `X-Robots-Tag` fold (E.3) and hreflang reconciliation
(E.4). The §12.0 vocabulary, provenance tags, atomicity rule, and source
precedence apply here unchanged.

**No new ADR-009 axis.** The crawler-token vocabulary is not reinvented:
`robotstxtr` engine-contract-v1 already owns it, and this section documents
sitemapr's interpretation *on top of* that vocabulary.

### 13.0 Naming bridge — sitemap ruleset ↔ robots policy ruleset

The two value sets are **different axes** and are related by a documented
**preset**, never a silent derivation (ADR-009 §1 independence):

| `sitemap_ruleset` (§12, sitemapr-owned) | `robots_policy_ruleset` (`robotstxtr`) |
|---|---|
| `sitemaps.org` (baseline / "no engine") | `rfc9309` |
| `google` | `google` |
| `bing` | `bing` |
| `yandex` | `yandex` |
| *(no sitemap-side equivalent)* | `assumed_rfc9309` |

Selecting a sitemap ruleset does **not** select a robots policy. A Bing *sitemap*
ruleset does not imply a Bing *robots* policy: the two are chosen independently,
because "which engine's sitemap rules am I validating under" and "which engine's
robots semantics govern access" are different questions.

**Explicit API carrier.** The robots axes are carried explicitly by
`robots_context(product_token, policy_ruleset, matcher_backend)`, with
`robots_context_preset()` supplying the documented presets above. A preset
**retains its expanded values** on the returned object, so a caller can read
back exactly which product token, policy ruleset, and matcher backend were
selected — the mapping is inspectable, not implicit. Provenance:
`application_choice` (the bridge is a named sitemapr product decision, not an
engine-documented mapping).

### 13.1 Crawler-token model — steal the vocabulary, do not invoke the matcher

Page-directive scoping reuses `robotstxtr`'s **product-token** vocabulary and
its published capability boundary, read from the **public** accessor
`robots_engine_contract_v1()$matcher_capability`
(`engine_backend_capability_v1()` is internal to `robotstxtr` and must not be
reached into):

| Backend | `token_policy` | Meaning for page-directive scoping |
|---|---|---|
| `google` | `arbitrary_valid` | any syntactically valid token may be named |
| `bing` | `bounded_profiles` | only the supported vendor profiles |
| `yandex` | `bounded_profiles` | only the supported vendor profiles |
| `rfc9309` | `rfc9309` | RFC 9309 token rules |

**Use vs. steal, by layer.** The robots matcher is *literally used* for the
**access** decision (E.5, E.1b, the §0.6 sitemap-blocked check). For page-directive
**interpretation** only the vocabulary is reused: matching a crawler name in
`<meta name="googlebot-news">` or a crawler-prefixed `X-Robots-Tag` is
**prefix/string matching on a token**, not robots.txt group selection, and the
matcher is never invoked for it.

**Why this boundary matters:** `robotstxtr` is a `Suggests`. Interpretation MUST
degrade gracefully when it is absent — only the access checks may gate on its
presence. Provenance: `application_choice`.

Carried over from `robotstxtr`'s own contract, the **anti-laundering rule**
applies here too: a decision computed under one engine's parsing reflects *that
engine's parsing*, never a prediction about the crawler a token happens to name.

### 13.2 The three-stage fold (E.3)

A naive "`noindex` in either channel wins" fold is **wrong** — it skips crawler
scoping and assumes a cross-engine conflict rule that does not hold. The model
is three stages:

1. **Extract** (Contract B): every directive fact, per channel
   (`<meta name=robots>` vs `X-Robots-Tag`), per crawler scope. Pure extraction,
   no interpretation.
2. **Crawler-applicability filter:** keep only directives applying to the target
   crawler for the chosen engine. Unscoped directives always apply; scoped
   directives apply only to their named crawler; general and engine-specific
   names combine.
3. **Engine fold:** resolve the surviving set to an effective directive.

| Engine | meta ≡ header | fold rule | channel-only notes | provenance |
|---|---|---|---|---|
| **Google** | yes | most-restrictive wins; the negative rules combine; `none` ⊇ `noindex` | non-HTML → header-only | `documented` (the general most-restrictive rule) |
| **Bing** | yes | most-restrictive wins, **explicitly cross-channel** — "if both forms present, the most restrictive applies" | not documented | `documented` |
| **Yandex** | yes | **allow-wins** — an explicit `index` / `all` overrides a `noindex` | `all` is meta-only | `documented` |

**Split cell (atomicity, §12.0).** For Google the *general* most-restrictive rule
is `documented`, but applying it **across channels** (meta vs header
specifically) has no worked example in Google's documentation. That atomic fact
is therefore separate and **`inferred`** — diagnostic only, and it may not drive
a hard verdict on its own.

**Note the divergence direction.** Google and Bing fold toward the *restrictive*
reading; **Yandex folds the opposite way** (an explicit allow overrides a
`noindex`). Engine divergence therefore only bites on an **explicit conflict**.
In the common case — `noindex` in exactly one channel with nothing opposing it —
all three engines agree; that agreement is `inferred` but safe.

**Must handle:** `none` (= `noindex,nofollow`), crawler-scoped meta names and
crawler-prefixed `X-Robots-Tag`, repeated or comma-separated headers and multiple
meta tags, and Yandex's channel-specific support.

**Out of scope for v0.2:** time-scoped directives (`unavailable_after`). The
check is therefore scoped to **effective `noindex`**, not full "indexability" —
canonical, HTTP status, and robots access also bear on whether a URL is really
indexable, and are reported by their own checks.

### 13.3 hreflang interpretation (E.4)

E.4 is a **reconciliation/consistency check, not a presence check**: the sitemap
and on-page methods are officially equivalent, so "missing on-page hreflang" is
not a defect when the sitemap carries it.

| Engine | sitemap-vs-page conflict verdict | provenance |
|---|---|---|
| **Google** | methods are equivalent; disagreement is a **consistency diagnostic** | equivalence `documented` |
| **Bing** | no equivalence, precedence, or reciprocity documented → diagnostic only | `documentation_gap` |
| **Yandex** | sitemap hreflang **discontinued**; validate on-page markup directly — the page is authoritative | `documented` |
| **sitemaps.org** | base spec defines no hreflang; `xhtml:link` is a Google extension | `documented` |

**Split cell (atomicity).** For Google the *equivalence of methods* is
`documented`; the **severity of a cross-method disagreement** is a separate
atomic fact with no primary source, so it is **`inferred`** — diagnostic only.
A sitemap-vs-page hreflang disagreement is never a hard failure.

**Do not conflate reciprocity with cross-method disagreement.** Google's
return-tag rule ("if two pages do not both point to each other, the tags are
ignored") is about **cross-page** pointing-back, not about a page disagreeing
with the sitemap. Cross-page reciprocity is **not safe under sampling**: a graph
built over a *sample* is incomplete by construction and would emit false
"no return tag" findings. It requires full corpus coverage, and the sampled
page-inspection path deliberately does not compute it.

### 13.4 Baseline behavior — `sitemaps.org` / "no engine"

Under the baseline ruleset there is **no engine fold to apply**. The page-layer
checks still run and still emit, as **generic consistency diagnostics** carrying
no per-engine interpretation:

- **E.2 canonical** — a mismatch is reported as a consistency diagnostic. Even
  under `google` this is deliberately softened: sitemap inclusion is an
  explicitly **weaker** canonicalization signal than a redirect or `rel=canonical`
  (`documented`), so a mismatch means "the page prefers a different canonical
  than the sitemap advertises", never "the sitemap is wrong".
- **E.3 noindex** — the channel codes (`PAGE_META_ROBOTS_NOINDEX`,
  `PAGE_XROBOTSTAG_NOINDEX`) report *what and where* the directive was seen.
  Without an engine overlay no fold verdict is computed, so the effective-
  indexability conclusion is omitted rather than guessed.
- **E.4 hreflang** — set disagreement is reported under the shared identity
  rules with no engine-specific severity.

Baseline emission is **suppression-free**: the checks are not silently disabled
without an engine, because the underlying facts are engine-neutral observations.
What an overlay adds is *interpretation*, not *detection*. Provenance:
`application_choice`.

### 13.5 Non-goals

This section does **not** mint new code strings; page-layer codes are registered
in the findings registry, not invented here. It does not promote general HTTP or
page-indexing guidance into sitemap-specific behavior, and it does not invent
undocumented engine behavior — undocumented Bing cells stay `documentation_gap`.

**Yandex `noindex` × robots.txt is deliberately absent.** The robots.txt-blocked
× `noindex` synthesis (design §5.4) is documented for Google and Bing only. The
equivalent Yandex case — URL-only indexing when robots.txt blocks the fetch —
is **not yet sourced from primary Yandex documentation** and is therefore not
encoded here in any form. It stays a `documentation_gap` until a primary quote
is obtained.
