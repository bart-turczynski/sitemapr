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

test_that("link-local matches fe80::/10 by value, not by literal prefix", {
  # SITE-mhfmtdxa. The old "^fe[89ab][0-9a-f]?:" made the 4th hex digit
  # optional, so a 3-digit first hextet ("fe8" = 0x0fe8) matched despite being
  # nowhere near fe80::/10. The block is exactly 0xfe80..0xfebf. Asserted on
  # the classifier directly so rurl's canonicalization cannot mask the rule.
  classify <- sitemapr_test_ns$ssrf_classify_ipv6
  expect_identical(classify("fe80::1"), "link-local")
  expect_identical(classify("fe80:0:0:0:0:0:0:1"), "link-local")
  expect_identical(classify("FE80::1"), "link-local")
  expect_identical(
    classify("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
    "link-local"
  )
  # Formerly over-blocked: 0x0fe8/0x0fea/0x0feb are ordinary global addresses.
  expect_true(is.na(classify("fe8::")))
  expect_true(is.na(classify("fe8:0:0:0:0:0:0:1")))
  expect_true(is.na(classify("fe9::")))
  expect_true(is.na(classify("fea::1")))
  expect_true(is.na(classify("feb::")))
  # Immediately outside the /10 on either side.
  expect_true(is.na(classify("fe7f::1")))
  expect_true(is.na(classify("fec0::1")))
  # A literal that does not expand to 8 hextets is refused outright rather than
  # falling through the prefix rules to the default allow (SITE-zgufvkks).
  expect_identical(classify("fea:"), "malformed-address")
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

test_that("every spelling of the AWS IPv6 metadata prefix is blocked", {
  # SITE-mhfmtdxa. A hextet may carry leading zeros, so "ec2" and "0ec2" are
  # the same 16 bits. Matching the literal "^fd00:ec2:" blocked the first
  # spelling and let the second through — a real bypass of the metadata block,
  # not merely an inconsistency. All of these are fd00:0ec2::/32.
  classify <- sitemapr_test_ns$ssrf_classify_ipv6
  expect_identical(classify("fd00:ec2::254"), "cloud-metadata")
  expect_identical(classify("fd00:0ec2::254"), "cloud-metadata")
  expect_identical(classify("fd00:0ec2:0:0:0:0:0:0254"), "cloud-metadata")
  expect_identical(classify("fd00:ec2:0:0:0:0:0:254"), "cloud-metadata")
  expect_identical(classify("FD00:0EC2::254"), "cloud-metadata")
  expect_identical(classify("fd00:0ec2:ffff::1"), "cloud-metadata")
  # End to end through the real parse path as well.
  expect_identical(guard("http://[fd00:0ec2::254]/")$reason, "cloud-metadata")
  # Neighbours outside the /32 stay allowed: only these two hextets match.
  expect_true(is.na(classify("fd00:ec3::254")))
  expect_true(is.na(classify("fd01:ec2::254")))
  expect_true(is.na(classify("fd00::1")))
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

# ---- specials classify on the expanded address, not the literal --------------

# Helper: the pure matcher with rurl out of the picture, so these pin layer 2
# on its own rather than rurl's canonicalization of the literal (SITE-vovtwvuh).
reason_of <- function(host) sitemapr_test_ns$ssrf_check(host, "http")$reason

test_that("every spelling of ::1 classifies as loopback", {
  # All six are the SAME 128 bits. Deciding the specials on the literal string
  # matched only the exact "::1" and let every other spelling reach the default
  # allow -- ssrf_embedded_ipv4() deliberately skips tail32 <= 1, so the
  # embedding decoder did not catch them either. Matching the EXPANDED hextets
  # is what makes all spellings agree.
  expect_identical(reason_of("[::1]"), "loopback")
  expect_identical(reason_of("[0::1]"), "loopback")
  expect_identical(reason_of("[::0:1]"), "loopback")
  expect_identical(reason_of("[0:0:0:0:0:0:0:1]"), "loopback")
  expect_identical(reason_of("[::0.0.0.1]"), "loopback")
  expect_identical(reason_of("[0:0:0:0:0:0:0.0.0.1]"), "loopback")
})

test_that("every spelling of :: classifies as unspecified", {
  expect_identical(reason_of("[::]"), "unspecified")
  expect_identical(reason_of("[0::]"), "unspecified")
  expect_identical(reason_of("[::0]"), "unspecified")
  expect_identical(reason_of("[0:0:0:0:0:0:0:0]"), "unspecified")
  expect_identical(reason_of("[::0.0.0.0]"), "unspecified")
  expect_identical(reason_of("[0:0:0:0:0:0:0.0.0.0]"), "unspecified")
})

test_that("dotted spellings of ::1 and :: are blocked on both layers", {
  # Defense in depth, both layers pinned so neither can regress silently behind
  # the other: (1) rurl canonicalizes the literal before the matcher sees it,
  # (2) ssrf_classify_ipv6() now classifies the expanded address, so it catches
  # these on its own even if rurl stops normalizing them.
  expect_identical(guard("http://[::0.0.0.1]/")$reason, "loopback")
  expect_identical(guard("http://[::0.0.0.0]/")$reason, "unspecified")
})

test_that("the specials do not swallow neighbouring addresses", {
  # One past the loopback special: with the low hextet above 1 the literal is
  # no longer a special and still routes to the embedding decoder, so the
  # deprecated IPv4-compatible reason keeps its meaning.
  expect_identical(reason_of("[::2]"), "ipv4-compatible")
  # A public IPv4-compatible address is still allowed, so the wider special
  # match did not turn into over-blocking.
  expect_true(is.na(reason_of("[::8.8.8.8]")))
  # A literal that does not expand to 8 hextets is not a special either — it is
  # refused before any rule runs (SITE-zgufvkks).
  expect_identical(
    sitemapr_test_ns$ssrf_classify_ipv6("1:2:3"),
    "malformed-address"
  )
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

# ---- IPv6 transition embeddings: 6to4 / Teredo / ISATAP (SITE-uxxdadsa) ------
# Each of these packs the IPv4 address somewhere other than the low 32 bits, so
# the tail-reading decoders above miss them and every vector here reached the
# default allow before the decoders were added. The blocked/public pairs are the
# point: these prefixes are legitimately reachable, so only the WRAPPED address
# may decide the outcome.

test_that("6to4 2002::/16 decodes the IPv4 at bits 16-47", {
  # Wrapping, in order: 127.0.0.1, 10.0.0.1, 192.168.0.1.
  expect_identical(guard("http://[2002:7f00:1::]/")$reason, "6to4")
  expect_identical(guard("http://[2002:a00:1::]/")$reason, "6to4")
  expect_identical(guard("http://[2002:c0a8:1::]/")$reason, "6to4")
})

test_that("6to4 wrapping the cloud-metadata IP is rejected", {
  res <- guard("http://[2002:a9fe:a9fe::]/") # a9fe:a9fe == 169.254.169.254
  expect_false(res$allowed)
  expect_identical(res$reason, "6to4")
})

test_that("6to4 wrapping a PUBLIC address is allowed", {
  # 8080:8080 == 128.128.128.128. The 2002::/16 prefix is globally reachable,
  # so the prefix alone must not block.
  res <- guard("http://[2002:8080:8080::]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("Teredo 2001::/32 undoes the XOR obfuscation of the client IPv4", {
  # f5ff:fffe XOR ffff:ffff == 0a00:0001 == 10.0.0.1.
  expect_identical(
    guard("http://[2001:0:0:0:0:0:f5ff:fffe]/")$reason,
    "teredo"
  )
  # 5601:5601 XOR ffff:ffff == a9fe:a9fe == 169.254.169.254.
  res <- guard("http://[2001:0:0:0:0:0:5601:5601]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "teredo")
})

test_that("Teredo wrapping a PUBLIC address is allowed", {
  # f7f7:f7f7 XOR ffff:ffff == 0808:0808 == 8.8.8.8.
  res <- guard("http://[2001:0:0:0:0:0:f7f7:f7f7]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("the Teredo prefix does not swallow 2001:db8::/32", {
  # Teredo is 2001:0000::/32 — the second hextet must be zero. The
  # documentation range 2001:db8::/32 is a neighbour, not a Teredo address.
  res <- guard("http://[2001:db8::1]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("ISATAP decodes the IPv4 after the marker under ANY prefix", {
  # Global prefix: nothing but the marker identifies the form.
  expect_identical(guard("http://[2001:db8::5efe:a00:1]/")$reason, "isatap")
  # Both documented markers (u-bit clear and set) are recognized.
  expect_identical(guard("http://[2001:db8::200:5efe:a00:1]/")$reason, "isatap")
})

test_that("ISATAP under a link-local prefix names the embedded address", {
  # fe80::5efe:a00:1 was blocked before this decoder existed, but only
  # incidentally — by the outer fe80::/10 rule. It is now blocked for the
  # actual reason: it wraps 10.0.0.1.
  res <- guard("http://[fe80::5efe:a00:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "isatap")
})

test_that("ISATAP wrapping a PUBLIC address is allowed", {
  # 808:808 == 8.8.8.8 under a documentation prefix.
  res <- guard("http://[2001:db8::5efe:808:808]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

test_that("ISATAP wrapping a public address still falls back to the prefix", {
  # The embedded address is public, so the ISATAP decoder allows it — but the
  # outer fe80::/10 prefix still blocks, and reports its own reason.
  res <- guard("http://[fe80::5efe:808:808]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "link-local")
})

test_that("an ISATAP-shaped hextet pair without the marker is allowed", {
  # 5eff is not the 5efe marker; nothing here embeds an address.
  res <- guard("http://[2001:db8::5eff:a00:1]/")
  expect_true(res$allowed)
  expect_true(is.na(res$reason))
})

# ---- malformed IPv6 literals fail closed (SITE-zgufvkks) ---------------------
# These are unreachable through the integration surface — rurl rejects them
# before the guard sees them — so they are driven through ssrf_check() directly.
# The point of the change is precisely that the guard no longer leans on rurl
# for this: a literal it cannot expand is refused on its own authority.

test_that("a malformed IPv6 literal is refused, not allowed", {
  malformed <- function(host) {
    sitemapr_test_ns$ssrf_check(host = host, scheme = "https")
  }
  # Three colons in a row: no valid "::" run to expand.
  expect_identical(malformed("[fe80:::1]")$reason, "malformed-address")
  # Over-long hextet.
  expect_identical(malformed("[::12345]")$reason, "malformed-address")
  # Dotted-quad tail that is not a valid IPv4 address.
  expect_identical(malformed("[::ffff:999.1.1.1]")$reason, "malformed-address")
  # More than one zero-compression run.
  expect_false(malformed("[1::2::3]")$allowed)
})

test_that("well-formed IPv6 literals are unaffected by the fail-closed rule", {
  res <- sitemapr_test_ns$ssrf_check(host = "[2606:2800::]", scheme = "https")
  expect_true(res$allowed)
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
  # Takes the expanded hextets, not the literal: the classifier expands once
  # and every rule reads that same expansion (SITE-mhfmtdxa). A literal that
  # does not expand never reaches here — ssrf_classify_ipv6() refuses it first
  # (SITE-zgufvkks) — so these helpers take 8 hextets, never NULL.
  reason <- function(s) {
    sitemapr_test_ns$ssrf_embedded_reason(sitemapr_test_ns$ssrf_ipv6_hextets(s))
  }
  # Well-formed IPv6 with no embedding prefix.
  expect_true(is.na(reason("fe80::1")))
  # Embedding prefix but a PUBLIC embedded address is allowed (NA).
  expect_true(is.na(reason("::ffff:8.8.8.8")))
  # Embedding prefix wrapping a blocked address yields its reason code.
  expect_identical(reason("::ffff:127.0.0.1"), "ipv4-mapped")
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
