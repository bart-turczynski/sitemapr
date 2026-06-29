# ADR-005: `<loc>` equivalence is a sitemapr lint; URL encoding conformance follows RFC-3986/3987

- Status: Accepted
- Date: 2026-06-29
- Deciders: Bart Turczyński
- Related: `docs/architecture.md` (§5 URL-stack contract); `docs/sitemap-spec.md`
  (§7 Layer D URL rules); `docs/findings-contract.md` (Protocol codes); SITE-skdnucxy;
  SITE-nsixzwux (Layer D), SITE-fraetonj (D.1 `<loc>` URL rules + IRI identity)

---

## Context

Two early-design assumptions about `<loc>` validation turned out to rest on the
canonical (`rurl`-normalized) URL form, and a review against the authoritative
spec (<https://sitemaps.org/protocol.html>) showed they were stated more
strongly than the spec warrants:

1. **Duplicate detection.** D.1 emitted `PROTOCOL_DUPLICATE_LOC` whenever two
   entries shared the same **full RFC-3986 equivalence key** (`build_loc_key()`:
   IDNA host, `%41`≡`A` unreserved-octet decoding, dot-segment normalization,
   default-port collapse, host-case folding). The internal spec described this
   as "the sitemapr-owned normalized full-URL key."

2. **The canonical form was framed as a dedup/scoping key**, with a standing
   worry that normalizing URLs at all is "modifying when we should be
   validating."

What sitemaps.org actually says:

- On duplicates and URL comparison: **silent.** The spec never forbids the same
  URL appearing twice and never defines URL equivalence or normalization.
- On how URLs must be written: **mandated.** *"All URLs ... must be URL-escaped
  ..."* and *"Please check to make sure that your URLs follow the RFC-3986
  standard for URIs, the RFC-3987 standard for IRIs, and the XML standard."* The
  file *"must be UTF-8 encoded."*

So: declaring `/a/../b` ≡ `/b` or `%41` ≡ `A` a "duplicate" is a sitemapr
interpretation the spec does not require — but verifying a URL is properly
escaped per RFC-3986/3987 **is** a spec rule we were not yet surfacing.

### The reframe

The canonical form is not a modification we apologize for. **The delta between
the raw `<loc>` and its RFC-3986/3987-canonical form is itself the validation
signal.** We never replace the user's URL (the `read_sitemap()` tibble and every
finding's `subject_ref` carry the original bytes — ADR-004 posture preserved);
we compute what the URL canonically resolves to and report the *difference*.
Two distinct, spec-grounded findings fall out of that comparison, plus the
existing malformed-escape check.

---

## Decision

### 1. `<loc>` equivalence is a sitemapr lint, not a protocol rule

It stays (it is genuinely useful — duplicate/equivalent URLs waste crawl
budget), but it is documented as a **sitemapr-added lint** the spec does not
mandate, and it is communicated by *degree of confidence*, not as a flat
"duplicate":

| Case | Detection | Code | Severity | Message shape |
|---|---|---|---|---|
| Byte-identical `<loc>` repeats | raw-string equality | `PROTOCOL_DUPLICATE_LOC` | **warning** | "identical to entry N" |
| Canonical forms match, raw bytes differ | canonical-key match, raw differs | `PROTOCOL_URL_EQUIVALENT` | **info** | "likely resolves to the same URL as entry N: `Y`" |

Rationale for the severity split: a byte-identical repeat is almost always an
authoring mistake (`warning`); a canonical collision can be intentional (e.g.
two IRIs that map to one URI), so it is advisory (`info`) and names the resolved
form `Y` rather than asserting a defect.

### 2. URL encoding conformance (RFC-3986/3987) becomes a first-class check

sitemaps.org requires URLs be URL-escaped and conform to RFC-3986 (URIs) **or**
RFC-3987 (IRIs). We surface the conformance gap via the same raw-vs-canonical
comparison:

| Case | Detection | Code | Severity |
|---|---|---|---|
| Malformed `%XX` (e.g. `%zz`) | raw bytes (`has_invalid_escape`) | `PROTOCOL_URL_INVALID_ESCAPE` (exists) | **error** |
| Raw Unicode / unescaped, but a **valid IRI** | `canonical(loc) != loc`, only IRI-legal chars | `PROTOCOL_URL_NOT_ESCAPED` (new) | **info** |
| Characters illegal even for an IRI (raw space, `<` `>` `{` `}` …) | `canonical(loc) != loc`, illegal char present | `PROTOCOL_URL_NOT_ESCAPED` (new) | **warning** |

Both URIs and IRIs are acceptable per the spec, so a raw-Unicode IRI is
**conformant** — the `info` advisory only tells the author which URI form
crawlers actually fetch (`Y`). Only characters illegal in *both* RFC-3986 and
RFC-3987 are a `warning`. XML entity-escaping of `& ' " < >` is a Layer C
(XSD/XML-parse) concern and is **not** duplicated here.

### 3. The fragment lint stays

`PROTOCOL_URL_FRAGMENT` (`info`) is kept: fragments are spec-legal but unusual
in a sitemap and ignored by crawlers, so flagging is helpful, not a defect.

### 4. `rurl` is gated behind a cheap non-ASCII/escape detector (performance)

`rurl::safe_parse_urls()` is ~70× slower than a raw `curl` parse (it `lapply`s
a per-URL R routine doing IDNA, PSL, and IRI→URI encoding). Running it over
every `<loc>` makes a max-size (50 000-URL) sitemap take ~90 s — the source of
the Layer D test stall.

`rurl` is invoked **only** for a URL whose canonical form can differ from its
raw bytes — i.e. the URL contains any byte ≥ 0x80 (Unicode → IRI/IDNA), or a
`%` (possible escape-normalization), or an ASCII character RFC-3986 would
percent-encode (space, `<`, `>`, …). Detection is a vectorized regex over the
raw strings (microseconds). Every other URL is already canonical ASCII; its key
is built with a cheap `curl`-level parse and no `rurl`.

**Safety invariant — the fast path is only taken where `rurl` is provably a
no-op**, so its output is byte-identical to "`rurl` on everything." Mixing fast
and `rurl` URLs within one document therefore cannot change any equivalence or
scope result: a Unicode host `café.com` (→ `rurl` → `xn--caf-dma.com`) and an
already-punycode `xn--caf-dma.com` (→ fast path, unchanged) still collapse to
one key. No `xn--` special-casing is needed for correctness; decoding `xn--`
back to Unicode is an optional message nicety only.

Scope checking (`PROTOCOL_URL_OUT_OF_SCOPE`) keeps using the canonical host and
only runs for URL-sourced sitemaps (those with an origin); it is out of scope
for this ADR.

---

## Consequences

### Positive
- Findings match the authority: the count/size/length/escaping rules are spec
  mandates; equivalence is labeled a sitemapr lint, not dressed as a protocol
  violation.
- The encoding-conformance gap sitemaps.org actually mandates is now surfaced.
- "Validate, don't modify" is satisfied explicitly: the raw bytes are reported;
  the canonical form is only ever a comparison key and a `resolves-to` hint.
- The 50 000-URL Layer D stall is removed for the common (ASCII) case without an
  approximate fast path — `rurl` runs only where it can change the answer.

### Negative / accepted trade-offs
- The non-ASCII/escape detector is deliberately conservative: URLs containing a
  `%` or a sub-delim are routed to `rurl` even when they would survive
  unchanged. Pure perf concession, zero correctness risk.
- `PROTOCOL_URL_EQUIVALENT` and `PROTOCOL_URL_NOT_ESCAPED` are new codes; the
  findings-contract code list and the registered-severity tables grow.
- The D.1 feature scenario asserting the canonical key's percent-encoded URI
  form, and the wording of the duplicate scenarios, are reframed to the
  warning-vs-info split (the scenarios that asserted the old flat behavior are
  updated, not deleted).

## Revisit conditions
- A future need to treat punycode/IRI hosts as *distinct* (rather than
  equivalent) for scope or dedup would reopen decision 4's no-op invariant.
- If `rurl` gains a vectorized (non-`lapply`) parse, the detector becomes a pure
  optimization that could be dropped without behavior change.
