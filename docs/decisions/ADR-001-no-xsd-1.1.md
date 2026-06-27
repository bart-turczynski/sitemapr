# ADR-001: Do not support XSD 1.1

- Status: Accepted
- Date: 2026-06-27
- Deciders: Bart Turczyński
- Related: `docs/PRD.md` (§3 technical findings, §2 scope, Layer C/D model)

---

## Context

`sitemapr` validates sitemaps in two layers (per the PRD and the
`sitemap-validator` SPEC layer model):

- **Layer C — schema validation:** XSD conformance against bundled, local
  schema profiles (core, index, core+extension, and runtime-generated mixed
  profiles).
- **Layer D — protocol/semantic validation:** the rules XSD cannot express
  (count/size limits, value ranges, cross-field coherence, URL scoping,
  hreflang/BCP-47, encoding).

The question raised: should Layer C support **XSD 1.1** (assertions `xs:assert`,
conditional type assignment `xs:alternative`, `xs:override`), not just XSD 1.0?

### Technical facts established (verified, not assumed)

1. **R has no XSD 1.1 path.** Both R XML packages — `xml2` and `XML` — are built
   on **libxml2**, which implements **XSD 1.0 only**. `xml2::xml_validate()`
   does real, in-process XSD 1.0 validation but cannot evaluate any 1.1 feature.
   There is no CRAN package offering XSD 1.1.
2. **XSD 1.1 is effectively a JVM capability.** The mainstream engines are
   **Xerces-J** (free; full 1.1 via the JAXP XSD 1.1 `SchemaFactory`, using a
   PsychoPath XPath 2.0 engine for assertions) and **Saxon-EE** (commercial).
   The only non-JVM option, **Xerces-C++**, has partial/experimental 1.1 support
   and would require a C++ system-library dependency.
3. **The sitemap domain has no XSD 1.1 schemas.** The official sitemaps.org and
   Google extension schemas are pure XSD 1.0 (verified: only elements,
   sequences, enumerations, one pattern, restrictions, attributes, and
   `xs:import`/`xs:include`). Even the in-house TS `sitemap-validator` is XSD
   1.0 — its `xsd-schema-validator` dependency uses the JDK's default Xerces 1.0
   `SchemaFactory`, not the 1.1 factory.
4. **Requiring 1.1 reverses the core architectural advantage.** `sitemapr`'s
   design deliberately drops the Java/Xerces engine (and the JDK, the runtime
   `javac` compile step, and the subprocess) that the TS app needs only because
   Node cannot do XSD validation. Adding XSD 1.1 reintroduces exactly that JVM
   dependency.

### Why someone might still want 1.1

Two distinct motivations were separated:

- **(A) Enforce richer constraints** that 1.1 assertions could express
  (value ranges, conditional rules, cross-field coherence, count limits).
- **(B) Validate arbitrary, user-supplied XSD 1.1 schemas** as a general
  capability.

For (A), an XSD 1.1 *engine* is not required: every such rule is precisely what
**Layer D** already implements in R. For (B), a JVM (or heavy C++ system dep)
is unavoidable.

---

## Decision

**`sitemapr` will not support XSD 1.1.**

- Layer C performs **XSD 1.0** structural validation via `xml2`/libxml2,
  in-process, with no external engine.
- All constraints beyond XSD 1.0's expressive power — including everything one
  might otherwise encode as `xs:assert` or conditional types — are implemented
  in **Layer D** as R checks.
- The package takes **no dependency on Java, a JDK, Xerces, Saxon, or
  Xerces-C++**, and declares no `SystemRequirements` for an external validator.

This resolves motivation **(A)** fully and declines motivation **(B)** by design.

---

## Consequences

### Positive
- **CRAN-clean and portable.** No system Java, no `JAVA_HOME`, no runtime
  compile step, no C++ system library, no subprocess. Pure R + libxml2 (already
  shipped with `xml2`).
- **In-process and fast.** No JVM startup, no IPC.
- **XXE-safe by default** (libxml2 does not expand external entities unless
  `NOENT`/`DTDLOAD` are passed).
- **Functionally complete for the sitemap domain.** XSD 1.0 covers every
  official sitemap/extension schema, including mixed multi-namespace documents
  via the strict `xs:any` wildcard composition (validated empirically).
- **Stricter than the reference.** Pushing richer rules into Layer D yields
  validation that exceeds the XSD-1.0-only TS `sitemap-validator`.

### Negative / accepted trade-offs
- **Cannot ingest arbitrary user-supplied XSD 1.1 schemas.** Out of scope; the
  sitemap domain does not require it.
- **Richer rules are not declared in a schema file.** They live in R code, so
  they are versioned and tested as code, not as XSD. Mitigation: keep Layer D
  rules data-driven and well-tested against the fixture corpus.
- **No `xs:assert`/conditional-type validation of third-party schemas.**
  Accepted.

---

## Alternatives considered (and rejected)

1. **Optional Java/Xerces-J sidecar** (invoke via `processx`/`system2`) gated
   behind a 1.1-only code path. — Rejected for v0.x: reintroduces a JDK
   dependency and the very architecture the design removes; no sitemap-domain
   need. Reconsider only under the revisit conditions below.
2. **Xerces-C++ via Rcpp.** — Rejected: partial/experimental 1.1, heavy
   `SystemRequirements: Xerces-C++`, painful cross-platform CRAN builds.
3. **Delegate 1.1 to the existing TS/Java `sitemap-validator` service over
   HTTP.** — Rejected for a library: introduces a network/service dependency
   incompatible with an offline, CRAN-installable package.

---

## Revisit conditions

Reopen this decision only if **all** of the following hold:

- a concrete, recurring need emerges to validate **external** XSD 1.1 schemas
  (motivation B), not merely to enforce stricter sitemap rules; and
- libxml2 still lacks XSD 1.1 (check before reopening); and
- the cost of an **optional, non-default** Java/Xerces-J backend (kept entirely
  off the core install path so the base package stays CRAN-clean) is justified
  by that need.

Until then: XSD 1.0 in Layer C, everything else in Layer D.
