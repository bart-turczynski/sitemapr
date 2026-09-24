# ADR-003: v1 network safety policy

- Status: Accepted (amended 2026-06-28 — two-axis body-limit model, §3;
  amended 2026-07-19 by ADR-010 — per-page truncate-and-retain cap, §3;
  amended 2026-07-25 — two corrections, see Consequences and Revisit
  conditions; no decision changed; amended 2026-07-25 — §1 covers the three
  IPv6 transition embeddings (SITE-uxxdadsa) and malformed IPv6 literals now
  fail closed with `malformed-address` (SITE-zgufvkks))
- Date: 2026-06-28
- Deciders: Bart Turczyński
- Related: `docs/PRD.md` (§2 scope — fetch & safety, §9 open decisions);
  `docs/sitemap-spec.md` (§2 three-axis limit model — authoritative);
  `docs/decisions/ADR-010-page-inspection.md` (per-page body cap — amends §3 below);
  `ssrfr` `design/adr/0001-network-safety-policy.md` (supersedes §1 and §4
  **for `ssrfr`'s scope only**, on the grounds that its audience — long-lived
  servers fetching attacker-supplied URLs — has a different threat model)

---

## Context

`sitemapr` fetches user-supplied URLs and follows redirects on behalf of
library callers. Without guardrails, a malicious or misconfigured sitemap
could cause the library to reach RFC-1918 ranges, cloud-metadata endpoints,
loopback addresses, or other sensitive hosts — a class of vulnerability known
as SSRF (Server-Side Request Forgery).

Several design questions needed resolution before implementation:

1. **How deep should the SSRF guard be?** Structural (parse the hostname and
   reject known-bad patterns) or resolve-then-check (actually DNS-resolve the
   host before fetching and reject any private IP in the result).
2. **Should redirect chains be revalidated?** Should the SSRF guard apply
   only to the initial URL or also to each redirect target?
3. **What limits are configurable vs. hard-capped?**
4. **Does `rurl` own any of the guard logic, or does `sitemapr`?**

---

## Decisions

### 1. SSRF guard: structural-only in v1; DNS resolve-then-check is post-v1

**v1 ships a structural SSRF guard.** On every user-supplied URL and every
redirect target, `sitemapr` rejects the request if the parsed host matches
any of the following:

- **Loopback:** `127.0.0.0/8` (IPv4), `::1` (IPv6)
- **RFC-1918 private ranges:** `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
- **Link-local:** `169.254.0.0/16` (IPv4), `fe80::/10` (IPv6)
- **Cloud metadata:** well-known metadata endpoints — `169.254.169.254`,
  `metadata.google.internal`, `fd00:ec2::254`
- **Shared address space:** `100.64.0.0/10` (CGNAT, RFC 6598). Blocked, but
  reported as `shared`, not `cloud-metadata`: it is not a metadata range, it
  merely contains one provider's endpoint (SITE-ghazltut).
- **Unspecified:** `0.0.0.0/32` (IPv4, RFC 1122 §3.2.1.3), `::` (IPv6)
- **This network:** the rest of `0.0.0.0/8` (IPv4, RFC 791 §3.2), reported as
  `this-network`. Blocked exactly as before; the previous single `/8` row
  reported all of it as `unspecified`, which is correct for one address in
  16,777,216 (SITE-ghazltut).
- **IPv6→IPv4 embedding prefixes:** every IPv6 spelling that embeds a 32-bit
  IPv4 address is decoded and the embedded address re-checked against the IPv4
  ranges above (a *public* embedded address is still allowed). Covered forms:
  IPv4-mapped `::ffff:a.b.c.d` (`::ffff:0:0/96`); IPv4-translated
  `::ffff:0:a.b.c.d` (`::ffff:0:0:0/96`); deprecated IPv4-compatible `::a.b.c.d`
  (`::/96`, excluding `::`/`::1`); NAT64 well-known `64:ff9b::a.b.c.d`
  (`64:ff9b::/96`); NAT64 local-use `64:ff9b:1::/48` (RFC 6052 §2.2 packing,
  IPv4 split across the reserved u-byte); and the three IPv6 **transition
  mechanisms** — 6to4 `2002::/16` (RFC 3056, IPv4 at bits 16–47), Teredo
  `2001::/32` (RFC 4380, IPv4 in the low 32 bits but XOR-obfuscated with
  `0xffffffff`), and ISATAP (RFC 5214, IPv4 in the interface identifier after a
  `0000:5efe` / `0200:5efe` marker, under an *arbitrary* outer prefix). Dotted,
  hex-hextet, and fully-expanded spellings are all handled, since `rurl`
  normalizes them inconsistently. This prevents IPv6-notation bypass of the IPv4
  range checks. *Arbitrary deployment-configured NAT64 prefixes are not covered
  (only the two IANA-assigned ones); DNS resolve-then-check remains out of scope
  (below).*

  The covered set is a **decoder inventory, not a range table.** Blocking
  `2002::/16` or `2001::/32` as ranges would be wrong — both are legitimately
  globally reachable — and would not address the defect: what must be classified
  is the address the wrapper *carries*. Only a blocked embedded address is
  rejected; a public one still passes. The transition forms were added
  2026-07-25 (SITE-uxxdadsa) after all three were verified to reach the default
  allow; they are fixed, IANA-assigned, RFC-defined prefixes, so they were
  always inside the scope this section claims rather than a scope extension.
  ISATAP under a link-local prefix was blocked before that, but incidentally, by
  the `fe80::/10` rule rather than by decoding — a rule that happens to cover a
  case for an unrelated reason is not coverage. See `ssrfr` ADR 0001 §2.3 for the
  normative statement (INV-13 embedded-address corollary), and the `pydantic-ai`
  CVE sequence for the same defect class recurring three times against one
  blocklist.
- **Numeric/octal literals:** reject hosts encoded as raw decimal integers,
  hex integers, or octal octets (e.g., `0x7f000001`, `017700000001`,
  `2130706433`)
- **Non-HTTP(S) schemes:** any scheme other than `http` or `https`

The guard runs on **parsed host and IP components from `rurl`** — it does not
re-parse the host itself. `sitemapr` owns the range/pattern matching; `rurl`
owns the parse.

Every IPv6 rule matches on the **expanded address** (the 8 numeric hextets),
never on the literal string. A hextet may be written with leading zeros and a
`::` run may be placed anywhere, so the same 128 bits have many spellings;
matching the literal decided them inconsistently and was a bypass in both
directions (SITE-vovtwvuh for `::1`/`::`, SITE-mhfmtdxa for `fe80::/10` and
`fd00:ec2::/32`).

**Malformed IPv6 literals fail closed** (amended 2026-07-25, SITE-zgufvkks;
mirrored as robotstxtr **ROBO-udnyuuwn**). A literal that cannot be expanded to
exactly 8 hextets (`fe80:::1`, `::12345`, `::ffff:999.1.1.1`, more than one `::`
run) is not an address the guard can reason about. It is refused with the reason
code **`malformed-address`** rather than reaching the default allow.

Previously such a literal matched no rule and was allowed. That was not a known
bypass — the guard sees only hosts `rurl` has already normalized, and `rurl`
rejects these first — but it left the property enforced by the parse layer
rather than by the guard, which is exactly the reliance SITE-vovtwvuh set out to
remove for the IPv6 specials. The same argument applies to malformed input, so
the guard now enforces it itself and no longer depends on `rurl`'s host handling
staying strict.

`malformed-address` is deliberately the code `ssrfr`'s vocabulary already
reserves for this case (`ssrf-guard-spec.md` §5, INV-11), so the eventual
extraction does not have to rename a published value. Refusing before any rule
runs is also what lets every IPv6 rule assume 8 numeric hextets, which removed
three defensive `is.null()` branches from the matcher.

**DNS resolve-then-check is deferred to post-v1.** Resolving hostnames before
fetching would catch DNS-rebinding attacks and hosts that resolve to private
IPs without being expressed as literals. However:

- DNS resolution at parse/guard time adds latency, network dependency, and
  failure modes (DNS timeout, flaky resolution) incompatible with a library
  designed to work offline and pass `R CMD check` without network access.
- DNS rebinding is primarily a browser/server concern. A library does not run
  a long-lived server; each call is discrete, narrowing the rebinding window
  to near zero.
- CRAN test isolation requires offline tests. Any DNS call inside the guard
  would need mocking, adding test infrastructure overhead.
- The structural guard already blocks the entire RFC-1918 literal space,
  loopback, link-local, and cloud-metadata endpoints. The remaining gap
  (a hostname that resolves to a private IP but is not expressed as a literal)
  is a threat model that applies more to multi-tenant API services than to a
  single-caller R library.

The opt-out flag (`ssrf_guard = FALSE`) allows trusted/offline use where the
guard should be disabled (e.g., scanning a private staging server from inside
the same network). The flag must be documented clearly and is **never** the
default.

### 2. Redirect revalidation

The SSRF guard runs on **every URL in the redirect chain**, not only on the
initial URL. A redirect to a `Location:` header that resolves to an RFC-1918
host is rejected at the same point a literal private IP would be.

`httr2`'s redirect handling is used with a configured redirect limit; each
redirect target is passed through the structural SSRF guard before the next
request is issued.

### 3. Configurable limits and hard caps

All limits are configurable via arguments to `read_sitemap()`,
`sitemap_tree()`, and `validate_sitemap()`, with fallback to
`getOption("sitemapr.*")`. No limit is hardcoded in logic. The defaults match
the §28 (PRD) values:

| Limit | Default | Notes |
|---|---|---|
| Request timeout | 30 s | Per request, not per session |
| Max redirects | 5 | Per URL, applied before SSRF recheck |
| Max discovery candidates | 25 | Guessed-path discovery only |
| Max index children | 50 000 | Per `sitemapindex` file |
| Sitemap uncompressed size | 50 MB | **Protocol conformance, not a fetch abort.** Measured on uncompressed bytes. Exceeding it is a non-fatal Layer D finding (`PROTOCOL_SIZE_EXCEEDED`); the body is still read so other findings surface. |
| Per-resource safety ceiling | 500 MB | Hard cap on **decompressed/effective** bytes per fetched resource. Exceeding it discards the body and yields a partial result (`FETCH_BODY_CEILING_EXCEEDED`, `fatal`). The memory backstop that replaces the old on-wire abort. |
| Max archive size | 50 MB | `.tar.gz` only (local files) |
| Max archive file count | 100 files | Per archive |
| Max archive decompressed size | 200 MB | Across all files in one archive; intentionally tighter than the 500 MB single-resource ceiling (a multi-file local archive is a different bomb surface) |

There are **no non-overridable hard caps** — every limit can be raised by the
caller if they accept the consequences. The library does not enforce CRAN
policy on the caller. Documentation should note the memory implications of
raising the safety ceiling or the archive decompressed limit.

**Body-limit model (amended).** Fetch is **buffered** in v1, not streaming: the
body is read into memory up to the per-resource safety ceiling. The 50 MB
sitemap-protocol limit is **not** a fetch-time abort — it is a Layer D
validation finding (`PROTOCOL_SIZE_EXCEEDED`) computed from the uncompressed
byte size, so the body is read in full and other findings still surface. The
earlier "on-wire / mid-stream byte count" framing is superseded: its
abuse-control rationale (archive-bomb defense) does not bind a no-network CRAN
library whose callers fetch their own sitemaps (see `docs/sitemap-spec.md` §2).

The hard stop is the **per-resource safety ceiling** (500 MB of decompressed/
effective bytes). Exceeding it discards the body and produces a partial result:
`validate_sitemap()` emits a `fatal` `FETCH_BODY_CEILING_EXCEEDED` finding;
`read_sitemap()` / `sitemap_tree()` (which do not emit findings) raise a classed
`sitemapr_body_ceiling` condition. A wall-clock timeout (the 30 s request limit)
remains a distinct `sitemapr_timeout` condition. The `sitemapr_truncated`
condition tied to the old 50 MB on-wire abort is **retired**.

**Per-page inspection cap (added 2026-07-19 by ADR-010 §2).** Opt-in Layer E page
inspection introduces a second, **inner** body bound: a per-page cap (single-MB
range, caller-overridable) that is **truncate-and-retain**, not discard. On
reaching it the fetch stops, **keeps the body prefix**, and marks the page
artifact `truncated`; the retained head-region prefix is usable for extraction
and the fetch outcome is `partial` (ADR-009 §3, as amended), never `incomplete`.
This sits **inside** the 500 MB per-resource safety ceiling above, which is
unchanged and stays the outer **discard** backstop (memory-bomb defense). The two
are distinct by design: the page cap keeps a small usable prefix; the 500 MB
ceiling discards the whole body. At the page findings layer, the 500 MB discard is
a **resource** failure → `PAGE_FETCH_FAILED`, kept distinct from an SSRF / scheme
/ downgrade refusal → `PAGE_SSRF_BLOCKED` (ADR-010 §3). The page cap is part of
the caller-overridable page-inspection budget and, like every limit in this §3,
has **no non-overridable hard floor**.

### 4. URL-stack ownership

| Concern | Owner |
|---|---|
| Parse URL components (scheme, host, path, port, query, fragment) | `rurl::safe_parse_urls()` |
| IDNA host normalization (Unicode → Punycode) | `rurl` (via `punycoder`) |
| Path dot-segment normalization | `rurl` |
| Path percent-encoding | `rurl` |
| Public suffix / registered domain fields | `rurl` (via `pslr`) |
| IP-host detection | `rurl` |
| SSRF guard (range matching, pattern rejection) | `sitemapr` |
| Sitemap entrypoint policy (bare domain → `https://`) | `sitemapr` |
| `loc` identity key (full-URL normalization for dedup) | `sitemapr` (built from `rurl` components; never `rurl::clean_url`) |
| Protocol-layer URL rules (absolute http/https, host present, scoping) | `sitemapr` Layer D |

### 5. Default User-Agent

The default UA string is `sitemapr/<version> (+<contact-url>)`, where
`<contact-url>` is the package GitHub URL. Callers may supply a custom UA via
the `user_agent` argument. No hard-coded URL appears in package source; the
contact URL is assembled at runtime from `utils::packageDescription()`.

---

## Consequences

### Positive
- SSRF guard is well-defined, owned clearly by `sitemapr`, and testable
  offline with literal-IP fixtures.
- All limits are configurable; no surprises for advanced users scanning large
  or trusted networks.
- `rurl` components are reused without re-implementing URL parsing.
- Redirect revalidation closes the most common redirect-based SSRF bypass.

### Negative / accepted trade-offs
- DNS-rebinding is not caught in v1. Documented explicitly.
- A hostname like `evil.internal.corp` that resolves to `10.0.0.1` is **not
  blocked at all** — unconditionally, since the structural guard never resolves
  it. Separately, users on trusted networks who *want* to reach such hosts
  should set `ssrf_guard = FALSE` rather than expect structural matching to
  accommodate them.

  *(Corrected 2026-07-25. The earlier wording — "is not blocked unless
  `ssrf_guard = FALSE` is set" — was self-contradictory: that flag disables the
  guard, so it cannot cause blocking. It conflated the unconditional gap with
  the unrelated opt-out advice.)*
- Failing closed on malformed IPv6 literals means a host containing a colon that
  is not a decodable IPv6 address is now refused rather than allowed. `rurl`
  rejects such hosts before the guard sees them, so no reachable behaviour
  changes; the cost is that the guard is stricter than the parse layer rather
  than the other way round, which is the intended direction.
- Reason codes are additive here (`6to4`, `teredo`, `isatap`,
  `malformed-address`). They widen the stable vocabulary a caller may see in a
  `sitemapr_ssrf_blocked` condition, but rename nothing.
- The transition decoders block by *classification*, not by routability. A 6to4
  or Teredo address whose wrapped IPv4 is blocked is refused whether or not the
  host would actually have routed that mechanism; RFC 7526 deprecated 6to4
  anycast, so in many deployments the connection would simply have failed. That
  is fail-closed by accident, and not a property to rely on.

---

## Revisit conditions

- ~~A reliable, CRAN-safe DNS resolution primitive is available (e.g., a
  future `httr2` feature or a lightweight CRAN package) that does not depend
  on `system2` or `nslookup`.~~ **Met (recorded 2026-07-25).** `curl::nslookup()`
  is a C-level libcurl call — not a shell-out to the `nslookup` binary — and
  returns all A/AAAA records. It is already an indirect dependency via `httr2`.

  This condition is therefore no longer what defers §1. The deferral now rests
  solely on the remaining §1 reasons: offline-testability, and the judgement
  that the residual threat model (a hostname resolving to a private IP) applies
  to multi-tenant services more than to a library whose callers fetch their own
  sitemaps. Both are still held. `ssrfr` reached the **opposite** conclusion on
  the second reason for its own audience — see the Related link above — so if
  `sitemapr` ever gains a server-side, attacker-supplied-URL use case, that
  reason lapses and §1 should be revisited immediately.
- User reports of real-world SSRF attempts against library callers
  demonstrate that the structural guard is insufficient.
- A dependency on `ssrfr` becomes viable, at which point the vendored matcher
  in `R/ssrf.R` is replaced rather than kept in sync by hand
  (**SITE-yeozymry**).
