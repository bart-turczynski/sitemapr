#!/usr/bin/env Rscript
# Dev-only clean-room parity oracle. NOT run in CI; NOT shipped (data-raw/ is
# .Rbuildignore'd). Uses the network.
#
# Downloads the canonical upstream XSDs (sitemaps.org, Google) to a tempdir and
# confirms that the clean-room schemas bundled in inst/schemas/ accept and
# reject the same corpus of documents. This is how we keep "behaviorally
# equivalent to upstream" honest without redistributing the upstream files
# (Google: All Rights Reserved; sitemaps.org: CC BY-SA 2.5).
#
# Run from the package root:
#     Rscript data-raw/schemas/check-parity.R
#
# Exit status is non-zero if any case diverges between authored and upstream, or
# fails its expected verdict.

suppressPackageStartupMessages(library(xml2))

root <- normalizePath(".", mustWork = TRUE)
bundled_dir <- file.path(root, "inst", "schemas")
UA <- "sitemapr-schema-parity/1 (+https://github.com/bart-turczynski/sitemapr)"

# Canonical upstream URLs, by bundled filename.
upstream <- c(
  "sitemap.xsd" = "https://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd", # nolint: line_length_linter.
  "siteindex.xsd" = "https://www.sitemaps.org/schemas/sitemap/0.9/siteindex.xsd", # nolint: line_length_linter.
  "sitemap-image.xsd" = "https://www.google.com/schemas/sitemap-image/1.1/sitemap-image.xsd", # nolint: line_length_linter.
  "sitemap-video.xsd" = "https://www.google.com/schemas/sitemap-video/1.1/sitemap-video.xsd", # nolint: line_length_linter.
  "sitemap-news.xsd" = "https://www.google.com/schemas/sitemap-news/0.9/sitemap-news.xsd", # nolint: line_length_linter.
  "sitemap-pagemap.xsd" = "https://www.google.com/schemas/sitemap-pagemap/1.0/sitemap-pagemap.xsd" # nolint: line_length_linter.
  # xhtml-hreflang.xsd has no single-element upstream XSD; nothing to diff.
)

tmp <- tempfile("upstream-xsd-")
dir.create(tmp)
for (f in names(upstream)) {
  ok <- tryCatch(
    utils::download.file(
      upstream[[f]],
      file.path(tmp, f),
      mode = "wb",
      quiet = TRUE,
      headers = c("User-Agent" = UA)
    ) ==
      0L,
    error = function(e) FALSE
  )
  if (!ok) stop(sprintf("download failed: %s", upstream[[f]]), call. = FALSE)
}

valid <- function(doc_str, xsd_path) {
  doc <- read_xml(doc_str, options = "NOBLANKS")
  isTRUE(as.logical(xml_validate(doc, read_xml(xsd_path))))
}

# Shared corpus, defined alongside the shipping conformance test.
sys.source(
  file.path(root, "tests", "testthat", "helper-schema-corpus.R"),
  envir = environment()
)
corpus <- schema_conformance_corpus()

fail <- 0L
ncase <- 0L
for (file in names(corpus)) {
  up <- file.path(tmp, file)
  if (!file.exists(up)) {
    next
  } # e.g. hreflang: no upstream
  au <- file.path(bundled_dir, file)
  for (case in corpus[[file]]) {
    ncase <- ncase + 1L
    xml <- case[[1]]
    exp <- case[[2]]
    vu <- valid(xml, up)
    va <- valid(xml, au)
    if (!(vu == exp && va == exp && vu == va)) {
      fail <- fail + 1L
      cat(sprintf(
        "[FAIL] %s expected=%s upstream=%s authored=%s\n      %s\n",
        file,
        exp,
        vu,
        va,
        substr(xml, 1, 90)
      ))
    }
  }
}
cat(sprintf(
  "\n%d cases checked against upstream, %d divergences\n",
  ncase,
  fail
))
quit(status = if (fail) 1L else 0L)
