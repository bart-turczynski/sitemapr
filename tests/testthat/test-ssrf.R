# SSRF guard unit tests (ADR-003 §1 matrix + fetch_classification.feature
# acceptance scenarios). Internal fns are referenced via sitemapr_test_ns$.

# Helper: run the guard the way the fetch engine will, by parsing a full URL
# through the real adapter and feeding the row to ssrf_check_parsed(). This
# exercises the integration surface and the rurl normalization behaviour.
guard <- function(url) {
  parsed <- sitemapr_test_ns$parse_url_adapter(url)
  sitemapr_test_ns$ssrf_check_parsed(parsed)
}

test_that("ssrf_raw_scheme_of returns NA for missing scalar schemes", {
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_scheme_of(character(0))))
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_scheme_of(NA_character_)))
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_scheme_of("")))
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_scheme_of("example.com/path")))
  expect_identical(
    sitemapr_test_ns$ssrf_raw_scheme_of("HTTP://example.com"),
    "http"
  )
})

# ---- loopback ----------------------------------------------------------------

test_that("loopback IPv4 127.0.0.1 is rejected (feature scenario)", {
  res <- guard("http://127.0.0.1/sitemap.xml")
  expect_false(res$allowed)
  expect_identical(res$reason, "loopback")
})

test_that("loopback covers the whole 127.0.0.0/8 block", {
  expect_false(guard("http://127.255.255.254/")$allowed)
  expect_identical(guard("http://127.0.0.2/")$reason, "loopback")
})

test_that("loopback IPv6 ::1 is rejected", {
  res <- guard("http://[::1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "loopback")
})

# ---- RFC-1918 private --------------------------------------------------------

test_that("RFC-1918 ranges are rejected as private", {
  expect_identical(guard("http://10.0.0.1/")$reason, "private")
  expect_identical(guard("http://10.255.255.255/")$reason, "private")
  expect_identical(guard("http://172.16.0.1/")$reason, "private")
  expect_identical(guard("http://172.31.255.255/")$reason, "private")
  expect_identical(guard("http://192.168.1.1/")$reason, "private")
})

test_that("addresses just outside 172.16/12 are allowed", {
  # 172.15.x and 172.32.x are public, not RFC-1918.
  expect_true(guard("http://172.15.0.1/")$allowed)
  expect_true(guard("http://172.32.0.1/")$allowed)
})

# ---- link-local --------------------------------------------------------------

test_that("link-local IPv4 169.254.0.0/16 is rejected", {
  res <- guard("http://169.254.1.1/")
  expect_false(res$allowed)
  expect_identical(res$reason, "link-local")
})

test_that("link-local IPv6 fe80::/10 is rejected", {
  expect_identical(guard("http://[fe80::1]/")$reason, "link-local")
  expect_identical(guard("http://[febf::1]/")$reason, "link-local")
})

# ---- cloud-metadata ----------------------------------------------------------

test_that("cloud metadata endpoint 169.254.169.254 is rejected (feature)", {
  res <- guard("http://169.254.169.254/latest/meta-data/")
  expect_false(res$allowed)
  expect_identical(res$reason, "cloud-metadata")
})

test_that("CGNAT 100.64.0.0/10 is rejected as cloud-metadata", {
  expect_identical(guard("http://100.64.0.1/")$reason, "cloud-metadata")
  expect_identical(guard("http://100.127.255.255/")$reason, "cloud-metadata")
})

test_that("metadata.google.internal hostname is rejected", {
  res <- guard("http://metadata.google.internal/")
  expect_false(res$allowed)
  expect_identical(res$reason, "cloud-metadata")
})

test_that("AWS IPv6 metadata fd00:ec2::254 is rejected", {
  res <- guard("http://[fd00:ec2::254]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "cloud-metadata")
})

# ---- unspecified -------------------------------------------------------------

test_that("unspecified IPv4 0.0.0.0/8 is rejected", {
  res <- guard("http://0.0.0.0/")
  expect_false(res$allowed)
  expect_identical(res$reason, "unspecified")
})

test_that("unspecified IPv6 :: is rejected", {
  res <- guard("http://[::]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "unspecified")
})

# ---- IPv4-mapped IPv6 bypass -------------------------------------------------

test_that("IPv4-mapped IPv6 of a private address is rejected (feature)", {
  res <- guard("http://[::ffff:192.168.1.1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("IPv4-mapped IPv6 of loopback is rejected", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "[::ffff:127.0.0.1]",
    scheme = "http",
    raw_host = "[::ffff:127.0.0.1]"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("IPv4-mapped IPv6 of a PUBLIC address is allowed", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "[::ffff:8.8.8.8]",
    scheme = "http",
    raw_host = "[::ffff:8.8.8.8]"
  )
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- IPv4-mapped IPv6 in HEX-HEXTET spelling (bypass class) ------------------

test_that("hex-hextet mapped loopback ::ffff:7f00:1 is rejected", {
  res <- guard("http://[::ffff:7f00:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("zero-padded hex-hextet mapped loopback ::ffff:7f00:0001 rejected", {
  res <- guard("http://[::ffff:7f00:0001]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("hex-hextet mapped private ::ffff:c0a8:1 is rejected", {
  # c0a8:0001 == 192.168.0.1
  res <- guard("http://[::ffff:c0a8:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("mapped ::ffff:0:1 (h7=0,h8=1) decodes to 0.0.0.1", {
  # Both IPv4 hextets present: h6=ffff, h7=0, h8=1 -> 0.0.0.1 (0.0.0.0/8).
  res <- guard("http://[::ffff:0:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("::ffff:1 is a plain IPv6 address, not an IPv4-mapped form", {
  # ::ffff:1 expands to 0:0:0:0:0:0:ffff:1 (ffff in the 7th group, not the
  # 6th), so it is NOT IPv4-mapped — a real stack routes it to that literal
  # IPv6 address, never to 0.0.0.1. The guard treats it as a normal address.
  res <- guard("http://[::ffff:1]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("fully-expanded hex-hextet mapped loopback is rejected", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "[0:0:0:0:0:ffff:7f00:1]",
    scheme = "http",
    raw_host = "[0:0:0:0:0:ffff:7f00:1]"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("hex-hextet mapped form is case-insensitive", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "[::FFFF:7F00:1]",
    scheme = "http",
    raw_host = "[::FFFF:7F00:1]"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("hex-hextet mapped PUBLIC address still passes", {
  # 5db8:d822 == 93.184.216.34 (example.com), public.
  res <- guard("http://[::ffff:5db8:d822]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- IPv4-translated ::ffff:0:0:0/96 (SITE-lgpgudfb hardening) ---------------

test_that("IPv4-translated of loopback is rejected (hex + dotted)", {
  expect_identical(guard("http://[::ffff:0:7f00:1]/")$reason, "ipv4-translated")
  expect_identical(
    guard("http://[::ffff:0:127.0.0.1]/")$reason,
    "ipv4-translated"
  )
})

test_that("IPv4-translated of a private address is rejected", {
  # c0a8:0001 == 192.168.0.1
  res <- guard("http://[::ffff:0:c0a8:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-translated")
})

test_that("IPv4-translated of a PUBLIC address is allowed", {
  res <- guard("http://[::ffff:0:8.8.8.8]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- IPv4-compatible ::/96 (deprecated SIIT form) ----------------------------

test_that("IPv4-compatible of loopback is rejected (hex + dotted)", {
  expect_identical(guard("http://[::7f00:1]/")$reason, "ipv4-compatible")
  expect_identical(guard("http://[::127.0.0.1]/")$reason, "ipv4-compatible")
})

test_that("IPv4-compatible of a private address is rejected", {
  res <- guard("http://[::c0a8:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-compatible")
})

test_that("IPv4-compatible of a PUBLIC address is allowed", {
  res <- guard("http://[::8.8.8.8]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("the :: and ::1 specials are NOT read as IPv4-compatible", {
  # :: -> unspecified, ::1 -> loopback; the compatible decoder must defer to
  # these rather than reading them as 0.0.0.0 / 0.0.0.1.
  expect_identical(guard("http://[::]/")$reason, "unspecified")
  expect_identical(guard("http://[::1]/")$reason, "loopback")
})

# ---- NAT64 well-known prefix 64:ff9b::/96 ------------------------------------

test_that("NAT64 WKP embedding loopback is rejected (hex + dotted)", {
  expect_identical(guard("http://[64:ff9b::7f00:1]/")$reason, "nat64")
  expect_identical(guard("http://[64:ff9b::127.0.0.1]/")$reason, "nat64")
})

test_that("NAT64 WKP embedding the cloud-metadata IP is rejected", {
  # a9fe:a9fe == 169.254.169.254
  res <- guard("http://[64:ff9b::a9fe:a9fe]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "nat64")
})

test_that("NAT64 WKP embedding a PUBLIC address is allowed", {
  res <- guard("http://[64:ff9b::8.8.8.8]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- NAT64 local-use prefix 64:ff9b:1::/48 (RFC 6052 §2.2 bit packing) -------

test_that("NAT64 /48 decodes the IPv4 across the reserved u-byte (private)", {
  # 192.168.0.1: a.b -> h4=c0a8, u+c -> h5=0000, d -> h6=0100.
  res <- guard("http://[64:ff9b:1:c0a8:0:100::]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "nat64")
})

test_that("NAT64 /48 decodes the cloud-metadata IP", {
  # 169.254.169.254: h4=a9fe, h5=00a9, h6=fe00.
  res <- guard("http://[64:ff9b:1:a9fe:a9:fe00::]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "nat64")
})

test_that("NAT64 /48 embedding a PUBLIC address is allowed", {
  # 8.8.8.8: h4=0808, h5=0008, h6=0800.
  res <- guard("http://[64:ff9b:1:808:8:800::]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- embedding decoder does not over-block normal IPv6 -----------------------

test_that("a non-embedding IPv6 with a dotted tail is allowed", {
  # 2001:db8::1.2.3.4 is a documentation-range address, not an embedding prefix.
  res <- guard("http://[2001:db8::1.2.3.4]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- numeric / hex / octal literal obfuscation -------------------------------

test_that("raw decimal IPv4 literal is rejected as numeric-literal", {
  res <- guard("http://2130706433/")
  expect_false(res$allowed)
  expect_identical(res$reason, "numeric-literal")
})

test_that("hex IPv4 literal is rejected as numeric-literal", {
  res <- guard("http://0x7f000001/")
  expect_false(res$allowed)
  expect_identical(res$reason, "numeric-literal")
})

test_that("octal IPv4 literal is rejected as numeric-literal", {
  res <- guard("http://017700000001/")
  expect_false(res$allowed)
  expect_identical(res$reason, "numeric-literal")
})

test_that("octal-dotted IPv4 literal is rejected as numeric-literal", {
  # 0177.0.0.1 == 127.0.0.1 with a leading-zero (octal) first octet.
  res <- sitemapr_test_ns$ssrf_check(
    host = "127.0.0.1",
    scheme = "http",
    raw_host = "0177.0.0.1"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "numeric-literal")
})

# ---- scheme gate -------------------------------------------------------------

test_that("non-http(s) scheme is rejected", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "example.com",
    scheme = "ftp",
    raw_host = "example.com"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "scheme")
})

test_that("file scheme is rejected", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "",
    scheme = "file",
    raw_host = ""
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "scheme")
})

test_that("https scheme is permitted through the scheme gate", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "example.com",
    scheme = "https",
    raw_host = "example.com"
  )
  expect_true(res$allowed)
})

# ---- positive / allowed cases ------------------------------------------------

test_that("public hostname example.com is allowed", {
  res <- guard("https://example.com/sitemap.xml")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("public IPv4 literals are allowed", {
  expect_true(guard("http://93.184.216.34/")$allowed)
  expect_true(guard("http://8.8.8.8/")$allowed)
})

test_that("public IPv6 literal is allowed", {
  res <- guard("http://[2606:2800::]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- result shape ------------------------------------------------------------

test_that("the guard returns a list with allowed + reason fields", {
  res <- sitemapr_test_ns$ssrf_check(
    host = "example.com",
    scheme = "https",
    raw_host = "example.com"
  )
  expect_type(res, "list")
  expect_named(res, c("allowed", "reason"))
  expect_type(res$allowed, "logical")
})

# ---- matcher is independently testable (no disable flag inside) --------------

test_that("ssrf_check evaluates ranges regardless of any caller toggle", {
  # The guard has no disable flag; disabling is the caller's job. Confirm the
  # core matcher always evaluates and blocks a private address.
  res <- sitemapr_test_ns$ssrf_check(
    host = "10.0.0.1",
    scheme = "http",
    raw_host = "10.0.0.1"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "private")
})

# ---- helper guards: malformed input rejection --------------------------------
# Direct unit coverage of the defensive branches in the IPv4/IPv6 parsers. These
# guards are reachable only with inputs the integration surface normalizes away,
# so they are exercised against the internal helpers directly.

test_that("ssrf_is_dotted_quad rejects malformed dotted-quads", {
  # Non-scalar, NA, or empty input.
  expect_false(sitemapr_test_ns$ssrf_is_dotted_quad(NA_character_))
  expect_false(sitemapr_test_ns$ssrf_is_dotted_quad(c("1", "2")))
  expect_false(sitemapr_test_ns$ssrf_is_dotted_quad(""))
  # Leading-zero octet (octal obfuscation form) is rejected.
  expect_false(sitemapr_test_ns$ssrf_is_dotted_quad("127.017.0.1"))
  # Octet out of the 0-255 range is rejected.
  expect_false(sitemapr_test_ns$ssrf_is_dotted_quad("256.0.0.1"))
})

test_that("ssrf_ipv6_hextets returns NULL for non-IPv6 / malformed input", {
  # Non-scalar, NA, or empty.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets(NA_character_))
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets(""))
  # No colon, or colon present but illegal characters.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("12345"))
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("::zz"))
  # Trailing dotted-quad tail that is not a valid IPv4 address.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("::1.2.3.999"))
  # More than one "::" zero-compression run.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("1::2::3"))
  # "::" present but no room to fill (already eight groups).
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("1:2:3:4:5:6:7:8::"))
  # No "::" and the wrong number of groups.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("1:2:3"))
  # Correct group count but an over-long hextet.
  expect_null(sitemapr_test_ns$ssrf_ipv6_hextets("::12345"))
})

test_that("ssrf_embedded_reason returns NA when no blocked embedding", {
  # Malformed literal: hextet parse fails, so there is nothing to decode.
  expect_true(is.na(sitemapr_test_ns$ssrf_embedded_reason("::zz")))
  # Well-formed IPv6 with no embedding prefix.
  expect_true(is.na(sitemapr_test_ns$ssrf_embedded_reason("fe80::1")))
  # Embedding prefix but a PUBLIC embedded address is allowed (NA).
  expect_true(is.na(sitemapr_test_ns$ssrf_embedded_reason("::ffff:8.8.8.8")))
  # Embedding prefix wrapping a blocked address yields its reason code.
  expect_identical(
    sitemapr_test_ns$ssrf_embedded_reason("::ffff:127.0.0.1"),
    "ipv4-mapped"
  )
})

test_that("ssrf_check allows when there is no host to evaluate", {
  # An NA or empty host is not blockable here; downstream rules decide.
  expect_true(
    sitemapr_test_ns$ssrf_check(host = NA_character_, scheme = "http")$allowed
  )
  expect_true(sitemapr_test_ns$ssrf_check(host = "", scheme = "http")$allowed)
})

test_that("ssrf_raw_host_of returns NA for non-scalar / NA / empty input", {
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_host_of(NA_character_)))
  expect_true(is.na(sitemapr_test_ns$ssrf_raw_host_of("")))
})
