# Structural SSRF guard (ADR-003 §1).
#
# Pure, side-effect-free, no-network, no-DNS. The fetch engine calls this once
# per redirect hop on each URL before issuing a request. It consumes URL
# components already parsed by `parse_url_adapter()` (rurl) — sitemapr never
# re-parses the URL here; it only does range/pattern matching on the components.
#
# The disable toggle (`ssrf_guard = FALSE`) is the CALLER's responsibility; the
# matcher below always evaluates and is independently testable. The reason codes
# returned are machine-readable and stable:
#   "loopback", "private", "link-local", "cloud-metadata", "unspecified",
#   "ipv4-mapped", "ipv4-translated", "ipv4-compatible", "nat64",
#   "numeric-literal", "scheme"; NA when allowed.
#
# IPv6->IPv4 embedding (ADR-003 §1). Several IPv6 spellings embed a 32-bit IPv4
# address; left undecoded each is a bypass of the IPv4 range checks. We decode
# all of them and re-run the IPv4 classifier on the embedded address (a PUBLIC
# embedded address is still allowed — only blocked v4 ranges are rejected):
#   prefix             form             reason code
#   ::ffff:0:0/96      IPv4-mapped      "ipv4-mapped"
#   ::ffff:0:0:0/96    IPv4-translated  "ipv4-translated"
#   ::/96              IPv4-compatible  "ipv4-compatible" (deprecated SIIT)
#   64:ff9b::/96       NAT64 well-known "nat64"
#   64:ff9b:1::/48     NAT64 local-use  "nat64" (RFC 6052 §2.2 packing)
# DNS resolve-then-check and arbitrary (deployment-configured) NAT64 prefixes
# remain out of scope per ADR-003 §1.

# ---- helpers: IPv4 -----------------------------------------------------------

# Is `p` a single canonical IPv4 octet: 1-3 ASCII digits, value 0-255, with no
# leading-zero ambiguity (a leading zero like "017" is an octal obfuscation
# form, rejected here)?
ssrf_octet_ok <- function(p) {
  grepl("^[0-9]{1,3}$", p) &&
    !(nchar(p) > 1L && substr(p, 1L, 1L) == "0") &&
    as.integer(p) <= 255L
}

# Is `s` a plain dotted-quad of four decimal octets (0-255)? Returns TRUE only
# for the canonical form rurl emits for an IPv4 host (e.g. "127.0.0.1"). Octal,
# hex, and short/raw-integer forms are NOT dotted-quads and return FALSE.
ssrf_is_dotted_quad <- function(s) {
  if (length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(FALSE)
  }
  parts <- strsplit(s, ".", fixed = TRUE)[[1L]]
  length(parts) == 4L && all(vapply(parts, ssrf_octet_ok, logical(1L)))
}

# Convert a validated dotted-quad to its 32-bit unsigned integer (as numeric, to
# stay clear of R's signed 32-bit integer overflow at the top of the range).
ssrf_ipv4_to_num <- function(s) {
  parts <- as.numeric(strsplit(s, ".", fixed = TRUE)[[1L]])
  parts[1L] * 16777216 + parts[2L] * 65536 + parts[3L] * 256 + parts[4L]
}

# Does the numeric IPv4 `n` fall inside the CIDR block `base/bits`?
ssrf_in_cidr <- function(n, base, bits) {
  base_num <- ssrf_ipv4_to_num(base)
  # Mask = the top `bits` bits set across 32 bits.
  size <- 2^(32 - bits)
  n >= base_num & n < (base_num + size)
}

# The ADR-003 blocked IPv4 CIDR matrix as a (base, bits, reason) table; ranges
# are mutually disjoint so first-match order is immaterial. Kept as data so the
# whole matrix is reviewable in one place. The 169.254.0.0/16 link-local block
# is handled separately because one address inside it (the cloud-metadata
# endpoint) maps to a distinct reason.
ssrf_ipv4_blocked <- list(
  list(base = "127.0.0.0", bits = 8L, reason = "loopback"),
  list(base = "10.0.0.0", bits = 8L, reason = "private"),
  list(base = "172.16.0.0", bits = 12L, reason = "private"),
  list(base = "192.168.0.0", bits = 16L, reason = "private"),
  list(base = "100.64.0.0", bits = 10L, reason = "cloud-metadata"),
  list(base = "0.0.0.0", bits = 8L, reason = "unspecified")
)

ssrf_classify_ipv4 <- function(s) {
  n <- ssrf_ipv4_to_num(s)

  if (ssrf_in_cidr(n, "169.254.0.0", 16L)) {
    # 169.254.169.254 is the cloud-metadata endpoint; it lives inside the
    # link-local /16. Report it as cloud-metadata for caller clarity.
    return(if (s == "169.254.169.254") "cloud-metadata" else "link-local")
  }
  # Classify against the blocked CIDR matrix; NA_character_ when allowed.
  for (r in ssrf_ipv4_blocked) {
    if (ssrf_in_cidr(n, r$base, r$bits)) {
      return(r$reason)
    }
  }
  NA_character_
}

# ---- helpers: IPv6 -----------------------------------------------------------

# Strip the brackets rurl emits around IPv6 literal hosts ("[::1]" -> "::1").
ssrf_strip_brackets <- function(s) {
  if (grepl("^\\[.*\\]$", s)) {
    return(substr(s, 2L, nchar(s) - 1L))
  }
  s
}

# Fold a trailing dotted-quad IPv4 tail in an IPv6 literal into two hex hextets,
# returning the rewritten string. Returns `low` unchanged when there is no tail,
# or NULL when a tail is present but is not a canonical dotted-quad.
ssrf_fold_ipv4_tail <- function(low) {
  m <- regexpr("[0-9]{1,3}(\\.[0-9]{1,3}){3}$", low)
  if (m == -1L) {
    return(low)
  }
  quad <- regmatches(low, m)
  if (!ssrf_is_dotted_quad(quad)) {
    return(NULL)
  }
  n <- ssrf_ipv4_to_num(quad)
  paste0(substr(low, 1L, m - 1L), sprintf("%x:%x", n %/% 65536, n %% 65536))
}

# Resolve an IPv6 literal into its vector of exactly 8 hextet strings: expand
# the (at most one) "::" zero-compression run, or split a fully-written literal
# on ":". Returns NULL when "::" appears more than once, when expansion cannot
# reach 8 hextets, or when a fully-written literal does not have 8 groups.
ssrf_expand_zero_run <- function(low) {
  if (!grepl("::", low, fixed = TRUE)) {
    groups <- strsplit(low, ":", fixed = TRUE)[[1L]]
    return(if (length(groups) == 8L) groups else NULL)
  }
  if (length(gregexpr("::", low, fixed = TRUE)[[1L]]) > 1L) {
    return(NULL)
  }
  pos <- regexpr("::", low, fixed = TRUE)
  left_s <- substr(low, 1L, pos - 1L)
  right_s <- substr(low, pos + 2L, nchar(low))
  left <- if (nzchar(left_s)) {
    strsplit(left_s, ":", fixed = TRUE)[[1L]]
  } else {
    character(0L)
  }
  right <- if (nzchar(right_s)) {
    strsplit(right_s, ":", fixed = TRUE)[[1L]]
  } else {
    character(0L)
  }
  fill <- 8L - length(left) - length(right)
  if (fill < 1L) {
    return(NULL)
  }
  c(left, rep("0", fill), right)
}

ssrf_ipv6_candidate <- function(s) {
  if (length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(NULL)
  }
  low <- tolower(s)
  if (!grepl(":", low, fixed = TRUE) || !grepl("^[0-9a-f:.]+$", low)) {
    return(NULL)
  }
  low
}

ssrf_ipv6_numeric_groups <- function(low) {
  groups <- ssrf_expand_zero_run(low)
  if (is.null(groups) || !all(grepl("^[0-9a-f]{1,4}$", groups))) {
    return(NULL)
  }
  as.numeric(strtoi(groups, base = 16L))
}

# Expand an IPv6 literal (brackets already stripped) into a numeric vector of
# exactly 8 hextets (each 0..65535), or NULL when `s` is not a well-formed IPv6
# literal. Hextets are stored as doubles so downstream arithmetic stays clear of
# R's signed-32-bit overflow. This single expander unifies every spelling rurl
# may or may not normalize, so the embedding detector works off bit positions
# rather than fragile per-form regexes.
ssrf_ipv6_hextets <- function(s) {
  low <- ssrf_ipv6_candidate(s)
  if (is.null(low)) {
    return(NULL)
  }

  low <- ssrf_fold_ipv4_tail(low)
  if (is.null(low)) {
    return(NULL)
  }

  ssrf_ipv6_numeric_groups(low)
}

# Render a 32-bit unsigned integer as a dotted-quad string ("." between octets).
ssrf_num_to_quad <- function(n) {
  paste(
    c(n %/% 16777216, (n %/% 65536) %% 256, (n %/% 256) %% 256, n %% 256),
    collapse = "."
  )
}

# Given the 8 expanded hextets, detect an IPv6->IPv4 embedding prefix and return
# the embedded dotted-quad plus its reason code as `list(quad, reason)`, or NULL
# when no embedding prefix matches. Last-32-bit forms read the IPv4 from h7/h8;
# the NAT64 local-use /48 packs the IPv4 across the RFC 6052 §2.2 bit layout
# (octets at bits 48-63 and 72-95, skipping the reserved u-byte at bits 64-71).
#
# Each `if` is a distinct RFC-defined embedding prefix, written as an exact
# hextet pattern compared with a single vectorised `all()`. This reads as a flat
# security spec table (prefix -> pattern) AND keeps cyclocomp low: a `&&` chain
# is charged per-operator, whereas one `all(h[...] == c(...))` is a single
# branch (ADR-003).
ssrf_embedded_ipv4 <- function(h) {
  tail32 <- h[7L] * 65536 + h[8L]

  # IPv4-mapped: five zero hextets then ffff, IPv4 in the last 32 bits.
  if (all(h[1:6] == c(0, 0, 0, 0, 0, 0xffff))) {
    return(list(ssrf_num_to_quad(tail32), "ipv4-mapped"))
  }
  # IPv4-translated: four zero hextets, then ffff and a zero hextet.
  if (all(h[1:6] == c(0, 0, 0, 0, 0xffff, 0))) {
    return(list(ssrf_num_to_quad(tail32), "ipv4-translated"))
  }
  # NAT64 well-known prefix, IPv4 in the last 32 bits.
  if (all(h[1:6] == c(0x64, 0xff9b, 0, 0, 0, 0))) {
    return(list(ssrf_num_to_quad(tail32), "nat64"))
  }
  # NAT64 local-use prefix; IPv4 split per RFC 6052 §2.2 around the u-byte.
  if (all(h[1:3] == c(0x64, 0xff9b, 1))) {
    o <- c(h[4L] %/% 256, h[4L] %% 256, h[5L] %% 256, h[6L] %/% 256)
    return(list(paste(o, collapse = "."), "nat64"))
  }
  # IPv4-compatible (deprecated): six zero hextets. tail32 > 1 excludes the
  # unspecified (::) and loopback (::1) specials, which must not be read as
  # 0.0.0.0 / 0.0.0.1.
  if (all(h[1:6] == 0) && tail32 > 1) {
    return(list(ssrf_num_to_quad(tail32), "ipv4-compatible"))
  }
  NULL
}

# IPv6->IPv4 embedding prefixes: decode the literal, and if it embeds an IPv4
# address that itself falls in a blocked range, return the embedding's reason
# code (bypass prevention, ADR-003). A public embedded address is allowed,
# matching the IPv4-literal policy; NA when there is no blocked embedding. The
# bit-layout decoding lives in ssrf_ipv6_hextets / ssrf_embedded_ipv4.
ssrf_embedded_reason <- function(low) {
  h <- ssrf_ipv6_hextets(low)
  if (is.null(h)) {
    return(NA_character_)
  }
  emb <- ssrf_embedded_ipv4(h)
  if (is.null(emb) || !ssrf_is_dotted_quad(emb[[1L]])) {
    return(NA_character_)
  }
  if (is.na(ssrf_classify_ipv4(emb[[1L]]))) {
    return(NA_character_)
  }
  emb[[2L]]
}

# Classify an IPv6 literal (brackets already stripped) against ADR-003 ranges.
ssrf_classify_ipv6 <- function(s) {
  low <- tolower(s)

  # Pure-literal specials first, so an embedding decoder can never mislabel them
  # (e.g. read "::1" as the IPv4-compatible address 0.0.0.1).
  if (low == "::1") {
    return("loopback")
  }
  if (low == "::") {
    return("unspecified")
  }

  embedded <- ssrf_embedded_reason(low)
  if (!is.na(embedded)) {
    return(embedded)
  }

  # Link-local fe80::/10 — first hextet 0xfe80..0xfebf.
  if (grepl("^fe[89ab][0-9a-f]?:", low) || grepl("^fe[89ab][0-9a-f]?$", low)) {
    return("link-local")
  }
  # Cloud-metadata IPv6 (AWS) fd00:ec2::254 and its /64 metadata prefix.
  if (low == "fd00:ec2::254" || grepl("^fd00:ec2:", low)) {
    return("cloud-metadata")
  }
  NA_character_
}

# ---- main guard --------------------------------------------------------------

# Build the small result record the fetch engine consumes.
ssrf_result <- function(allowed, reason = NA_character_) {
  list(allowed = allowed, reason = reason)
}

# Does the raw (pre-normalization) host use a numeric/hex/octal obfuscation
# form that is NOT a canonical dotted-quad? rurl normalizes such literals into a
# clean dotted-quad, so the obfuscation is only visible in the raw host. The
# stricter ADR-003 interpretation applies: any all-numeric / hex / leading-zero
# octal literal that is not a canonical dotted-quad is rejected outright.
ssrf_numeric_literal_blocked <- function(raw_host) {
  raw <- ssrf_strip_brackets(if (is.na(raw_host)) "" else raw_host)
  if (
    !nzchar(raw) || grepl(":", raw, fixed = TRUE) || ssrf_is_dotted_quad(raw)
  ) {
    return(FALSE)
  }
  grepl("^0[xX][0-9a-fA-F]+$", raw) || # hex single-integer form
    grepl("^[0-9]+$", raw) || # raw decimal single-integer form
    grepl("^0[0-7]+(\\.0?[0-7]*){1,3}$", raw) # octal-style dotted form
}

# Range/name matching on the normalized host (brackets already stripped).
# Returns an ssrf_result: blocked with a reason code for a matched IP range or
# the well-known metadata hostname; allowed otherwise. Registered names other
# than the metadata host pass (DNS resolve-then-check is deferred, ADR-003 §1).
ssrf_classify_literal <- function(bare) {
  reason <- if (grepl(":", bare, fixed = TRUE)) {
    ssrf_classify_ipv6(bare) # IPv6 literal (contains a colon)
  } else if (ssrf_is_dotted_quad(bare)) {
    ssrf_classify_ipv4(bare) # IPv4 dotted-quad
  } else if (tolower(bare) == "metadata.google.internal") {
    "cloud-metadata"
  } else {
    NA_character_
  }
  ssrf_result(is.na(reason), reason)
}

#' Structural SSRF check on already-parsed URL components
#'
#' Pure, no-network, no-DNS. Returns a list with `allowed` (TRUE/FALSE) and a
#' machine-readable `reason` code (NA when allowed). See file header / ADR-003
#' for the full blocked matrix.
#'
#' @param host Normalized host string as emitted by `parse_url_adapter()`
#'   (rurl): dotted-quad for numeric IPv4, bracketed literal for IPv6, lowercase
#'   registered name otherwise. rurl normalizes numeric/hex/octal IPv4 literals
#'   into dotted-quads, so the obfuscation form is recovered from `raw_host`.
#' @param scheme URL scheme (e.g. "http", "https").
#' @param is_ip_host Logical flag from `parse_url_adapter()`; TRUE when the host
#'   is an IP literal. Used only as a hint; classification ignores it.
#' @param raw_host The pre-normalization host string (typically the host portion
#'   of `original_url`). Used solely to detect numeric/hex/octal IPv4 literal
#'   obfuscation, which rurl normalizes away. Optional; defaults to `host`.
#' @return A list: `list(allowed = <logical>, reason = <character>)`.
#' @noRd
ssrf_check <- function(host, scheme, is_ip_host = FALSE, raw_host = host) {
  # 1. Scheme gate — only http/https allowed.
  scheme_l <- if (is.na(scheme)) "" else tolower(scheme)
  if (!scheme_l %in% c("http", "https")) {
    return(ssrf_result(FALSE, "scheme"))
  }

  # 2. Numeric-literal obfuscation (ADR-003): reject raw decimal/hex/octal
  #    encodings on the raw, pre-normalization host. Checked before the
  #    empty-host guard so a numeric authority rurl fails to parse (host = NA)
  #    is still rejected on its raw form, not slipped through as "no host".
  if (ssrf_numeric_literal_blocked(raw_host)) {
    return(ssrf_result(FALSE, "numeric-literal"))
  }

  if (length(host) != 1L || is.na(host) || !nzchar(host)) {
    # No host to evaluate — nothing to block here; let downstream rules decide.
    return(ssrf_result(TRUE))
  }

  # 3. IP-literal range matching and metadata-name check on the normalized host.
  ssrf_classify_literal(ssrf_strip_brackets(host))
}

#' Structural SSRF check driven by a `parse_url_adapter()` row
#'
#' Convenience wrapper that pulls `scheme`, `host`, `is_ip_host`, and the raw
#' host (from `original_url`) out of a single parsed row and delegates to
#' `ssrf_check()`. Operates on exactly one row.
#'
#' @param parsed_row A one-row data.frame from `parse_url_adapter()`.
#' @return A list: `list(allowed = <logical>, reason = <character>)`.
#' @noRd
ssrf_check_parsed <- function(parsed_row) {
  host <- as.character(parsed_row$host)[[1L]]
  scheme <- as.character(parsed_row$scheme)[[1L]]
  is_ip <- isTRUE(as.logical(parsed_row$is_ip_host)[[1L]])
  original_url <- as.character(parsed_row$original_url)[[1L]]
  # Recover the scheme from the raw URL when rurl reports none: rurl returns
  # scheme = NA for an authority it cannot parse (e.g. a bare numeric-literal
  # host), and without recovery the scheme gate would mask the numeric-literal
  # reason with a "scheme" reject.
  if (is.na(scheme)) {
    scheme <- ssrf_raw_scheme_of(original_url)
  }
  raw_host <- ssrf_raw_host_of(original_url)
  ssrf_check(
    host = host,
    scheme = scheme,
    is_ip_host = is_ip,
    raw_host = raw_host
  )
}

# Recover the scheme from a raw URL string without full parsing, used only when
# rurl reports scheme = NA for an authority it could not parse. Returns the
# lowercased scheme (no "://") or NA when the string carries no scheme.
ssrf_raw_scheme_of <- function(url) {
  if (length(url) != 1L || is.na(url) || !nzchar(url)) {
    return(NA_character_)
  }
  re <- "^[a-zA-Z][a-zA-Z0-9+.-]*(?=://)"
  m <- regmatches(url, regexpr(re, url, perl = TRUE))
  if (length(m) == 0L) {
    return(NA_character_)
  }
  tolower(m)
}

# Extract the host substring from a raw URL string WITHOUT re-parsing semantics:
# this is a literal slice between the authority's "//" and the next delimiter,
# used only to recover the pre-normalization numeric-literal form. rurl still
# owns real parsing; this is a lightweight obfuscation-detection aid.
ssrf_raw_host_of <- function(url) {
  if (length(url) != 1L || is.na(url) || !nzchar(url)) {
    return(NA_character_)
  }
  # Drop scheme://, optional userinfo@, then take up to the first /?# or :port.
  after_scheme <- sub("^[a-zA-Z][a-zA-Z0-9+.-]*://", "", url)
  authority <- sub("[/?#].*$", "", after_scheme)
  authority <- sub("^[^@]*@", "", authority)
  if (grepl("^\\[.*\\]", authority)) {
    # Bracketed IPv6 — keep the brackets so the colon test in ssrf_check works.
    return(sub("^(\\[[^]]*\\]).*$", "\\1", authority))
  }
  # Strip a trailing :port (port is digits only after the final colon).
  sub(":[0-9]*$", "", authority)
}
