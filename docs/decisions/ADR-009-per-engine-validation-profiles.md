# ADR-009: Per-engine validation profiles (rulesets, outcomes, capability negotiation)

- Status: Accepted
- Date: 2026-07-16
- Deciders: Bart Turczyński
- Related: `docs/decisions/ADR-003-network-safety-policy.md` (safety precedence),
  `docs/decisions/ADR-006-robots-sitemap-discovery.md`, `docs/findings-contract.md` +
  `docs/findings-registry.csv` (the cross-repo findings contract this mirrors),
  robotstxtr `design/PRD.md` (matcher scope / non-goals),
  SITE-mnahrdnt (sitemap validation profiles), SITE-ofdqaeju (Layer E robots check).
  Sibling specs governed by this ADR: sitemapr `docs/sitemap-spec.md` (sitemap rules),
  robotstxtr `design/engine-profiles.md` (robots status-policy + matcher/limits).

---

## Context

sitemapr validates sitemaps and (opt-in) consumes robotstxtr to answer "does robots.txt allow this
URL?". Both questions have engine-dependent answers: sitemaps.org / Google / Bing / Yandex differ on
sitemap scope, formats, and limits, and RFC 9309 / Google / Yandex differ on how a robots.txt HTTP
status maps to a crawl decision (Bing publishes almost nothing). Today robotstxtr bakes in one
partial policy and sitemapr treats scope as pure protocol conformance; neither lets the caller say
*which engine* they mean.

A multi-round design review established that a naive "profile" abstraction would be unsafe:
it would let one engine's documented behavior stand in for undocumented cells, collapse independent
facts (submission vs discovery vs authority) into one blob, imply matchers that do not exist, and
silently break the pinned findings and result schemas. This ADR records the **approved vocabulary and
contracts** that the two sibling specs and all implementation slices must conform to. It is a decision
record; no engine matrices and no implementation land here.

Key external constraints that shaped these decisions:

- A stateless tool **cannot** reproduce "what would this crawler do" for 5xx/network: Google and RFC
  behavior depend on cache age, last-known-good rules, failure duration, and site availability
  (Google robots.txt spec; RFC 9309 §§2.3.1.4, 2.4).
- The vendored Google matcher (`robotstxt-cpp`) is **intentionally not strict RFC 9309** and
  robotstxtr's PRD forbids RFC-correcting it, so a ruleset name is not the same thing as a matcher.
- sitemapr's findings table is an exact ten-column compatibility contract and the assembler strips
  extra producer fields; robotstxtr's public functions have pinned result schemas.

---

## Decision

### 0. Load-bearing principle: neutral mechanics, per-engine interpretation, provenance-gated

Separate **engine-neutral mechanics** (fetching, safety, resource limits) from **per-engine
interpretation** (policy, matching, rules). Only **executable** provenance classes may drive an
engine-specific verdict; the rest stay **diagnostic** (softened findings), never a fabricated verdict.
Every engine/rule cell carries exactly one provenance tag:

- **Executable:** `documented` (quoted from the engine's current primary source) ·
  `inherited_protocol` (explicitly inherited from sitemaps.org / RFC 9309 baseline) ·
  `application_choice` (a named, deliberate product decision among permitted options).
- **Diagnostic only:** `inferred` (follows from a general rule but not stated per-case) ·
  `documentation_gap` (confirmed absent) · `documentation_conflict` (two **current** authoritative
  sources genuinely disagree) · `advisory` (a host/page-level or non-normative note, never a verdict).

**Source precedence:** current guidance supersedes historical/superseded material — a value replaced
by a newer official statement is `documented` at its current value, not a `documentation_conflict`.
Historical sources may only support historical claims (labelled as such), never a current cell.

### 1. Independent context axes (no single `profile` scalar)

Validation context is a set of **independent** axes, not one `profile` value (a bare `profile` also
collides with sitemapr's existing XSD schema-profile terminology). **This ADR owns the axes, their
independence, and the per-source inheritance/conflict invariants; the sibling specs own each axis's
extensible value set.** A named **preset** MAY populate several axes at once, but the expanded values
are what is stored and reported.

- `sitemap_ruleset` — value set owned by `docs/sitemap-spec.md` (baseline `sitemaps.org` + engine
  overlays).
- `robots_policy_ruleset` — value set owned by robotstxtr (`rfc9309` | `google` | `yandex`; bing =
  gap). Pure data; always available.
- `matcher_backend` — `google` (available) | `rfc9309`, `yandex` (capability-gated; see §4).
- `robots_product_token` — the token the caller wants rules resolved for (a **context input**).
- **HTTP request User-Agent** — the fetch header (distinct from the product token).
- `mode` — `strict` | `non-strict`. `mode` may alter **finding presentation/severity and filtering
  only**; it MUST NOT change facts, validity, `policy_action`, matcher selection, or `url_decision`.
- `submission_channel` — how the artifact was submitted (value set owned by the sibling specs; e.g.
  search_console/API, webmaster_tools, user, import). **`discovered` is not a submission value.**
- `discovery_provenance` — how the artifact was found (organic discovery, robots.txt reference,
  supplied). A robots.txt *reference used as cross-site trust* is distinct from robots.txt *discovery*.
- `property_scope` — the verified property/site a submission is bound to (does not by itself grant
  authority beyond that property).
- `authority_evidence` — **structured** per-source evidence, never a boolean: verified-property set |
  exact target-host robots.txt reference | same-location default | absent | conflicting.

**User-agent group selection is NOT a context axis** — it is a matcher/ruleset *capability* (and
carries a ruleset revision), specified in robotstxtr's engine-profiles doc, not here.

**Per-source invariant:** `submission_channel`, `discovery_provenance`, `property_scope`, and
`authority_evidence` are **per-source facts**; a sitemap-index child inherits nothing implicitly. The
sibling specs define explicit inheritance and conflict rules; authority for a child is established
only by that child's own evidence.

### 2. Outcome fields (five independent namespaces; nullability defined)

A robots result is not a single enum. It is five independent fields:

- `source_kind` — `fetched` | `supplied` | `local` (where the body came from — orthogonal to whether
  it is usable).
- `evidence_status` — `usable_body` | `partial` | `incomplete` | `http_status` | `http_protocol_error` |
  `redirect_over_budget` | `transport_fail` | `safety_refused` | `not_applicable`. This value set is
  **versioned**, and robotstxtr owns robots-specific extensions to it (the semantic invariants in this
  §2 remain ADR-owned). A `usable_body` with `source_kind ∈ {supplied, local}` resolves to
  `policy_action = use_rules` as an `application_choice` (no fetch status to interpret); the use-rules
  state rows then apply normally.
- `policy_status` — `resolved` | `context_required` | `undocumented` | `not_evaluated`.
- `policy_action` — `use_rules` | `allow_all` | `disallow_all` | absent. **Non-absent iff**
  `policy_status = resolved`.
- `matcher_status` — `available` | `not_required` | `capability_unavailable` | `not_evaluated`.
- `url_decision` — `allow` | `deny` | absent.

`policy_status = context_required` carries the missing-state fields and the documented possibilities —
never a faked single verdict, never collapsed into a bare `indeterminate`. Plus `reason` +
`provenance`. The complete valid-state table (this is the contract new APIs must map onto — note a
`use_rules` result with **no matching rule** is a real **default allow**, matching robotstxtr's
current default-no-match decision, not an absent verdict):

| Situation | `policy_status` | `policy_action` | `matcher_status` | `url_decision` |
|---|---|---|---|---|
| safety / incomplete / not-applicable | `not_evaluated` | absent | `not_evaluated` | absent |
| undocumented engine case | `undocumented` | absent | `not_evaluated` | absent |
| missing lifecycle state | `context_required` | absent | `not_evaluated` | absent |
| allow-all | `resolved` | `allow_all` | `not_required` | `allow` |
| disallow-all | `resolved` | `disallow_all` | `not_required` | `deny` |
| use-rules, but body partial/unusable (e.g. 206) | `resolved` | `use_rules` | `not_evaluated` | absent |
| use-rules, no backend | `resolved` | `use_rules` | `capability_unavailable` | absent |
| use-rules, backend, no matching rule | `resolved` | `use_rules` | `available` | `allow` (default) |
| use-rules, backend, matching rule | `resolved` | `use_rules` | `available` | `allow` / `deny` |

### 3. Safety precedence: safety and resource limits are never crawler policy

Local safety and resource controls **dominate** and are reported as their own outcomes, never
reinterpreted as an engine allow/deny:

- SSRF blocks, scheme restriction, and HTTPS→HTTP downgrade rejection → `evidence_status =
  safety_refused` (ADR-003 governs the guard).
- Fetch budget / deadline / body ceiling reached → `evidence_status = incomplete` (never `allow_all`
  or `disallow_all`).

The fetch layer accepts **caller acquisition + safety limits only**; per-engine parse limits and
excess-content behavior belong to the interpretation layer, not the fetch layer.

### 4. Capability negotiation: policy ruleset ≠ matcher backend

Selecting a `robots_policy_ruleset` does **not** imply a matcher exists. The status→decision policy is
data and always available; matching/group-selection over a fetched body is a separate capability. When
matching is requested for a ruleset with no approved backend, return `matcher_status =
capability_unavailable`; the policy result still resolves independently. A ruleset request MUST NOT
silently fall through to another engine's matcher. New matcher backends (`rfc9309`, `yandex`) are
gated on a reproducible parsing/group-selection differential, a conformance corpus, and ABI /
provenance / licensing review.

### 5. Legacy defaults and versioned APIs

Backwards compatibility is preserved by construction:

- Existing robotstxtr functions and sitemapr's exact legacy result schemas are unchanged; they are
  preserved by a **repository-specific legacy compatibility preset/adapter** — NOT a synthetic
  cross-repo engine ruleset spanning the independent axes. There is **no silent switch to `google`**.
- Engine-aware behavior is exposed through **parallel, versioned** entry points / result contracts.
  New ruleset-aware robotstxtr entry points require an **explicit** `robots_policy_ruleset`; there is
  no neutral default matcher to fall back to.
- Any change of default ruleset rides an explicit, documented **major-version** migration.

### 6. Findings encoding

Extend, don't fork, the shared findings contract (`docs/findings-contract.md`,
`docs/findings-registry.csv`):

- **Shared codes for shared semantics**, plus versioned `ruleset` / revision / context / provenance
  fields. Engine-specific codes only for genuinely engine-specific rules.
- The existing ten-column result stays a stable, legacy-compatible contract; per-engine context is
  additive via the versioned schema, never by silently widening the pinned table.

### 7. Cross-repository ownership and version compatibility

- **robotstxtr** owns robots.txt behavior and capabilities (status-policy, matchers, limits,
  user-agent selection): `design/engine-profiles.md`.
- **sitemapr** owns sitemap rules and the findings contract: `docs/sitemap-spec.md` and the findings
  registry; it also owns sitemap **authority-evidence** modeling.
- This ADR (in sitemapr) is the canonical vocabulary anchor, mirroring how the findings registry is
  canonical here and the sibling validator aligns.
- Each repo publishes its schema/ruleset revisions and its **supported sibling-version ranges**; a
  robotstxtr contract must be released before sitemapr integrates against it.

### 8. Explicit non-goals (this release)

- **Content / grammar validation** (unsupported/typo/unknown directives) is **out of scope**.
  robotstxtr stays a matcher/policy package (its PRD non-goal). If needed later, it is a separate
  project or an explicit robotstxtr v2 — **not** sitemapr parser logic. sitemapr may *display*
  robotstxtr policy findings but must not own robots grammar/parser fidelity.
- **Crawler lifecycle emulation** (cache, 30-day grace, last-known-good) is out of scope; the tool is
  stateless and returns `context_required` instead.
- **Bing robots status policy** is undocumented and is **not** invented from RFC; Bing cells stay
  gaps. Any RFC-shaped fallback is an explicit application policy (`assumed_rfc9309`), never presented
  under Bing's name.
- **A Yandex (or strict-RFC) matcher** is not built in this release (§4).

---

## Consequences

### Positive

- One vocabulary spans both repos and all slices: axes, outcome fields, safety precedence, capability
  negotiation, defaults, and findings encoding are fixed before code.
- The tool is honest: it never fabricates an engine verdict for an undocumented cell, never lets a
  safety refusal masquerade as an allow, and never implies a matcher it lacks.
- Back-compat is guaranteed: legacy functions/schemas are untouched; engine behavior is opt-in and
  versioned.

### Negative / accepted trade-offs

- More surface than a single `profile` flag: callers (and presets) deal with several axes and a
  multi-field result. Accepted — the independence is exactly what prevents the unsafe collapses the
  review found.
- `capability_unavailable` and `context_required` are real, user-visible outcomes rather than a clean
  allow/deny. Accepted — they are truthful where a single verdict would be false precision.
- Coordinated cross-repo versioning is required. Accepted — it mirrors the existing findings-registry
  discipline.

### Next steps (documentation; no implementation here)

1. robotstxtr `design/engine-profiles.md` — the robots status-policy matrix, matcher/user-agent
   selection, and limits, with per-cell provenance (requires a PRD/version-scope amendment).
2. sitemapr `docs/sitemap-spec.md` — extend the accepted spec with the per-engine sitemap rules
   (formats, the three independent scope relations — sitemap→page, index→child, authority→site —
   fetch, encoding, limits, metadata), cited to the primary sources in `docs/references.md`; research
   only known gaps (current Bing cross-site behavior; Yandex URL-length/BOM).
3. Update `docs/findings-contract.md`, `docs/findings-registry.csv`, `docs/references.md`,
   `docs/architecture.md`, and a migration note.
4. Only after those contracts are accepted: file the dependency-ordered implementation slices.
