# ADR-003: v1 network safety policy

- Status: Accepted
- Date: 2026-06-28
- Deciders: Bart Turczyński
- Related: `docs/PRD.md` (§2 scope — fetch & safety, §9 open decisions)

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
- **Cloud metadata:** `100.64.0.0/10` (CGNAT), and well-known metadata
  hostnames (`169.254.169.254`, `metadata.google.internal`, `fd00:ec2::254`)
- **Unspecified:** `0.0.0.0/8` (IPv4), `::` (IPv6)
- **IPv4-mapped-IPv6:** `::ffff:10.x.x.x`, `::ffff:192.168.x.x`, etc.
  (prevents IPv6-notation bypass of IPv4 range checks)
- **Numeric/octal literals:** reject hosts encoded as raw decimal integers,
  hex integers, or octal octets (e.g., `0x7f000001`, `017700000001`,
  `2130706433`)
- **Non-HTTP(S) schemes:** any scheme other than `http` or `https`

The guard runs on **parsed host and IP components from `rurl`** — it does not
re-parse the host itself. `sitemapr` owns the range/pattern matching; `rurl`
owns the parse.

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
| Max on-wire body | 50 MB | Content-Length + mid-stream byte count |
| Max archive size | 50 MB | `.tar.gz` only (local files) |
| Max archive file count | 100 files | Per archive |
| Max decompressed size | 200 MB | Across all files in one archive |

There are **no non-overridable hard caps** — every limit can be raised by the
caller if they accept the consequences. The library does not enforce CRAN
policy on the caller. Documentation should note the memory implications of
raising the on-wire or decompressed limits.

A **mid-stream timeout** (the `on_wire` limit hit during body read) discards
the partial body. A truncated document is never parsed; an `error`-class
condition is raised instead with an `error_class` of `sitemapr_truncated`.

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
- A hostname like `evil.internal.corp` that resolves to `10.0.0.1` is not
  blocked unless `ssrf_guard = FALSE` is set; users on trusted networks
  should use the opt-out rather than rely on structural matching.

---

## Revisit conditions

- A reliable, CRAN-safe DNS resolution primitive is available (e.g., a
  future `httr2` feature or a lightweight CRAN package) that does not depend
  on `system2` or `nslookup`.
- User reports of real-world SSRF attempts against library callers
  demonstrate that the structural guard is insufficient.
