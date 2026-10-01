# ASCII-only case folding (SITE-rkstwdsr, fleet sweep SEOR-rxxuzhmc).

test_that("only ASCII letters change case", {
  expect_identical(
    ascii_lower("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
    "abcdefghijklmnopqrstuvwxyz"
  )
  expect_identical(
    ascii_upper("abcdefghijklmnopqrstuvwxyz"),
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  )
  expect_identical(
    ascii_lower("Text/HTML; Charset=UTF-8"),
    "text/html; charset=utf-8"
  )
  # Non-ASCII letters, the Turkish dotless and dotted I among them, pass
  # through unchanged in both directions.
  others <- intToUtf8(c(0xC4, 0x131, 0x130, 0xE4), multiple = TRUE)
  expect_identical(ascii_lower(others), others)
  expect_identical(ascii_upper(others), others)
  expect_identical(ascii_lower(c("ICANN", NA)), c("icann", NA))
  expect_identical(ascii_upper(character()), character())
})

test_that("protocol comparisons survive a Turkish locale", {
  # The hazard is glibc's: under tr_TR, tolower("I") is the dotless "ı". Run
  # where the platform has the locale; on macOS it exists but folds I to i, so
  # there the test only pins that nothing regresses.
  suppressWarnings(withr::local_locale(c(LC_CTYPE = "tr_TR.UTF-8")))
  skip_if_not(
    identical(Sys.getlocale("LC_CTYPE"), "tr_TR.UTF-8"),
    "tr_TR.UTF-8 locale not available"
  )
  expect_identical(ascii_lower("HTTPS://ID.EXAMPLE"), "https://id.example")
  expect_identical(ascii_upper("in"), "IN")
  # End to end through call sites that fold: a content type and an hreflang
  # region carrying I/i.
  html <- list(terminal_headers = list(`CONTENT-TYPE` = "TEXT/HTML"))
  expect_true(page_content_is_html(html))
  expect_true(hreflang_case_ok(c("hi", "IN"), c("lang", "region")))
})
