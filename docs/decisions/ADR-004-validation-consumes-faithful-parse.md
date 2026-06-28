# ADR-004: validation layers consume a faithful parse, not the typed tibble

- Status: Accepted
- Date: 2026-06-28
- Deciders: Bart Turczyński
- Related: `docs/architecture.md` (§3 layer model, §4 slice map, §7 output
  contracts); `docs/sitemap-spec.md` (§4 field semantics, §7 Layer D);
  `docs/findings-contract.md`; SITE-fraetonj (D.1), SITE-ysviepus (D.2),
  SITE-jlpihcap (D.6), SITE-ymzvnlpr (Layer F)

---

## Context

The architecture (§4) describes both validation layers identically:
**"Parsed doc → findings."**

- **Layer C** (`validate_schema(doc, …)`) honors this — it takes the raw
  `xml2` document. Nothing is coerced or lost before validation.
- **Layer D** (`validate_protocol(rows, …)`), as first implemented in D.1,
  took `read_sitemap()`'s **typed tidy tibble** instead.

That tibble is the `read_sitemap()` public output contract: `lastmod` is
`POSIXct`, `priority` is `numeric` (`docs/architecture.md` §7, PRD §4). That
projection is correct **for that output** — callers filter with dplyr rather
than re-parsing strings. The problem is feeding the *projection* back into
**validation**, because the projection is lossy in exactly the dimensions some
Layer D field rules must inspect:

| Field | Parser coercion | Information destroyed |
|---|---|---|
| `lastmod` | `parse_lastmod()` → `POSIXct` | malformed → `NA` (indistinguishable from absent); date-only `YYYY-MM-DD` → midnight (indistinguishable from a midnight datetime) |
| `priority` | `parse_priority()` → `numeric` | unparseable text → `NA` (indistinguishable from absent). Latent only: there is no `PROTOCOL_PRIORITY_*` code for "not a number" (XSD `xs:decimal` catches it at Layer C), and out-of-range values *do* survive as numbers, so the range rule still works. |
| `changefreq` | kept as `character` | nothing — safe by construction |

D.2 (`PROTOCOL_LASTMOD_INVALID` / `PROTOCOL_LASTMOD_DATE_ONLY`) is where the
loss actually bites: the checks need exactly the bytes coercion threw away. The
D.2 slice patched this with a `lastmod_raw` side-channel parameter on
`validate_protocol()`. That works, but it patches one field rather than fixing
the layer-input mismatch, and it makes Layer F responsible for threading raw
strings alongside the typed rows.

The friction is **not** that `POSIXct` is used "too early" in some absolute
sense — `read_sitemap()`'s output is rightly typed. It is that **Layer D was
wired to the user-facing lossy projection instead of a faithful parse**, unlike
Layer C.

---

## Decision

**Validation consumes a faithful parse; coercion to the typed tibble is a
`read_sitemap()` projection, not a validation input.**

1. **Layer D's logical input is the faithful, string-preserving parse** of a
   document — the same representation Layer C already validates against, just
   field-extracted. Field-format rules (`lastmod`, and any future
   string-format rule) read the original text; range/enum rules read whatever
   form is non-lossy. POSIXct/numeric coercion happens **after** (or
   independently of) validation, on the path that produces the
   `read_sitemap()` tibble.

2. **The typed 9-column row tibble remains the `read_sitemap()` output
   contract, unchanged.** This ADR does not add or change a public column.
   `lastmod` stays `POSIXct`, `priority` stays `numeric`. The faithful parse is
   an *internal* representation feeding validation, not a new public surface.

3. **Implement this when D.6 / Layer F wires the parse→validate data flow**,
   not as an isolated refactor now. `validate_sitemap()` (Layer F) does not yet
   exist, and `validate_protocol()` currently has no production caller — only
   D.2's unit tests. Layer F will already hold the raw doc/bytes (it needs them
   for Layer C schema validation), so it is the natural owner of "parse once,
   keep raw, coerce late." Building a faithful-intermediate emitter in the
   parser today, with no consumer, would be speculative plumbing.

4. **At the D.6 wiring point, retire or absorb the `lastmod_raw` side-channel.**
   Once Layer D receives a faithful parse, the original `<lastmod>` strings
   arrive through that representation. Whether `validate_protocol()` takes a
   small "raw rows" intermediate or extracts from the doc directly is a D.6
   implementation choice; either way, the dedicated `lastmod_raw` argument
   stops being a special case. The same representation also removes `priority`'s
   latent NA-overload from the validation path.

The likely shape (not binding on D.6): the format parsers produce **one**
faithful field extraction; `read_sitemap()` projects it to the typed tibble;
Layers C and D validate the faithful form. "Parse once → faithful intermediate
→ validate + project late."

---

## Consequences

### Positive
- Layer C and Layer D share one mental model: both validate a faithful parse,
  matching `architecture.md` §4. No layer reads a lossy downstream projection.
- Field-format rules become expressible without per-field side-channels.
- `priority`'s latent absent-vs-unparseable ambiguity is removed from the
  validation path as a side effect.
- The `read_sitemap()` typed contract is untouched; this is purely an internal
  data-flow correction.

### Negative / accepted trade-offs
- Until the faithful-parse unwind lands (now scheduled for Layer F — see the
  Update below), `validate_protocol()` keeps the interim `lastmod_raw`
  parameter — a documented seam, not the final interface.
- A faithful intermediate is a second internal representation of a parsed
  document alongside the typed tibble. The two must stay consistent; the chosen
  design should derive the typed tibble *from* the faithful form (projection),
  not parse twice, so there is a single source of truth.

---

## Update (2026-06-28 — D.6 / SITE-jlpihcap)

D.6 implemented its diagnostics but **deferred the faithful-parse unwind to
Layer F** (`validate_sitemap()`, SITE-ymzvnlpr), refining decision point 3 and
point 4 above. Rationale: the unwind is a single coordinated change across the
parser (emit a faithful, string-preserving extraction), `read_sitemap()`
(project that to the typed tibble late), and Layer F (feed the faithful form to
both Layer C and Layer D). Layer F is the component that holds the raw doc/bytes
and is the only place the end-to-end flow can be integration-tested. Doing it at
D.6 — which still has no production caller for `validate_protocol()` — would have
churned the protocol test suite to construct a faithful shape nothing in
production emits, with no integration verification, and a partial "swap only
`validate_protocol()`'s input" half-measure was rejected as worst-of-both
(test churn without removing the root coercion in the parser).

Net effect on decision point 4: **the `lastmod_raw` side-channel is retired at
Layer F, not at D.6.** It remains the documented interim seam until then. D.6
itself adds only the `source_meta` argument (classification + encoding
diagnostics), which is orthogonal to the faithful parse.

## Revisit conditions
- D.6 / Layer F implementation diverges from "parse once, coerce late" (e.g.
  it proves cheaper to re-extract from the doc inside `validate_protocol()`
  than to thread an intermediate) — update this ADR to record the actual seam.
- A future string-format protocol rule on a *different* field surfaces the same
  loss, confirming the general fix was the right call (or revealing a field the
  faithful parse still drops).
