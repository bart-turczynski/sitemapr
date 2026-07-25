# ADR-010: Opt-in page inspection — network expansion, page-fetch body contract, and safety/resource precedence

- Status: Accepted
- Date: 2026-07-19
- Deciders: Bart Turczyński
- Related: `docs/design/layer-e-page-inspection.md` (governing spec — read §0
  first; §0.2, §0.4, §0.5 govern this ADR), `docs/decisions/ADR-009-per-engine-validation-profiles.md`
  (evidence-status enum, safety precedence — **amended by this ADR, §2**),
  `docs/decisions/ADR-003-network-safety-policy.md` (SSRF guard, resource
  ceilings — **amended by this ADR, §2/§3**),
  `docs/decisions/ADR-007-api-entry-points.md` (public entry points / `probe_url()`),
  `docs/findings-registry.csv` (the pinned `PAGE_*` codes and their severities),
  SITE-ndwnfyer (this ADR), SITE-ihycidfl (Layer E epic).

---

## Context

Layer E adds **opt-in, per-URL page inspection**: given a sitemap's advertised
URLs, fetch a sample of the **page bodies** and compare what the page *declares*
(HTTP response + HTML head: canonical, meta robots, `X-Robots-Tag`, hreflang)
against what the sitemap *asserts*. v1 never fetched page bodies — it fetched
sitemap documents and their children only. Page inspection is therefore a
deliberate **network expansion**, and three decisions must be settled before the
fetch spine (E.1a → E.1s → E.1f) is implemented, because they cut across the
accepted network-safety and evidence-status contracts:

1. **Is page-body fetching a new ADR-007 exception, or justified on its own
   terms?** ADR-007 accepts exactly one non-resolving inspection entry point
   (`probe_url()`), which *classifies* a URL and **counts** an index's children
   but never fetches them (ADR-007 §2). Page inspection fetches something ADR-007
   never contemplated — the advertised pages themselves — so its authority to
   reach the network needs an explicit basis.
2. **How does a page fetch record a body it deliberately truncated?** The
   inspector only needs the head region, so the page path caps the body far below
   ADR-003's 500 MB per-resource ceiling and **retains the prefix**. The accepted
   ADR-009 §3 rule resolves *any* reached body ceiling to `incomplete` (no usable
   body). That is wrong for an intentional truncate-and-retain window, where the
   retained head is real and usable.
3. **How do a safety refusal and a resource-ceiling discard differ at the page
   layer?** Both stop a fetch, but they are different failures: an SSRF / scheme /
   downgrade refusal is a *safety* verdict; hitting the 500 MB per-resource
   ceiling is a *resource* failure. Collapsing them would mislabel a large but
   legitimate page as an attempted-SSRF block.

A multi-round design review (Codex, four rounds; folded into the governing spec's
authoritative §0) settled these. This ADR records the decisions; no
implementation and no emission matrix land here (E.1f owns the outcome→code map;
the findings registry owns severities).

---

## Decisions

### 1. Page-body inspection is an opt-in network expansion, justified on its own terms — not an ADR-007 exception

Page inspection is **default-off**. It runs only when the caller explicitly opts
in (`inspect_pages = TRUE`, the E.1f / Contract D parameter surface), and only
over a **budgeted** sample (E.1s: caller-overridable caps on pages, requests,
aggregate bytes, per-page body bytes, and wall time — governed by ADR-003 §3's
"all limits configurable, no non-overridable hard caps" rule). With page
inspection off, behavior is **byte-identical to v1**: the pinned ten-column
findings surface, no page fetches (governing spec §0.2 acceptance (a)).

This authority is **not** carried as an ADR-007 exception. ADR-007 governs the
*sitemap* entry points and constrains `probe_url()` to non-resolving
classification that counts children but never follows them; it says nothing about
fetching advertised pages. Page inspection is justified **on its own terms** by
the conjunction it ships with:

- **opt-in** — never reached unless the caller asks for it;
- **default-off** — the zero-config surface makes no page requests;
- **budgeted** — a dedicated aggregate budget bounds the expansion, distinct from
  (and far tighter than) the ~500 MB-per-resource inheritance that suits fetching
  one sitemap but not fetching many pages.

The SSRF guard, redirect revalidation, and per-resource ceiling of ADR-003 apply
unchanged to every page request; page inspection **adds a budget on top of**
ADR-003's safety envelope, it does not weaken it.

### 2. Page-fetch body contract: `partial` is truncate-and-retain — amends ADR-009 §3 and ADR-003

The page fetch reuses the shared ADR-009 §2 `evidence_status` enum (the page
artifact's `outcome`). `partial` is **already** a member of that enum
(ADR-009:104) — this ADR does **not** add an enum value. It resolves the
*ceiling→status* rule that the accepted ADR-009 §3 got wrong for the intentional
page cap, via **direct edits** to the two governing ADRs:

**(a) Amend the ADR-009 §3 body-ceiling rule.** Accepted ADR-009 §3 maps a
reached body ceiling uniformly to `incomplete`. Split it by intent:

- an **intentional per-page truncate-and-retain cap** (the page path, §2(b))
  resolves to `evidence_status = partial` — the body was cut at the page cap but
  the **retained head-region prefix is usable**, so head-derived facts are real;
- a **deadline / transport failure yielding no usable body**, and the **500 MB
  per-resource discard backstop** (§3), resolve to `incomplete` — no usable body.

`partial` is never `allow_all` / `disallow_all` and never an engine verdict;
per ADR-009 §2's state table a `use_rules` result over a `partial`/unusable body
carries `matcher_status = not_evaluated`, `url_decision` absent.

**(b) Page-cap `partial` semantics.** The per-page body cap (single-MB range,
caller-overridable; §1 budget) is a **truncate-and-retain** bound: on reaching it,
the fetch stops, **keeps the body prefix**, and marks the artifact `truncated`.
The retained prefix is treated as usable for head-region extraction. An **absence
read from a `partial` body is `unknown`, not `missing`** — it flows to the
Contract B extraction status as `unknown` and **must not** produce an
absence-derived finding (a signal could sit past the truncation point). A
`partial` outcome emits **no transport finding**; the truncation is recorded only
in the artifact and the coverage metadata (governing spec §3.2, §6.2).

**(c) Add an ADR-003 page-cap subsection.** ADR-003 §3 gains the per-page cap as a
**truncate-and-retain** control that sits **inside** the existing 500 MB
per-resource safety ceiling. The 500 MB ceiling is unchanged and remains the outer
**discard** backstop (ADR-003 §3: exceeding it discards the body). The two are
distinct bounds: the page cap keeps a small usable prefix by design; the 500 MB
ceiling discards everything as a memory-bomb backstop.

### 3. Safety and resource controls are distinct, and both dominate crawler policy — with a fixed precedence

Local **safety** refusals and **resource** limits both stop a fetch, but they are
different outcomes and map to different page codes. This ADR keeps them distinct
(governing spec §0.5) and pins their precedence:

- **SSRF address block / non-HTTP(S) scheme / HTTPS→HTTP downgrade rejection** →
  `evidence_status = safety_refused` → **`PAGE_SSRF_BLOCKED`**. A *safety* verdict.
  `PAGE_SSRF_BLOCKED` is **reserved for these three refusal classes only**.
- **500 MB per-resource ceiling discard** → a *resource/transport* failure (no
  usable body; §2(a) `incomplete`) → **`PAGE_FETCH_FAILED`**, **not**
  `PAGE_SSRF_BLOCKED`. A large-but-legitimate page is a resource failure, not an
  attempted SSRF. (This corrects the superseded governing-spec §3.4 matrix, which
  routed the 500 MB discard to `PAGE_SSRF_BLOCKED`.)
- **Per-page truncate-and-retain cap** → `partial` (§2) → no transport finding.

**Precedence when outcomes overlap on one logical fetch** (a URL is one logical
fetch of possibly several HTTP requests): **`safety_refused` > terminal
`http_status` > redirect (resolved / over-budget)** (governing spec §0.11). A
safety refusal or a terminal HTTP error outranks any redirect observation; **at
most one transport finding** is emitted per URL.

The concrete outcome→code emission matrix, the remaining transport mappings
(`http_status`, `http_protocol_error`, `transport_fail`, `redirect_over_budget`,
`not_applicable`), and any registry severity are **owned downstream** — E.1f and
`findings-registry.csv`, not this ADR. Any change to a registered `PAGE_*`
severity is a coordinated cross-repo registry migration, never a silent flip.

---

## Consequences

### Positive

- The network expansion has an honest, self-standing justification (opt-in +
  default-off + budgeted); no zero-config user pays for a feature they did not
  request, and the authority does not overload ADR-007's sitemap-entry contract.
- The truncate-and-retain page path reads the head region cheaply while staying
  strictly inside ADR-003's safety envelope; `partial` distinguishes "usable head,
  cut tail" from "nothing usable", so absence findings never fire on a truncated
  body.
- Safety and resource failures stay separable: a 12 GB page reports
  `PAGE_FETCH_FAILED`, not a false `PAGE_SSRF_BLOCKED`, keeping the SSRF signal
  meaningful.

### Negative / accepted trade-offs

- Two body bounds now coexist (per-page cap + 500 MB ceiling) with different
  semantics (retain vs discard). Accepted — the retain-vs-discard distinction is
  exactly what makes head extraction cheap without weakening the memory backstop.
- `partial` is a third body state alongside `usable_body` / `incomplete`, so every
  extractor must handle "usable but possibly incomplete". Accepted — collapsing it
  into either neighbor would either drop real head facts or emit false absences.
- The precedence rule and the safety/resource split add contract surface E.1f must
  implement exactly. Accepted — it is the price of one-finding-per-URL honesty.

### Amendments carried by this ADR

- **ADR-009 §3** — body-ceiling rule split by intent (`partial` for the
  intentional page cap; `incomplete` for no-usable-body / the 500 MB discard).
- **ADR-003 §3** — per-page truncate-and-retain cap added as an inner bound; the
  500 MB per-resource ceiling stays the outer discard backstop and its page-layer
  code is `PAGE_FETCH_FAILED` (resource), distinct from `PAGE_SSRF_BLOCKED`
  (safety).

### Non-goals (this ADR)

- No emission matrix, no severities, no code (E.1f + registry own these).
- No robots-access / interpretation decisions (ADR-009 + robotstxtr engine-contract-v1
  own those; see governing spec §0.3).
- No streaming / `audit_sitemap()` path, no rendered (JS) fetch — the page fetch
  is an **unrendered** snapshot (governing spec §0.2 non-goals).
