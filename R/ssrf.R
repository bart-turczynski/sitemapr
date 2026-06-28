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
#   "ipv4-mapped", "numeric-literal", "scheme"; NA when allowed.

# ---- helpers: IPv4 -----------------------------------------------------------

# Is `s` a plain dotted-quad of four decimal octets (0-255)? Returns TRUE only
# for the canonical form rurl emits for an IPv4 host (e.g. "127.0.0.1"). Octal,
# hex, and short/raw-integer forms are NOT dotted-quads and return FALSE.
ssrf_is_dotted_quad <- function(s) {
  if (length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(FALSE)
  }
  parts <- strsplit(s, ".", fixed = TRUE)[[1L]]
  if (length(parts) != 4L) {
    return(FALSE)
  }
  # Each octet: 1-3 ASCII digits, value 0-255, no leading-zero ambiguity
  # (a leading zero like "017" is an octal obfuscation form, rejected here).
  for (p in parts) {
    if (!grepl("^[0-9]{1,3}$", p)) {
      return(FALSE)
    }
    if (nchar(p) > 1L && substr(p, 1L, 1L) == "0") {
      return(FALSE)
    }
    if (as.integer(p) > 255L) {
      return(FALSE)
    }
  }
  TRUE
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

# Classify a dotted-quad IPv4 address against the ADR-003 blocked ranges.
# Returns a reason code string, or NA_character_ if the address is allowed.
ssrf_classify_ipv4 <- function(s) {
  n <- ssrf_ipv4_to_num(s)

  if (ssrf_in_cidr(n, "127.0.0.0", 8L)) {
    return("loopback")
  }
  if (ssrf_in_cidr(n, "10.0.0.0", 8L) ||
        ssrf_in_cidr(n, "172.16.0.0", 12L) ||
        ssrf_in_cidr(n, "192.168.0.0", 16L)) {
    return("private")
  }
  if (ssrf_in_cidr(n, "169.254.0.0", 16L)) {
    # 169.254.169.254 is the cloud-metadata endpoint; it lives inside the
    # link-local /16. Report it as cloud-metadata for caller clarity.
    if (s == "169.254.169.254") {
      return("cloud-metadata")
    }
    return("link-local")
  }
  if (ssrf_in_cidr(n, "100.64.0.0", 10L)) {
    return("cloud-metadata")
  }
  if (ssrf_in_cidr(n, "0.0.0.0", 8L)) {
    return("unspecified")
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

# Extract the embedded IPv4 dotted-quad tail of an IPv4-mapped IPv6 address
# (e.g. "::ffff:192.168.1.1" -> "192.168.1.1"). Returns NA_character_ if `s` is
# not an IPv4-mapped form. Accepts both "::ffff:a.b.c.d" and the fully expanded
# "0:0:0:0:0:ffff:a.b.c.d" spellings, case-insensitively.
ssrf_ipv4_mapped_tail <- function(s) {
  low <- tolower(s)
  m <- regmatches(
    low,
    regexpr("(^|:)ffff:([0-9]{1,3}(\\.[0-9]{1,3}){3})$", low)
  )
  if (length(m) == 0L) {
    return(NA_character_)
  }
  # Pull the trailing dotted-quad out of the matched fragment.
  quad <- sub("^.*ffff:", "", m)
  quad
}

# Decode the HEX-HEXTET spelling of an IPv4-mapped IPv6 address into a dotted
# quad. The same `::ffff:a.b.c.d` mapping can also be written with the IPv4 tail
# as two 16-bit hextets, e.g. "::ffff:7f00:1" == "::ffff:127.0.0.1", which rurl
# does NOT normalize. We match `ffff:HHHH:HHHH` (each hextet 1-4 hex digits,
# zero-padded or short), or the compressed single-hextet form `ffff:HHHH` where
# the high hextet is implicitly 0 (e.g. "::ffff:1" == 0.0.0.1). The high hextet
# is the top 16 bits, the low hextet the bottom 16 bits, of the 32-bit IPv4.
# Returns NA_character_ when `s` is not an `::ffff:` hex-hextet mapped form.
# Only the `::ffff:` prefix is handled (ADR-003 matrix); NAT64 / other prefixes
# are intentionally out of scope.
ssrf_ipv4_mapped_hex_tail <- function(s) {
  low <- tolower(s)
  # Two-hextet form: ...ffff:HHHH:HHHH
  m2 <- regmatches(
    low, regexpr("(^|:)ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$", low)
  )
  if (length(m2) > 0L) {
    hextets <- sub("^.*ffff:", "", m2)
    parts <- strsplit(hextets, ":", fixed = TRUE)[[1L]]
    hi <- strtoi(parts[[1L]], base = 16L)
    lo <- strtoi(parts[[2L]], base = 16L)
  } else {
    # Compressed single-hextet form: ...ffff:HHHH (high hextet implicitly 0).
    m1 <- regmatches(low, regexpr("(^|:)ffff:([0-9a-f]{1,4})$", low))
    if (length(m1) == 0L) {
      return(NA_character_)
    }
    hi <- 0L
    lo <- strtoi(sub("^.*ffff:", "", m1), base = 16L)
  }
  # Build the dotted quad with plain arithmetic (n can reach 2^32 - 1, which
  # overflows R's signed 32-bit integer, so avoid bit ops / integer coercion).
  n <- hi * 65536 + lo
  o1 <- n %/% 16777216
  o2 <- (n %/% 65536) %% 256
  o3 <- (n %/% 256) %% 256
  o4 <- n %% 256
  paste(c(o1, o2, o3, o4), collapse = ".")
}

# Classify an IPv6 literal (brackets already stripped) against ADR-003 ranges.
ssrf_classify_ipv6 <- function(s) {
  low <- tolower(s)

  # IPv4-mapped IPv6: reject if the embedded v4 address is in any blocked range
  # (bypass prevention, ADR-003). Reported as "ipv4-mapped".
  tail <- ssrf_ipv4_mapped_tail(low)
  if (!is.na(tail) && ssrf_is_dotted_quad(tail)) {
    if (!is.na(ssrf_classify_ipv4(tail))) {
      return("ipv4-mapped")
    }
  }
  # Same mapping written with the IPv4 tail as hex hextets (rurl does not
  # normalize this spelling), e.g. "::ffff:7f00:1" == "::ffff:127.0.0.1".
  hex_tail <- ssrf_ipv4_mapped_hex_tail(low)
  if (!is.na(hex_tail) && ssrf_is_dotted_quad(hex_tail)) {
    if (!is.na(ssrf_classify_ipv4(hex_tail))) {
      return("ipv4-mapped")
    }
  }

  # Loopback ::1
  if (low == "::1") {
    return("loopback")
  }
  # Unspecified ::
  if (low == "::") {
    return("unspecified")
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
ssrf_check <- function(host, scheme, is_ip_host = FALSE, raw_host = host) {
  # 1. Scheme gate — only http/https allowed.
  scheme_l <- if (is.na(scheme)) "" else tolower(scheme)
  if (!scheme_l %in% c("http", "https")) {
    return(ssrf_result(FALSE, "scheme"))
  }

  if (length(host) != 1L || is.na(host) || !nzchar(host)) {
    # No host to evaluate — nothing to block here; let downstream rules decide.
    return(ssrf_result(TRUE))
  }

  # 2. Numeric-literal obfuscation (ADR-003): reject non-dotted-quad numeric
  #    encodings (raw decimal, hex, octal). rurl normalizes these into a clean
  #    dotted-quad host, so we inspect the raw, pre-normalization host. The
  #    stricter interpretation is used: any all-numeric / hex / leading-zero
  #    octal literal that is NOT a canonical dotted-quad is rejected outright.
  raw <- ssrf_strip_brackets(if (is.na(raw_host)) "" else raw_host)
  if (nzchar(raw) && !grepl(":", raw, fixed = TRUE)) {
    is_canonical_quad <- ssrf_is_dotted_quad(raw)
    looks_hex <- grepl("^0[xX][0-9a-fA-F]+$", raw)
    looks_decimal_int <- grepl("^[0-9]+$", raw)
    # Octal-style dotted form (any octet with a leading zero) or hex/decimal
    # single-integer forms are obfuscation. A canonical dotted-quad is fine.
    looks_octal_dotted <- grepl("^0[0-7]+(\\.0?[0-7]*){1,3}$", raw)
    if (!is_canonical_quad &&
          (looks_hex || looks_decimal_int || looks_octal_dotted)) {
      return(ssrf_result(FALSE, "numeric-literal"))
    }
  }

  # 3. IP-literal range matching on the normalized host.
  bare <- ssrf_strip_brackets(host)

  # IPv6 literal (contains a colon).
  if (grepl(":", bare, fixed = TRUE)) {
    reason <- ssrf_classify_ipv6(bare)
    if (!is.na(reason)) {
      return(ssrf_result(FALSE, reason))
    }
    return(ssrf_result(TRUE))
  }

  # IPv4 dotted-quad.
  if (ssrf_is_dotted_quad(bare)) {
    reason <- ssrf_classify_ipv4(bare)
    if (!is.na(reason)) {
      return(ssrf_result(FALSE, reason))
    }
    return(ssrf_result(TRUE))
  }

  # 4. Registered-name hosts: block only the well-known metadata hostnames.
  #    All other names pass the structural guard (DNS resolve-then-check is
  #    deferred to post-v1 per ADR-003 §1).
  if (tolower(bare) == "metadata.google.internal") {
    return(ssrf_result(FALSE, "cloud-metadata"))
  }

  ssrf_result(TRUE)
}

#' Structural SSRF check driven by a `parse_url_adapter()` row
#'
#' Convenience wrapper that pulls `scheme`, `host`, `is_ip_host`, and the raw
#' host (from `original_url`) out of a single parsed row and delegates to
#' [ssrf_check()]. Operates on exactly one row.
#'
#' @param parsed_row A one-row data.frame from `parse_url_adapter()`.
#' @return A list: `list(allowed = <logical>, reason = <character>)`.
ssrf_check_parsed <- function(parsed_row) {
  host <- as.character(parsed_row$host)[[1L]]
  scheme <- as.character(parsed_row$scheme)[[1L]]
  is_ip <- isTRUE(as.logical(parsed_row$is_ip_host)[[1L]])
  raw_host <- ssrf_raw_host_of(as.character(parsed_row$original_url)[[1L]])
  ssrf_check(host = host, scheme = scheme, is_ip_host = is_ip,
             raw_host = raw_host)
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
