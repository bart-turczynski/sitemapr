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
