# The URL table links a sitemap <loc> only when its scheme is http or https
# (SITE-qmndjnmt). Fully offline: cells render from strings, and the end-to-end
# cases read a sitemap written to a local temp file.

url_cell_html <- function(url) {
  as.character(report_url_cell(url))
}

local_sitemap <- function(locs, env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = env)
  writeLines(
    paste0(
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      paste(sprintf("<url><loc>%s</loc></url>", locs), collapse = ""),
      "</urlset>"
    ),
    path
  )
  path
}

# ---- http(s) locs stay links -------------------------------------------------

test_that("an http or https loc renders as a link in the URL cell", {
  for (url in c("http://example.com/a", "https://example.com/b")) {
    html <- url_cell_html(url)
    expect_match(html, sprintf('<a href="%s"', url), fixed = TRUE)
    expect_match(html, 'class="smr-url"', fixed = TRUE)
    expect_match(html, 'rel="noopener noreferrer"', fixed = TRUE)
  }
})

test_that("http and https locs render as links in the report HTML", {
  path <- local_sitemap(c("http://example.com/a", "https://example.com/b"))
  html <- render_string(path)
  expect_match(html, '<a href="http://example.com/a"', fixed = TRUE)
  expect_match(html, '<a href="https://example.com/b"', fixed = TRUE)
})

test_that("the scheme match ignores ASCII case and edge whitespace", {
  for (url in c("HTTPS://example.com/c", " https://example.com/d\n")) {
    html <- url_cell_html(url)
    expect_match(html, "<a href=", fixed = TRUE)
  }
})

# ---- any other value renders as escaped text ---------------------------------

hostile_locs <- c(
  "javascript:alert(1)",
  "JavaScript:alert(1)",
  "  javascript:alert(1)",
  "java\tscript:alert(1)",
  "data:text/html,<script>alert(1)</script>",
  "vbscript:x",
  "\x01javascript:alert(1)",
  "java\nscript:alert(1)",
  "/relative/path",
  "http\u017f://example.com/" # a non-ASCII lookalike is not a scheme match
)

test_that("a loc whose scheme is not http(s) renders as text, not a link", {
  for (url in hostile_locs) {
    html <- url_cell_html(url)
    expect_no_match(html, "href", fixed = TRUE, info = url)
    expect_no_match(html, "<a", fixed = TRUE, info = url)
    # Same cell, same base class: the table layout and search still hold.
    expect_match(html, "<td>", fixed = TRUE, info = url)
    expect_match(html, "class=\"smr-url", fixed = TRUE, info = url)
    expect_match(html, htmltools::htmlEscape(url), fixed = TRUE, info = url)
  }
})

test_that("the text rendering of a non-link loc is HTML-escaped", {
  html <- url_cell_html("data:text/html,<script>alert(1)</script>")
  expect_match(html, "&lt;script&gt;alert(1)&lt;/script&gt;", fixed = TRUE)
  expect_no_match(html, "<script>", fixed = TRUE)
})

test_that("a hostile sitemap produces no script link in the report HTML", {
  path <- local_sitemap(c(
    "javascript:alert(document.domain)",
    "java&#9;script:alert(1)",
    "data:text/html,&lt;script&gt;alert(1)&lt;/script&gt;",
    "https://example.com/ok"
  ))
  html <- render_string(path)
  expect_no_match(html, "href=\"javascript:", fixed = TRUE)
  expect_no_match(html, "href=\"java\tscript:", fixed = TRUE)
  expect_no_match(html, "href=\"data:", fixed = TRUE)
  expect_match(
    html,
    paste0(
      '<span class="smr-url smr-url-text">',
      "javascript:alert(document.domain)</span>"
    ),
    fixed = TRUE
  )
  expect_match(html, '<a href="https://example.com/ok"', fixed = TRUE)
})

test_that("a loc that is not valid UTF-8 does not stop the link check", {
  # An unmarked string holding a lone Latin-1 byte: invalid UTF-8.
  bad <- "http:\xe9"
  expect_true(report_link_scheme_ok(bad))
  expect_false(report_link_scheme_ok(paste0("javascript:", bad)))
})
