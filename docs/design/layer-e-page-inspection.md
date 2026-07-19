# Layer E — per-URL page inspection: behavior spec & decomposition

**Status:** accepted as the v0.2 development contract, with hardening amendments
(§0). The body below (§1–§11) is the v2.1 draft; **where §0 and the body
disagree, §0 wins** — §0 records the decisions taken after the third review.
**Date:** 2026-07-19 (promoted from `_scratch/` and hardened).
**Parent issue:** SITE-ihycidfl (v0.2: per-URL page inspection, Layer E).
**Supersedes:** the dead `_scratch/cross-port-analysis.md B2` reference in the parent issue.

---

## 0. Hardening amendments (authoritative over the body)

### 0.1 Framing — three layers, not one

A sitemap can be fetched by **any** bot; per-engine identity matters only in two
of the three layers page inspection touches. Keep them separate:

- **Access** (robots.txt: who may fetch what) — *engine-aware*. Applies to both
  the sitemap document (§0.6, new) and the listed URLs (E.5, done). Owned by
  `robotstxtr`.
- **Fetch** (server + URL) — **engine-neutral mechanics**. Any bot fetches; the
  server returns what it returns. This is E.1 / Contract A. Engine identity MUST
  NOT leak into the fetch.
- **Interpretation** (how a given engine would *read* the fetched signals) —
  *engine-aware*. E.2/E.3/E.4 / Contract C.

### 0.2 Goals / non-goals / acceptance

**Goals.** Opt-in, default-off, budgeted per-URL inspection over the registered
`page` codes; one reusable engine-neutral fetch artifact; pure extractors;
per-engine interpretation that conforms to `robotstxtr`'s contract and ADR-009.

**Non-goals (v0.2).** `audit_sitemap()` / streaming path (D4); `unavailable_after`
time-scoped directives; cross-page hreflang reciprocity over a *sample*; a new
fused indexability code; rendering JavaScript (the fetch is an **unrendered**
snapshot — every absence-derived finding carries that caveat).

**Acceptance.** (a) baseline `sitemap_ruleset = "sitemaps.org"` returns exactly
the pinned ten columns, page inspection off, byte-identical to today; (b) with
`inspect_pages = TRUE`, transport + extractor findings render in the `page` layer
and `attr(x, "page_coverage")` reports coverage; (c) E.5 output is byte-identical
after the E.1b refactor; (d) all network tests are offline/mocked (CRAN); (e) no
finding severity or code diverges from `findings-registry.csv` without a filed,
coordinated registry migration.

### 0.3 Crawler-token axis → adopt `robotstxtr` engine-contract-v1 (supersedes §5.1/§8/§10-D1)

There is **no new sitemapr axis and no ADR-009 amendment for the axis.**
`robotstxtr` already owns the vocabulary as first-class parameters of
`robots_evaluate_url_v1(url, robots_product_token, robots_policy_ruleset,
matcher_backend, …)`, and publishes the capability boundary at the **public**
accessor `robots_engine_contract_v1()$matcher_capability` (`token_policy`: Google
`arbitrary_valid`; Bing/Yandex `bounded_profiles`; rfc9309 `rfc9309`), including
the anti-laundering rule ("a Google decision on any token reflects Google parsing,
never a prediction of the crawler the token names"). Consume the public accessor —
`engine_backend_capability_v1()` is **internal** to `robotstxtr`.

- **API carrier — not silent derivation.** The robots axes need an **explicit
  carrier** on the public entry point. `validate_sitemap_ruleset()` /
  `ruleset_context()` today expose only the four sitemap-source axes
  (`submission_channel` / `discovery_provenance` / `property_scope` /
  `authority_evidence`) — **neither `robots_policy_ruleset` nor `matcher_backend`**.
  Deriving them silently from `sitemap_ruleset` violates ADR-009's axis
  independence. Add explicit arguments (or a structured robots context) with
  **documented presets whose expanded values are retained** (ADR-009 §1). The
  naming bridge below is a *preset*, not an implicit derivation.
- **Use vs. steal, by layer.** *Literally use* `robotstxtr` for the **access**
  decision (E.5, E.1b, and the §0.6 sitemap check). *Steal the ideas* for
  **interpretation** (E.3 crawler-applicability filter): reuse the product-token
  vocabulary + `token_policy` boundary, documented in `docs/sitemap-spec.md`; do
  **not** invoke the robots matcher for `<meta>`/`X-Robots-Tag` scoping (that is
  prefix/string matching on a token, not robots.txt group selection). Rationale:
  `robotstxtr` is a `Suggests`; interpretation MUST degrade gracefully without it
  — only the access checks may gate on its presence.
- **Naming bridge (sitemapr-owned):** `sitemap_ruleset ∈ {sitemaps.org, google,
  bing, yandex}` maps to `robots_policy_ruleset ∈ {rfc9309, assumed_rfc9309,
  google, bing, yandex}`; `sitemaps.org`/"no engine" ↔ `rfc9309`.

### 0.4 `partial` requires an ADR-009 §2 amendment (supersedes §3.1/§10-D7)

`partial` is **already** in the ADR-009 §2 `evidence_status` enum (ADR-009:104) —
so the ADR does **not** "add" it. It MUST instead **(a)** amend the **ADR-009 §3
body-ceiling rule** (accepted ADR-009 resolves a reached body ceiling to
`incomplete`; the intentional truncate-and-retain page cap resolves to `partial`,
head-region facts usable), **(b)** define the page-cap `partial` semantics, and
**(c)** add an **ADR-003** page-cap subsection. Name these as **direct edits to
ADR-009 §3 and ADR-003**, not an enum addition and not a cross-reference.
**Resolved by `docs/decisions/ADR-010-page-inspection.md`** (§2) — which also
carries the ADR-009 §3 and ADR-003 §3 direct edits; the opt-in network-expansion
justification (§0 open-decision 5) and the transport safety/resource split (§0.5)
land in ADR-010 §1/§3.

### 0.5 Transport matrix conforms to the registry (supersedes §3.4)

`findings-registry.csv` is the source of truth. The §3.4 matrix is **wrong** and
is overridden: `PAGE_STATUS_REDIRECT = warning`, `PAGE_REDIRECT_CHAIN = info`
(registry rows 79–80). The matrix must also map `incomplete`,
`http_protocol_error`, and `not_applicable`. The **500 MB resource-ceiling
discard maps to `PAGE_FETCH_FAILED`** (a resource/transport failure), **not**
`PAGE_SSRF_BLOCKED` — `PAGE_SSRF_BLOCKED` is reserved for SSRF / scheme /
HTTPS→HTTP downgrade refusals only. Any change to a registry severity is a
separate, coordinated cross-repo migration, never a silent flip in an issue.

### 0.6 New check — sitemap document blocked by robots.txt (E.5 sibling)

We consume the robots.txt `Sitemap:` directive for **discovery only** and
explicitly ignore `Disallow`/`Allow` there (`R/discovery.R:312`); all robots
allow/deny checking targets the *listed URLs*. Add the document-level analog:
"is the sitemap URL itself `Disallow`-ed for this engine's token?" — an engine-
aware self-contradiction diagnostic (parallel to the §5.4 robots×noindex trap),
reusing the E.5/`robotstxtr` machinery pointed at the sitemap URL. Needs a
registry code decision (new `ROBOTS_*` code at `source` scope, or reuse of
`ROBOTS_DISALLOWED`) — a coordinated registry addition, never a silent invention.

### 0.7 Findings encoding — per-finding context merge, not a uniform stamp (supersedes §8/§10-D6)

The assembler stamps a **uniform** ruleset `context` on every row
(`R/findings-assemble.R:229`) and the baseline ten-column surface has **no
`context` column at all**. So page-specific context (status code, channel,
crawler scope, raw token, canonical target) needs a **per-finding context merge**
in engine mode, and on the pure `sitemaps.org` baseline it collapses into the
free-form `evidence$excerpt` string (≤500 ch) — so a baseline user still reads
"HTTP 404". Synthesis text still rides `remediation_hint` via the assembler
pass-through (stop nulling at `R/findings-assemble.R:307`).

### 0.8 Decomposition delta (supersedes §11)

E.1 is split into **E.1a** (acquisition/artifact), **E.1s** (selection + budget
orchestration), **E.1f** (transport findings + coverage + Contract-D param
surface + the `deferred-v0.2 → active` registry flip). Extractors E.2/E.3/E.4
depend on **E.1f**. E.1b additionally routes the consultable robots decision
through `robots_evaluate_url_v1()` and preserves E.5 output via
`as_legacy_robots_decisions_v1()`. `SITE-wrylygzd` is **non-gating** (cross-repo
tail of the done E.5). The live issue set in `fp` is authoritative for IDs and
dependencies.

### 0.9 `robotstxtr` contract pin — the concrete blocker

E.1b names v1 engine-contract APIs (`robots_evaluate_url_v1`,
`as_legacy_robots_decisions_v1`) that live in `robotstxtr` **0.2.0**, but
sitemapr's `DESCRIPTION` still pins `robotstxtr (>= 0.1.0)` / `Remotes: …@v0.1.0`,
and **no `v0.2.0` tag exists** in `robotstxtr` (HEAD carries the contract; the tag
does not). The public capability accessor is
`robots_engine_contract_v1()$matcher_capability`. Blocker steps: (1) tag/release
`robotstxtr` v0.2.0 (cross-repo); (2) bump sitemapr `Suggests`/`Remotes` to
`>= 0.2.0` / `@v0.2.0`; (3) gate on the engine-contract schema revision
(`robots_engine_contract_v1()$contract_id`). **Gates E.1b.**

### 0.10 Provenance carrier — code-level is insufficient (expands §0.7)

The assembler derives `provenance` solely from `(code, ruleset)`
(`R/findings-assemble.R:245`). E.3 can make **different** documented/inferred
claims under the **same** code depending on the fold path (e.g. single-channel
`noindex` = `documented`; the cross-channel meta↔header application = `inferred`,
both under `PAGE_META_ROBOTS_NOINDEX`). So context + `remediation_hint` do not
close the seam. Resolve one of: **(a)** allow a producer-supplied `provenance`
with a documented collision rule against the `(code, ruleset)` default, or
**(b)** constrain every emitted row/message so code-level provenance stays
sufficient. Owned by the assembler issue (§0.7).

### 0.11 Acceptance tightening

- **Coverage shape:** pin whether `attr(x, "page_coverage")` is **batch-wide** or
  **per-sitemap** for `validate_sitemaps*()`, and version the attribute.
- **Transport-finding precedence:** "at most one transport finding" needs an
  explicit order when outcomes overlap on one logical fetch —
  **`safety_refused` > terminal `http_status` > redirect (resolved /
  over-budget)**. A safety refusal or terminal error outranks any redirect
  observation.

---

**Governing contracts (must conform, not restate):**
`docs/decisions/ADR-009-per-engine-validation-profiles.md` (axes, outcome
fields, provenance, safety precedence), `docs/decisions/ADR-003-network-safety-policy.md`
(SSRF), `docs/findings-contract.md` + `docs/findings-registry.csv` (the pinned
ten-column findings contract and the already-registered `PAGE_*` codes).

> **v2 changelog** (why this differs from v1): (1) drop the invented
> "target-engine parameter" — ADR-009 forbids a single profile scalar and defines
> independent axes; (2) the `page` layer and all `PAGE_*` codes are **already
> registered** as `deferred-v0.2` — this spec conforms to them, it does not
> propose them; (3) add four missing contracts (fetch artifact + budget, raw-facts
> schema, per-engine interpretation with provenance, public-API/coverage);
> (4) E.3 keeps the two committed channel codes and *computes* effective
> indexability (option a); (5) hreflang cross-method disagreement is an `inferred`
> consistency diagnostic, not an engine verdict; (6) E.5 needs a facts/decisions
> refactor before any synthesis can consult it; (7) Bing's URL-only indexing of
> robots-blocked URLs is now first-party `documented`; (8) canonical extraction
> adds the HTTP `Link` header and edge cases; (9) the fetch record is an
> **unrendered** snapshot (no JS) and this is stated, not implied.

> **v2.1 changelog** (second Codex review): (1) **Contract D added** (§6) —
> public-API param surface + coverage-metadata shape + audit/report inclusion,
> the fourth contract the v2 changelog promised but never defined; (2) the page
> fetch is a **truncate-and-retain** path distinct from ADR-003's
> discard-at-ceiling backstop, and `partial` rejoins the `evidence_status` enum
> (§3) — a truncated head is `partial` (facts usable), not `incomplete`; (3) an
> **E.1 emission matrix** (§3.4) pins which outcome maps to which `PAGE_STATUS_*`
> code; (4) the findings **encoding is corrected** (§8) — the assembler overwrites
> producer `remediation_hint` with `NA` and the pinned `evidence` list is frozen
> to `excerpt/line/column`, so page context rides the engine-aware `context`
> list-column and synthesis text needs an assembler change, not a silent widening;
> (5) Contract B gains a per-family **extraction status** (§4) so *absent* is
> distinguishable from *unobserved*; (6) the hreflang divergence predicate (§5.3)
> and a shared URL-identity rule (§5.2) are pinned; (7) the `page`/`robots`
> **report-layer omission** is split out as its own bug — it already hides shipped
> E.5 `robots` findings.

---

## 1. Framing — two entry points, and what an inspector actually sees

A sitemap is an **assertion**; the page is the **reality**. The sitemap says
"this URL exists, is canonical-worthy, index it, here are its language
alternates." The page's HTTP response + HTML head *declare* what is actually
true. Layer E catches where the two diverge, because the page declaration is
generally the stronger signal — and for some engines the *only* one that counts.

**sitemapr fetches as an inspector, not as a search-engine crawler.** It fetches
the exact advertised URL through `fetch_source()` (ADR-003 SSRF guard, redirect
and body ceilings). This has two consequences that must be stated in every
finding, not assumed:

- **It can see what the engine cannot.** A `noindex` sitting behind a robots.txt
  `Disallow` is invisible to the engine (it never fetches the body) but visible
  to sitemapr — one of Layer E's highest-value findings (§5.4).
- **It sees an UNRENDERED response snapshot.** sitemapr does not execute
  JavaScript and sees only the response delivered to *its* HTTP request
  User-Agent. Google renders JS and can observe JS-injected canonical/robots/
  hreflang markup that a raw fetch never sees. **Absence of static markup is not
  proof the engine sees none.** Every `page`-layer finding derived from *absence*
  (missing canonical, missing hreflang) is therefore a diagnostic with an
  explicit "unrendered snapshot; verify in the engine's tools" caveat, never a
  hard verdict.

**The two public entry points** that gain page inspection:

- `validate_sitemap()` (`R/validate-sitemap.R:853`) — already carries the E.5
  `check_robots` / `robots_user_agent` params; page inspection extends this
  pattern with an opt-in `inspect_pages` + budget params.
- `validate_sitemap_ruleset()` (`R/validate-sitemap.R:972`) — the ADR-009
  ruleset-aware entry; same opt-in, plus the engine interpretation keys off the
  ADR-009 context (§8).
- Batch variants `validate_sitemaps()` / `validate_sitemaps_ruleset()` inherit
  the param surface.
- `audit_sitemap()` (`R/audit-pipeline.R:648`) has **neither** ruleset nor robots
  args today and **streams** (the combined `urls` tibble retains no rows in
  streaming mode — `audit_stream_read`). Whether/how it gains page inspection is
  an explicit Contract-D decision, not assumed.

---

## 2. Decomposition (E.1–E.5) and the codes it maps to

Architecture: a single logical fetch of a sampled URL (which may involve several
HTTP hops) yields a **page-fetch artifact** — status, per-hop redirect trail,
final URL, terminal headers, capped body, outcome. Every check below is a **pure
extractor + interpreter** over that one artifact; no check issues its own
network request (except E.5, which fetches robots.txt per origin, already done).

| Check | Reads from | Registered code(s) | Issue | Status |
|---|---|---|---|---|
| HTTP status | artifact status | `PAGE_STATUS_ERROR`, `PAGE_FETCH_FAILED`, `PAGE_SSRF_BLOCKED` | E.1 | fleshed |
| redirect chain + final URL | artifact hop trail | `PAGE_STATUS_REDIRECT`, `PAGE_REDIRECT_CHAIN` | E.1 | fleshed |
| canonical | artifact body + `Link` header | `PAGE_CANONICAL_MISMATCH`, `PAGE_CANONICAL_MISSING` | E.2 | stub |
| meta robots | artifact body | `PAGE_META_ROBOTS_NOINDEX` | E.3 | stub |
| X-Robots-Tag | artifact header | `PAGE_XROBOTSTAG_NOINDEX` | E.3 | stub |
| page hreflang | artifact body | `PAGE_HREFLANG_MISMATCH` | E.4 | stub |
| robots.txt allow/disallow | robots.txt per origin | `ROBOTS_DISALLOWED`, `ROBOTS_INDETERMINATE` | E.5 | **DONE** (PR #134) |

All `PAGE_*` codes above are **already in `findings-registry.csv:76–85`** as
`deferred-v0.2` baseline rows, and the `page` layer is registered in
`findings-contract.md:58`. This spec conforms to those codes; any change to them
(e.g. §5.1's effective-indexability question, §5.4's synthesis) is an explicit
registry-migration decision with cross-repo reconciliation (cf. SITE-wrylygzd),
called out where it arises — never a silent invention.

**Unifying thread — ADR-009.** E.2/E.3/E.4 interpretation is per-engine and must
ride ADR-009's vocabulary: independent context axes (no `profile`/`target_engine`
scalar), the six-field outcome model where a page verdict is warranted, provenance
tags on every engine cell, and safety-precedence (SSRF/budget are their own
outcomes, never a page verdict). §8 is the conformance checklist.

---

## 3. Contract A — page-fetch artifact + aggregate budget (engine-neutral)

This is **engine-neutral mechanics** (ADR-009 §0/§3): fetching, safety, limits.
No policy or interpretation lives here.

### 3.1 The artifact

`fetch_source()` today returns the pinned 13-column source metadata plus a body
attribute; it follows redirects manually (per-hop SSRF re-check) but **discards
arbitrary response headers and per-hop status/`Location`**. Page inspection needs
an internal artifact that captures them. Define an internal
`page_fetch_artifact` (NOT added to the pinned `source_metadata()` columns unless
a versioned contract change is intended):

- `requested_url`, `final_url`
- `hops`: ordered, one record per HTTP request — `url`, `status`, resolved
  `Location` (so a redirect *chain* is representable; a redirecting page is one
  logical fetch of several requests, not "a single GET")
- `terminal_headers`: the final response's headers, **preserving repeated field
  values** (e.g. multiple `X-Robots-Tag` / `Link` lines)
- `body`: the retained body **prefix** (capped at the §3.3 per-page cap) + a
  `truncated` flag. Truncate-and-retain, not discard (§3.2).
- `outcome`: reuse ADR-009 §2 `evidence_status` values — `usable_body` |
  `partial` | `incomplete` | `http_status` | `http_protocol_error` |
  `redirect_over_budget` | `transport_fail` | `safety_refused` | `not_applicable`.
  `partial` = the body was **truncated at the page cap but the retained prefix is
  usable** (head-region facts are real); `incomplete` = **no usable body at all**
  (deadline/transport yielded nothing). ADR-009 §2 owns this enum; v2 dropped
  `partial` in error — it is exactly the value the truncate-and-retain path (§3.2)
  produces
- `request_user_agent`: the HTTP header actually sent (recorded for the "what did
  the inspector see" caveat; distinct from any engine product token — ADR-009 §1)

### 3.2 Safety precedence (ADR-009 §3, ADR-003)

- SSRF block / scheme restriction / HTTPS→HTTP downgrade → `outcome =
  safety_refused` → `PAGE_SSRF_BLOCKED`. Never a page verdict, never `allow`.
- **Per-page body cap reached → `outcome = partial`, body prefix retained.** The
  page cap (§3.3, single-MB range) is a **truncate-and-retain** bound, distinct
  from ADR-003's 500 MB per-resource safety ceiling — which stays a *discard*
  backstop (`safety_refused`, no prefix; a memory-bomb defense, not a page
  signal). Reading the head region is the whole point, so the page path caps low
  and keeps the prefix. **This is an ADR-003 amendment** (a page-specific fetch
  contract alongside the discard-at-ceiling rule), not a reinterpretation of the
  existing ceiling — settle it before E.1 files (§10 open decision 7).
- Deadline / transport failure with **no** usable body → `outcome = incomplete`.
- Absence read from a `partial` body is *unknown*, not *missing* — it flows to the
  Contract B extraction status (§4) as `unknown`, never to an absence finding.

### 3.3 Aggregate budget (the biggest v1 gap)

The inherited default body ceiling is ~500 MB **per resource** — unsuitable as
the only bound for fetching many pages. Define a dedicated page-inspection budget,
all caller-overridable with safe defaults:

- **fetch key & dedup:** a URL advertised by multiple sitemaps/anchors is fetched
  **once**; the finding still anchors to each advertising `subject_ref`.
- **selection:** deterministic sample (default N; document the algorithm — e.g.
  stable hash order over deduped locs so re-runs pick the same set), plus explicit
  `full` mode.
- **caps:** max pages, max requests (hops count), max aggregate bytes, per-page
  body bytes (far below 500 MB), max elapsed wall time.
- **concurrency / throttling:** host-aware (reuse the per-host pacing seam in
  `request_policy`).
- **failure isolation:** one timeout / SSRF refusal / body-limit hit produces a
  per-page finding (`PAGE_FETCH_FAILED` / `PAGE_SSRF_BLOCKED`) and **must not
  abort the sample**.
- **`full` when a cap bites:** define the exact behavior — `full` is "all deduped
  locs subject to the safety caps"; reaching a cap yields coverage metadata
  marking the run partial, never a silent truncation.

### 3.4 E.1 transport emission matrix

> **SUPERSEDED by §0.5.** The severities in the matrix below are wrong
> (`PAGE_STATUS_REDIRECT`/`PAGE_REDIRECT_CHAIN` reversed) and the 500 MB mapping
> is corrected there. Read §0.5 (+ §0.11 precedence); the matrix here is
> historical.

E.1 is "fleshed" only with the outcome→code mapping pinned. One logical fetch
emits **at most one** transport finding; extraction (E.2–E.4) runs only on a
`usable_body` / `partial` outcome.

| Outcome | Condition | Code | Severity | Extraction? |
|---|---|---|---|---|
| `usable_body` | 2xx, full body | *(none)* | — | yes |
| `partial` | 2xx, body truncated at page cap | *(none; facts flagged `partial`)* | — | yes — absence ⇒ `unknown` |
| `http_status` | terminal 4xx / 5xx | `PAGE_STATUS_ERROR` | error | no |
| `http_status` | terminal 3xx with no resolvable `Location` | `PAGE_STATUS_ERROR` | error | no |
| *(resolved redirect)* | ≥1 hop, terminal 2xx, `final_url ≠ requested_url` | `PAGE_STATUS_REDIRECT` | info | yes (on `final_url`) |
| `redirect_over_budget` | hop count exceeds the redirect cap | `PAGE_REDIRECT_CHAIN` | warning | no |
| `transport_fail` | timeout, DNS, TLS, protocol error, no body | `PAGE_FETCH_FAILED` | error | no |
| `safety_refused` | SSRF / scheme / downgrade / 500 MB ceiling discard | `PAGE_SSRF_BLOCKED` | error | no |

`PAGE_STATUS_REDIRECT` (a redirect resolved) and `PAGE_REDIRECT_CHAIN` (the cap
was hit) are **mutually exclusive** per URL. A redirect whose `final_url` equals
the advertised `loc` under the §5.2 identity rules is informational, not a
mismatch. `partial` never emits a transport finding — the truncation is recorded
only in the artifact and the §6.2 coverage metadata.

---

## 4. Contract B — raw-facts schema (pure extraction, no interpretation)

Extraction is engine-neutral and produces *facts*; §5 interprets them per engine.
Keeping the two apart is what makes extraction testable in isolation and lets one
fetch feed every engine's fold.

- **canonical facts:** every canonical signal found, each tagged by source —
  `html_link` (`<link rel=canonical>` in head), `http_link` (`Link: …;
  rel="canonical"` header), with the raw target, whether it was relative (and its
  resolved absolute form against the response base / `<base>`), and any fragment.
  Record **all** occurrences (multiple/conflicting is itself a fact).
- **robots-directive facts:** every directive token found, each tagged by
  `channel` (`meta` | `header`), the crawler scope it was addressed to
  (`*`/unscoped, or a named token like `googlebot`, `bingbot`, `yandex`), and the
  raw token string. Record **all** occurrences (repeated headers, multiple meta
  tags, comma-separated lists all expand to individual facts).
- **hreflang facts (page):** the set of `(hreflang, href)` pairs declared in the
  page head `<link rel=alternate>`, plus whether a self-reference is present.

- **extraction status (per family/channel):** every family above carries a status
  so a downstream absence check can tell *absent* from *unobserved* — `observed`
  (facts found), `absent` (a **complete, usable** body declared none), `unknown`
  (the body was `partial`, non-HTML, or unparseable, or the fetch failed — absence
  here is not evidence of absence), `not_applicable` (the family does not apply to
  this content type). An absence finding (`PAGE_CANONICAL_MISSING`, and the §5.3
  hreflang predicate) may fire **only** on `absent`, never on `unknown` — this is
  what stops sampling/truncation and the §1 unrendered-snapshot from manufacturing
  false positives. An empty collection alone is *not* an absence signal; the status
  is.

No fact carries a verdict, severity, or engine name.

---

## 5. Contract C — per-engine interpretation (provenance-tagged)

Every engine cell below carries an ADR-009 provenance tag: **executable**
(`documented` / `inherited_protocol` / `application_choice`) may drive a verdict;
**diagnostic-only** (`inferred` / `documentation_gap` / `documentation_conflict` /
`advisory`) may only soften a finding, never fabricate a verdict.

### 5.1 Effective indexability — meta robots + X-Robots-Tag (E.3)

> **Axis handling SUPERSEDED by §0.3.** The fold semantics below stand, but the
> per-engine axis is carried by `robotstxtr` engine-contract-v1 (no new ADR-009
> axis; explicit API carrier, not silent derivation) and provenance is
> producer-supplied where the fold path diverges (§0.10).

**Decision (option a, chosen): keep the two committed channel codes
(`PAGE_META_ROBOTS_NOINDEX`, `PAGE_XROBOTSTAG_NOINDEX`) that say *what/where*, and
*compute* an effective-indexability verdict for the message/severity.** No new
fused code (which would force a registry migration + cross-repo reconciliation).
The channel codes report provenance-of-signal; the effective computation drives
the human-facing conclusion in `remediation_hint`/message.

**Three-stage model** (a naive `noindex`-in-either fold is wrong):

1. **extract** (Contract B): all directive facts, per channel, per crawler scope.
2. **crawler-applicability filter:** keep the directives that apply to the target
   crawler for the chosen engine — unscoped directives always apply; scoped
   directives apply only to their named crawler; combine general + engine-specific
   meta names.
3. **engine fold:** resolve the surviving set to an effective directive.

| Engine | meta ≡ header | fold rule | channel-only | provenance |
|---|---|---|---|---|
| **Google** | yes | most-restrictive wins; combine the negative rules; `none` ⊇ `noindex` | non-HTML → header-only | `documented` (general rule); the *meta-vs-header cross-channel* application specifically is `inferred` (no worked example) |
| **Bing** | yes | most-restrictive wins, **explicitly cross-channel** ("if both forms present, the most restrictive applies") | not documented | `documented` |
| **Yandex** | yes | **allow-wins** — explicit `index`/`all` overrides `noindex` | `all` is meta-only | `documented` |

Must handle: `none` (= `noindex,nofollow`), crawler-scoped meta names and
crawler-prefixed `X-Robots-Tag`, repeated/comma-separated headers and multiple
meta tags, Yandex's channel-specific support. Time-scoped directives
(`unavailable_after`) are **out of scope** for v0.2 — so the check is scoped to
**effective noindex**, not full "indexability" (canonical, HTTP status, robots
access also bear on real indexability). Common-case note: `noindex` in exactly one
channel with nothing opposing → all three engines agree (`inferred`, safe); engine
divergence only bites on explicit conflict, where the Yandex fold differs.

### 5.2 Canonical (E.2)

Extract from **both** `<link rel=canonical>` and the `Link` header (Google honors
both, including for non-HTML files). Define behavior for: multiple/conflicting
canonicals (across or within channels), relative URLs (resolve against response
base / `<base>`), fragments, the final redirect URL, malformed HTML, and non-HTML
responses. Findings: `PAGE_CANONICAL_MISMATCH` (page canonicalizes to a *different*
URL than the advertised `loc`), `PAGE_CANONICAL_MISSING` (info; softened by the
§1 unrendered-snapshot caveat — a JS-injected canonical would be invisible here).

**Soften the assertion:** the sitemap does *not* "assert this URL is canonical."
For Google, sitemap inclusion is an explicitly **weaker** canonicalization signal
than redirects or `rel=canonical` (`documented`). So a mismatch is "the page
prefers a different canonical than the sitemap advertises" — a consistency
diagnostic, not "the sitemap is wrong."

**URL identity (shared rule, ADR-005).** Fetch dedup (§3.3), redirect `final_url`
equality (§3.4), canonical mismatch (here), and hreflang set comparison (§5.3) all
compare URLs the **same** way: the **RFC-3986/3987-canonical form** — ADR-005's
canonical-comparison key (scheme/host lowercasing, default-port removal,
dot-segment and percent-encoding normalization), with the **fragment dropped**.
This deliberately reuses ADR-005's canonical key rather than raw-string equality;
the *raw* advertised `loc` is retained for the finding's `subject_ref` and message
(the raw-vs-canonical distinction ADR-005 draws). Relative canonical / hreflang
targets are resolved against the response base / `<base>` before comparison.

### 5.3 hreflang reconciliation (E.4)

**Decision: E.4 is a reconciliation/consistency check, not a presence check.**
Methods are officially equivalent, so "missing on-page hreflang" is **not** a
defect when the sitemap carries it.

Separate the two comparisons — they have different safety under sampling:

- **per-inspected-page set comparison (safe under sampling):** compare the page's
  declared alternate set against what the sitemap declared for that same URL.
  **Predicate (resolves the v2 contradiction):** emit `PAGE_HREFLANG_MISMATCH`
  only when the page's hreflang extraction status is `observed` **and** the two
  non-empty sets disagree under the §5.2 identity rules (case-insensitive BCP-47 on
  the tag, canonical form on `href`). An **empty page set against a populated
  sitemap set is *not* a mismatch** — methods are equivalent (opening of §5.3), so
  a page carrying no on-page hreflang while the sitemap does is the
  explicitly-excused case; under an `unknown`/`absent` status it is softened by the
  §1 unrendered-snapshot caveat (a JS-injected `<link>` is invisible here), never a
  verdict.
- **cross-page reciprocity / return-tag (NOT safe under sampling):**
  `build_hreflang_graph()` (`R/hreflang-graph.R`) builds a **complete** graph from
  the whole submitted corpus; a graph over a *sample* is incomplete by
  construction and would emit false "no return tag" findings. Do **not** reuse the
  graph verdict logic just because sample data resembles edges. Cross-page
  reciprocity requires full coverage or explicitly fetching the named counterpart.

| Engine | sitemap-vs-page conflict verdict | provenance |
|---|---|---|
| **Google** | methods equivalent; disagreement is a **consistency diagnostic**, NOT "likely void". Cross-page reciprocity is a *separate* rule ("if two pages don't both point to each other, tags are ignored"). | equivalence `documented`; the conflict-severity itself `inferred` → diagnostic only |
| **Bing** | no equivalence/precedence/reciprocity documented → diagnostic only | `documentation_gap` |
| **Yandex** | sitemap hreflang **discontinued**; validate on-page markup directly; page is authoritative | `documented` |
| **sitemaps.org** | base spec defines no hreflang; `xhtml:link` is a Google extension | `documented` |

(Correction from v1: the Google "likely void" verdict was over-stated — reciprocity
is about cross-page pointing-back, not cross-method disagreement.)

### 5.4 Synthesis — robots.txt `Disallow` × `noindex` (the trap)

A URL can be simultaneously advertised in the sitemap, `Disallow`-ed by
robots.txt, and carrying a `noindex`. This is a misconfiguration sitemapr is
uniquely able to detect (it fetches the body the engine can't). Documented
mechanics:

- **Google** (`documented`, quoted): "For the `noindex` rule to be effective, the
  page or resource **must not** be blocked by a robots.txt file…"; "the crawler
  will never see the `noindex` rule, and the page can still appear in search
  results…"; a disallowed URL "can still be indexed if linked to from other
  sites… but the search result won't have a description."
- **Bing** (`documented`, quoted): a robots-disallowed URL still surfaces —
  "Bing cannot show a description of the page as it is disallowed in the website's
  robots.txt file"; robots.txt tells crawlers "what… they can access… **not what
  to add to the index**"; and the trap itself — "**always allow Bingbot to crawl
  pages that have a NOINDEX tag in your robots.txt file.**" (Docs describe the
  outcome + mechanism but not the discovered-never-fetched provenance
  specifically; for a sitemap-listed URL that provenance is satisfied by
  construction, so the gap is moot here.)
- **Yandex** — **verify before encoding** (`documentation_gap` until a primary
  quote on the URL-only-indexing-when-robots-blocked case is obtained; the earlier
  "documents similar" was not backed by a specific Yandex source).

**Emission:** the synthesis is *not* a new registered code (option a). When a
`PAGE_*_NOINDEX` finding and a `ROBOTS_DISALLOWED` decision coincide on the same
URL, attach the trap explanation as the noindex finding's `remediation_hint`,
stamped per engine. This depends on §7 (E.5 must expose a consultable decision)
and on the §8 findings-encoding change (producer `remediation_hint` is nulled by
the assembler today).

**Message discipline (ADR-009 provenance + Codex finding 12):** stamp per-engine
provenance; only assert the mechanic for engines where it is `documented`
(Google, Bing today; Yandex pending). Remediation is **intent-neutral**: state
the conflict and both possible intents, do not universally say "remove the block"
(some content should stay access-controlled; robots.txt is not a security
mechanism; removal tools are not a permanent substitute). Point the user to the
engine's admin panel for live status.

Draft message (engine-stamped): *"This URL is advertised in the sitemap,
disallowed by robots.txt, and also carries a `noindex` (source: `<meta robots>` /
`X-Robots-Tag`). Per {Google|Bing} documentation, robots.txt prevents the engine
from fetching the page, so it will never see the `noindex` — the URL may still be
indexed without a description if other pages link to it. If the intent is to keep
it out of the index, allow crawling so the `noindex` can be read (or use the
engine's removal tool); if the intent is only to block crawling, the `noindex`
has no effect. Verify live status in the engine's admin panel."*

---

## 6. Contract D — public API surface + coverage metadata (engine-neutral)

The fourth contract the v2 changelog promised but never defined. Engine-neutral:
it fixes *how a caller turns page inspection on and what the run reports about its
own coverage*, independent of any per-engine fold (§5).

### 6.1 Parameter surface

`validate_sitemap()` and `validate_sitemap_ruleset()` (plus the batch variants)
gain an opt-in group, mirroring the existing `check_robots` / `robots_user_agent`
shape (`R/validate-sitemap.R:853`):

- `inspect_pages = FALSE` — master opt-in, default **off**; network expansion is
  never implicit (§10 open decision 5).
- `page_sample = <N>` + `page_mode = c("sample", "full")` — selection (§3.3): a
  deterministic sample of size N by default (stable hash order over deduped locs,
  so re-runs pick the same set), or `full` = all deduped locs subject to the caps.
- `page_budget` — a list carrying the §3.3 caps (max pages, max requests, max
  aggregate bytes, per-page body cap, max wall time), each caller-overridable with
  a safe default.
- `page_user_agent` — the HTTP request User-Agent actually sent (§3.1), recorded
  for the "what did the inspector see" caveat; **distinct** from any engine product
  token (ADR-009 §1). Defaults to sitemapr's inspector UA.

No parameter changes the pinned ten-column result shape; coverage rides its own
attribute (§6.2).

### 6.2 Coverage metadata

A sampled or capped run must report what it actually covered, so a reader never
reads "not sampled" as "clean". Coverage is returned as a **named attribute** on
the findings tibble (`attr(x, "page_coverage")`), **not** as findings rows — a
run's self-coverage is a property of the run, not of the sitemap. Shape:

- `eligible` — absolute http(s) locs that qualified for inspection.
- `deduplicated` — distinct fetch keys after §3.3 dedup.
- `selected` — how many selection picked (`= deduplicated` in `full` mode).
- `attempted` / `completed` — fetches started vs. those reaching a `usable_body`
  or `partial` outcome.
- `partial` — how many hit the per-page cap (`outcome = partial`).
- `caps_hit` — which caps bit (max-pages / max-bytes / wall-time / …), so a
  truncated `full` run is explicitly marked partial, never silently truncated.

The registry's `INSPECTION_*_CAP_HIT` rows are **not** reused here — they stay
reserved for a later decision to surface a cap as a finding. This slice keeps caps
in the coverage attribute only, so no legacy findings widen.

### 6.3 audit / streaming / report inclusion

- **`audit_sitemap()` (`R/audit-pipeline.R:648`): out of scope for v0.2.** It
  carries neither ruleset nor robots args and **streams** (the combined `urls`
  tibble retains no rows — `audit_stream_read`), so per-URL page findings have
  nowhere to attach. Page inspection is **validate-side only** for v0.2; the audit
  path is a later decision (§10 open decision 4) — stated as an explicit exclusion,
  not assumed away.
- **Report rendering must learn the `page` and `robots` layers.** `report.R`'s
  `report_layer_order` (`R/report.R:44`) omits both, and the renderer filters
  findings to that list (`R/report.R:591`), so page findings would be dropped — and
  shipped E.5 `robots` findings **already are**. Adding the two layers to
  `report_layer_order` is a **precondition** for any `page`/`robots` finding to
  render. This predates Layer E and is filed as its own bug; E.1 depends on it.

---

## 7. E.5 refactor prerequisite — a consultable robots decision

The completed E.5 producer (`validate_robots`, `R/robots-validate.R`) returns
**findings only**: allowed URLs produce no row and the internal `decisions`
object is discarded. So "E.3/synthesis consults E.5's per-URL result" is **not
implementable as-is**. Required enabling refactor (small, precedes §5.4):

- Extract robots evaluation into an internal **facts/decisions producer** that
  returns a per-URL decision object (mapping onto ADR-009 §2 outcome fields), and
  derive **both** the `ROBOTS_*` findings **and** the §5.4 synthesis from it.
- Gate the synthesis on robots evaluation actually being **enabled and available**
  (`check_robots = TRUE` and `robotstxtr` present); otherwise the noindex findings
  stand alone with no synthesis.
- This is a refactor of *done* code — it must preserve E.5's current findings
  output exactly (ADR-009 §5 back-compat).

---

## 8. ADR-009 conformance checklist

- **No `profile`/`target_engine` scalar.** Engine interpretation keys off the
  existing independent axes via `validate_sitemap_ruleset()` + `ruleset_context()`.
  The "which crawler do these page directives target" concept reuses the
  product-token axis idea; the **HTTP request User-Agent stays distinct** from it.
  **Open contract question:** page-directive interpretation (§5.1 fold, §5.3
  hreflang) may need either (a) a documented per-engine fold table in
  `docs/sitemap-spec.md` keyed off an existing axis, or (b) an ADR-009 amendment
  adding a `page_directive_ruleset` axis. Axes are ADR-owned — this cannot be
  invented in an implementation slice. **Settle before E.3/E.4 file.**
- **Provenance on every cell** (§5 tables). Diagnostic-only cells never drive a
  verdict.
- **Six-field outcome model** reused for the page-fetch outcome (§3.1
  `evidence_status`) and, where a page verdict is warranted, the resolved/
  context_required/undocumented distinction rather than a bare enum.
- **Safety precedence** (§3.2): SSRF/budget are their own outcomes.
- **Findings encoding — corrected (v2 was wrong here).** The pinned `evidence`
  list is **frozen** to `excerpt`/`line`/`column` (`findings-contract.md:30`;
  `finding_evidence()`, `findings-assemble.R:66`), and the assembler
  **overwrites every producer `remediation_hint` with `NA`**
  (`findings-assemble.R:307`) — so today *no* finding carries a hint at all. v2's
  "channel/crawler-scope/raw-token/source-location live in `evidence`" would be a
  silent widening of a **cross-repo shared surface** (the registry is shared with
  `sitemap-validator`), which §2 forbids. Resolution (both scoped as §10 open
  decision 6):
  - **Structured page context** (channel, crawler scope, raw token, source
    location) rides the **engine-aware `context` list-column** — the schema-v2
    additive surface (`ruleset`/`ruleset_revision`/`context`/`provenance`) that
    already exists for exactly this — **not** the frozen `evidence` list. A
    normalized human string may still go in `evidence$excerpt` (free-form ≤500 ch).
  - **§5.4 synthesis text** in `remediation_hint` requires a **local Layer F
    change**: the assembler must carry a producer-supplied `remediation_hint`
    instead of nulling it. `remediation_hint` is already a pinned column, so this
    is not a contract widening — but it changes every producer's tibble shape and
    the row-bind, so it is scoped explicitly, not assumed.
- **Bing gaps** stay gaps *only where undocumented* — but Bing's URL-only indexing
  (§5.4) and cross-channel most-restrictive (§5.1) **are** documented, so they are
  `documented`, not gaps.
- **mode strict/non-strict** may only alter presentation/severity/filtering, never
  the underlying page facts or decision.

---

## 9. Sources (primary only; provenance of *our verification*)

`[V-direct]` fetched & quoted this session; `[V-hreflang]`/`[V-robots]`/`[V-bing]`
agent-verified this session (2026-07-19); verify others before shipping.

**Indexing directives / robots.txt × noindex:**
- Google — Robots meta tag / X-Robots-Tag: https://developers.google.com/search/docs/crawling-indexing/robots-meta-tag **[V-robots]**
- Google — Block Search indexing with noindex: https://developers.google.com/search/docs/crawling-indexing/block-indexing **[V-direct]**
- Google — Introduction to robots.txt: https://developers.google.com/search/docs/crawling-indexing/robots/intro **[V-direct]**
- Bing — Robots Meta Tags & attributes Bing supports: https://www.bing.com/webmasters/help/robots-meta-tags-and-attributes-that-bing-supports-5198d240 **[V-robots]**
- Bing — Block URLs from Bing: https://www.bing.com/webmasters/help/block-urls-from-bing-264e560a **[V-bing]** (the NOINDEX-behind-robots trap, verbatim)
- Bing — Robots.txt tester (URL-only result, no description): https://www.bing.com/webmasters/help/robots-txt-tester-623520ca **[V-bing]**
- Bing — Missing info / cannot show a description: https://www.bing.com/webmaster/info/missinginfo **[V-bing]**
- Yandex — Meta robots: https://yandex.com/support/webmaster/en/controlling-robot/meta-robots.html **[V-robots]**
- Yandex — HTML directives / X-Robots-Tag: https://yandex.com/support/webmaster/en/controlling-robot/html **[V-robots]**
- *(Yandex robots.txt × noindex URL-only-indexing case: NOT yet sourced — verify before encoding §5.4 Yandex.)*

> **Repro note:** the Bing help pages are JS-rendered SPAs; plain WebFetch returns
> only the shell. They must be browser-rendered (cf-crawl) to read. Mildly ironic
> given §1's unrendered-snapshot point — and a reminder to verify Bing quotes via a
> render, not a raw fetch.

**hreflang / localization:**
- Google — Localized versions of your pages: https://developers.google.com/search/docs/specialty/international/localized-versions **[V-hreflang]**
- Google — Managing multi-regional sites: https://developers.google.com/search/docs/specialty/international/managing-multi-regional-sites **[V-hreflang]**
- Google — 2012 blog (hreflang origin): https://developers.google.com/search/blog/2012/05/multilingual-and-multinational-site **[V-hreflang]**
- Yandex — Locale pages (sitemap hreflang discontinued): https://yandex.com/support/webmaster/en/yandex-indexing/locale-pages **[V-hreflang]**
- Bing — hreflang (on-page example; only recent primary mention): https://blogs.bing.com/webmaster/December-2025/Does-Duplicate-Content-Hurt-SEO-and-AI-Search-Visibility **[V-hreflang]**

**Canonical:**
- Google — Consolidate duplicate URLs (canonical; HTTP `Link`; sitemap = weaker signal): https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls *(verify before encoding §5.2 detail)*

**JavaScript rendering (the unrendered-snapshot caveat):**
- Google — JavaScript SEO basics (Google renders JS): https://developers.google.com/search/docs/crawling-indexing/javascript/javascript-seo-basics *(verify before encoding §1 wording)*

**Sitemap base protocol:**
- sitemaps.org protocol: https://www.sitemaps.org/protocol.html **[V-hreflang]**

---

## 10. Open decisions (to settle at issue-filing)

> **RESOLVED — historical.** Every decision below is settled in §0 (D1/D8→§0.3,
> D2/D3→E.3, D4→§0.2, D5+D7→§0.4/ADR, D6→§0.7/§0.10). Retained to show the
> reasoning; §0 and the live `fp` tree are authoritative.

1. **ADR-009 axis for page-directive interpretation** (§8) — documented fold
   table on an existing axis, vs. an ADR-009 amendment adding
   `page_directive_ruleset`. Axes are ADR-owned; must settle before E.3/E.4 file.
2. **§5.4 synthesis emission** — confirmed as `remediation_hint` on the existing
   noindex codes (option a, no new code), gated on the §7 E.5 refactor **and** the
   §8 encoding change (the assembler nulls producer hints today). Keep, or promote
   to a registered synthesis code (registry migration + cross-repo)? Leaning keep.
3. **Yandex §5.4** — obtain a primary source for robots-blocked URL-only indexing,
   or leave the synthesis message Google/Bing-only.
4. **audit_sitemap page inspection** (Contract D / §1) — opt-in on validate-side
   only for v0.2, and explicitly *not* on the streaming `audit_sitemap` path
   (which retains no rows)? Leaning validate-side only; revisit audit later.
5. **New ADR for opt-in network expansion?** — page inspection fetches advertised
   *page* URLs, a deliberate opt-in network expansion with a budget and API
   surface. This is *not* an ADR-007 exception (ADR-007 only constrains
   `probe_url()` from resolving sitemap children — v1's framing was wrong). If an
   ADR is warranted it is about opt-in expansion + budgets + default-off network
   behavior, justified on its own terms.
6. **Findings encoding for page context** (§8) — structured evidence via the
   engine-aware `context` list-column (not the frozen `evidence` list); synthesis
   text via a local assembler change letting producers supply `remediation_hint`
   (nulled at `findings-assemble.R:307` today). Both must be scoped before
   E.2/E.3/E.4 file; the `context`-column reuse is additive, the assembler change
   is Layer F. Leaning: context-column + `remediation_hint` pass-through.
7. **ADR-003 page-fetch amendment** (§3.2) — the truncate-and-retain per-page cap
   is a new page-specific fetch contract beside the 500 MB discard ceiling. Amend
   ADR-003 (or a dedicated page-fetch ADR) before E.1 files. Leaning: an ADR-003
   "page inspection" subsection; the discard ceiling stays the outer backstop.
8. **Provenance one-tag-per-cell** (§5.1/§5.3 tables) — split the Google cells that
   carry both `documented` and `inferred` into one-fact-per-row at decomposition
   (ADR-009 / `sitemap-spec.md`: one atomic fact + one provenance tag per cell).

---

## 11. Decomposition preview (file after §10 settles)

> **SUPERSEDED by §0.8.** E.1 is split into E.1a/E.1s/E.1f and the sitemap-blocked
> check was added; the live `fp` tree is authoritative for the decomposition.
> Historical.

- **Parent SITE-ihycidfl** — re-scope: E.5 done; remaining = the engine-
  parameterized `page` layer (E.1–E.4) over registered `PAGE_*` codes + fetch
  infra; drop the dead `_scratch` ref; link this spec.
- **E.1 (fleshed)** — Contract A (page-fetch artifact + budget) + Contract D
  (param surface + coverage) + the §3.4 transport checks (`PAGE_STATUS_*`,
  `PAGE_REDIRECT_*`, `PAGE_FETCH_FAILED`, `PAGE_SSRF_BLOCKED`) on
  `validate_sitemap`/`validate_sitemap_ruleset`. Engine-neutral. Depends on the
  §6.3 report-layer fix and the §10 open decision 7 (ADR-003 amendment).
- **Report-layer bug (independent, precedes any `page`/`robots` output)** — add
  `page` + `robots` to `report_layer_order` (`R/report.R:44`); already hides
  shipped E.5 `robots` findings. Filed separately.
- **E.1b / prerequisite (small)** — §7 E.5 facts/decisions refactor (enables
  synthesis; preserves E.5 output).
- **E.2 (stub)** — canonical (`PAGE_CANONICAL_*`), §5.2.
- **E.3 (stub)** — effective noindex (`PAGE_META_ROBOTS_NOINDEX`,
  `PAGE_XROBOTSTAG_NOINDEX`) + §5.4 synthesis hint, §5.1, three-stage fold.
- **E.4 (stub)** — hreflang reconciliation (`PAGE_HREFLANG_MISMATCH`), §5.3.
- **SITE-wrylygzd** — stays the cross-repo code-alignment tail of E.5.
