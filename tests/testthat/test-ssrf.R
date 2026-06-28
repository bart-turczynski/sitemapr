# SSRF guard unit tests (ADR-003 §1 matrix + fetch_classification.feature
# acceptance scenarios). Internal fns are referenced via sitemapr:::.

# Helper: run the guard the way the fetch engine will, by parsing a full URL
# through the real adapter and feeding the row to ssrf_check_parsed(). This
# exercises the integration surface and the rurl normalization behaviour.
guard <- function(url) {
  parsed <- sitemapr:::parse_url_adapter(url)
  sitemapr:::ssrf_check_parsed(parsed)
}

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
  res <- sitemapr:::ssrf_check(
    host = "[::ffff:127.0.0.1]", scheme = "http",
    raw_host = "[::ffff:127.0.0.1]"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("IPv4-mapped IPv6 of a PUBLIC address is allowed", {
  res <- sitemapr:::ssrf_check(
    host = "[::ffff:8.8.8.8]", scheme = "http",
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

test_that("compressed single-hextet mapped ::ffff:1 decodes to 0.0.0.1", {
  # High hextet implicitly 0, low hextet 1 -> 0.0.0.1 (unspecified 0.0.0.0/8).
  res <- guard("http://[::ffff:1]/")
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("fully-expanded hex-hextet mapped loopback is rejected", {
  res <- sitemapr:::ssrf_check(
    host = "[0:0:0:0:0:ffff:7f00:1]", scheme = "http",
    raw_host = "[0:0:0:0:0:ffff:7f00:1]"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "ipv4-mapped")
})

test_that("hex-hextet mapped form is case-insensitive", {
  res <- sitemapr:::ssrf_check(
    host = "[::FFFF:7F00:1]", scheme = "http",
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
  res <- sitemapr:::ssrf_check(
    host = "127.0.0.1", scheme = "http", raw_host = "0177.0.0.1"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "numeric-literal")
})

# ---- scheme gate -------------------------------------------------------------

test_that("non-http(s) scheme is rejected", {
  res <- sitemapr:::ssrf_check(
    host = "example.com", scheme = "ftp", raw_host = "example.com"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "scheme")
})

test_that("file scheme is rejected", {
  res <- sitemapr:::ssrf_check(
    host = "", scheme = "file", raw_host = ""
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "scheme")
})

test_that("https scheme is permitted through the scheme gate", {
  res <- sitemapr:::ssrf_check(
    host = "example.com", scheme = "https", raw_host = "example.com"
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
  res <- sitemapr:::ssrf_check(
    host = "example.com", scheme = "https", raw_host = "example.com"
  )
  expect_type(res, "list")
  expect_named(res, c("allowed", "reason"))
  expect_type(res$allowed, "logical")
})

# ---- matcher is independently testable (no disable flag inside) --------------

test_that("ssrf_check evaluates ranges regardless of any caller toggle", {
  # The guard has no disable flag; disabling is the caller's job. Confirm the
  # core matcher always evaluates and blocks a private address.
  res <- sitemapr:::ssrf_check(
    host = "10.0.0.1", scheme = "http", raw_host = "10.0.0.1"
  )
  expect_false(res$allowed)
  expect_identical(res$reason, "private")
})
