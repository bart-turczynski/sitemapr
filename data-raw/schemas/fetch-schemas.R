#!/usr/bin/env Rscript
# Reproducible vendoring of the XSD schemas sitemapr bundles in inst/schemas/.
#
# Run from the package root:
#     Rscript data-raw/schemas/fetch-schemas.R
#
# What it does:
#   1. Downloads each upstream schema from its CANONICAL source (sitemaps.org,
#      Google) -- never from a third-party mirror or sibling project, so the
#      provenance trail is unambiguous.
#   2. Copies sitemapr-authored schemas from data-raw/schemas/authored/ (used
#      only where no upstream XSD exists, e.g. the xhtml:link hreflang element).
#   3. Verifies every file is well-formed XML (xml2) and a parseable XSD.
#   4. Records sha256 + retrieval date and regenerates inst/schemas/SOURCES.md
#      and inst/schemas/LICENSE so the bundled provenance never drifts from the
#      bytes actually shipped.
#
# This script is the single source of truth for what lives in inst/schemas/.
# To add a schema later, add a row to `manifest` (or drop a file in authored/
# and add an "authored" row) and re-run. data-raw/ is .Rbuildignore'd, so the
# script ships in the repo but not in the CRAN tarball.

suppressPackageStartupMessages({
  library(xml2)
  library(openssl)
})

# A polite, identifiable UA; some origins reject R's default.
UA <- "sitemapr-schema-vendor/1 (+https://github.com/bart-turczynski/sitemapr)"

# --- manifest -----------------------------------------------------------------
# One row per bundled schema. `source` is the canonical URL, or "authored" for
# files maintained in data-raw/schemas/authored/. `terms` documents the
# licensing/usage basis for CRAN provenance.
manifest <- list(
  list(
    file = "sitemap.xsd",
    namespace = "http://www.sitemaps.org/schemas/sitemap/0.9",
    role = "core urlset (Sitemap Protocol 0.9)",
    source = "https://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd",
    terms = "sitemaps.org content; Attribution-ShareAlike Creative Commons License."
  ),
  list(
    file = "siteindex.xsd",
    namespace = "http://www.sitemaps.org/schemas/sitemap/0.9",
    role = "sitemapindex (Sitemap Protocol 0.9)",
    source = "https://www.sitemaps.org/schemas/sitemap/0.9/siteindex.xsd",
    terms = "sitemaps.org content; Attribution-ShareAlike Creative Commons License."
  ),
  list(
    file = "sitemap-image.xsd",
    namespace = "http://www.google.com/schemas/sitemap-image/1.1",
    role = "Google image extension 1.1",
    source = "https://www.google.com/schemas/sitemap-image/1.1/sitemap-image.xsd",
    terms = "Copyright Google Inc.; published reference schema for the image extension."
  ),
  list(
    file = "sitemap-video.xsd",
    namespace = "http://www.google.com/schemas/sitemap-video/1.1",
    role = "Google video extension 1.1",
    source = "https://www.google.com/schemas/sitemap-video/1.1/sitemap-video.xsd",
    terms = "Copyright Google Inc.; published reference schema for the video extension."
  ),
  list(
    file = "sitemap-news.xsd",
    namespace = "http://www.google.com/schemas/sitemap-news/0.9",
    role = "Google news extension 0.9",
    source = "https://www.google.com/schemas/sitemap-news/0.9/sitemap-news.xsd",
    terms = "Copyright Google Inc.; published reference schema for the news extension."
  ),
  list(
    file = "sitemap-pagemap.xsd",
    namespace = "http://www.google.com/schemas/sitemap-pagemap/1.0",
    role = "Google PageMap extension 1.0",
    source = "https://www.google.com/schemas/sitemap-pagemap/1.0/sitemap-pagemap.xsd",
    terms = "Copyright Google Inc.; published reference schema for the PageMap extension."
  ),
  list(
    file = "xhtml-hreflang.xsd",
    namespace = "http://www.w3.org/1999/xhtml",
    role = "minimal xhtml:link element for hreflang alternates (sitemapr-authored)",
    source = "authored",
    terms = "sitemapr-authored; covered by the sitemapr package license. No upstream single-element XSD exists for the xhtml:link hreflang annotation."
  )
)

# --- paths --------------------------------------------------------------------
root <- normalizePath(".", mustWork = TRUE)
out_dir <- file.path(root, "inst", "schemas")
authored_dir <- file.path(root, "data-raw", "schemas", "authored")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# --- fetch / copy -------------------------------------------------------------
fetch_one <- function(entry) {
  dest <- file.path(out_dir, entry$file)
  if (identical(entry$source, "authored")) {
    src <- file.path(authored_dir, entry$file)
    if (!file.exists(src)) {
      stop(sprintf("authored schema missing: %s", src), call. = FALSE)
    }
    file.copy(src, dest, overwrite = TRUE)
    message(sprintf("  authored  %s", entry$file))
  } else {
    ok <- tryCatch(
      utils::download.file(
        entry$source, dest,
        mode = "wb", quiet = TRUE,
        headers = c("User-Agent" = UA)
      ) == 0L,
      error = function(e) FALSE
    )
    if (!ok || !file.exists(dest)) {
      stop(sprintf("download failed: %s", entry$source), call. = FALSE)
    }
    message(sprintf("  fetched   %s  <-  %s", entry$file, entry$source))
  }
  # Normalize line endings to LF so the bundled bytes are identical across
  # platforms and match what git stores (.gitattributes eol=lf). The recorded
  # sha256 is therefore the hash of the normalized artifact we actually ship,
  # not of the raw upstream stream.
  raw <- readBin(dest, "raw", n = file.info(dest)$size)
  txt <- gsub("\r", "", rawToChar(raw), fixed = TRUE)
  writeBin(charToRaw(txt), dest)

  # Integrity: must be well-formed XML (real schema validation lands in S6.4).
  tryCatch(xml2::read_xml(dest), error = function(e) {
    stop(sprintf("not well-formed XML: %s (%s)", entry$file, conditionMessage(e)),
         call. = FALSE)
  })
  entry$sha256 <- as.character(openssl::sha256(file(dest)))
  entry$bytes <- file.info(dest)$size
  entry
}

message("Vendoring schemas into inst/schemas/ ...")
records <- lapply(manifest, fetch_one)
retrieved <- format(Sys.Date())

# --- SOURCES.md (provenance, ships with the package) --------------------------
src_lines <- c(
  "# Bundled schema provenance",
  "",
  "Generated by `data-raw/schemas/fetch-schemas.R`. Do not edit by hand;",
  "re-run the script to refresh.",
  "",
  sprintf("Retrieved: %s", retrieved),
  "",
  "| File | Namespace | Role | Source | sha256 |",
  "|---|---|---|---|---|"
)
for (r in records) {
  src_lines <- c(src_lines, sprintf(
    "| `%s` | `%s` | %s | %s | `%s` |",
    r$file, r$namespace, r$role,
    if (identical(r$source, "authored")) "authored (see data-raw/schemas/authored/)" else r$source,
    r$sha256
  ))
}
src_lines <- c(
  src_lines, "",
  "## Terms",
  "",
  vapply(records, function(r) sprintf("- `%s` — %s", r$file, r$terms), character(1)),
  "",
  "## Notes",
  "",
  "- Google deprecated the mobile sitemap extension; `sitemap-mobile/1.0` is no",
  "  longer published upstream and is intentionally not bundled.",
  "- All schemas are XSD 1.0 (libxml2 / `xml2::xml_validate`). XSD 1.1 is out of",
  "  scope (ADR-001); rules beyond XSD 1.0 live in Layer D.",
  ""
)
writeLines(src_lines, file.path(out_dir, "SOURCES.md"))
message("  wrote     SOURCES.md")

# --- LICENSE (CRAN-policy provenance file) ------------------------------------
lic_lines <- c(
  "Bundled XML Schema (XSD) files in this directory are third-party assets,",
  "except where marked sitemapr-authored. See SOURCES.md for per-file source,",
  "retrieval date, checksum, and terms.",
  "",
  "Summary:",
  "  * sitemap.xsd, siteindex.xsd",
  "      Source: sitemaps.org (Sitemap Protocol 0.9).",
  "      Terms:  Attribution-ShareAlike Creative Commons License (sitemaps.org).",
  "  * sitemap-image.xsd, sitemap-video.xsd, sitemap-news.xsd, sitemap-pagemap.xsd",
  "      Source: Google (published sitemap extension reference schemas).",
  "      Terms:  Copyright Google Inc. Published as the reference schemas that",
  "              public sitemaps point at via xsi:schemaLocation.",
  "  * xhtml-hreflang.xsd",
  "      sitemapr-authored; covered by the sitemapr package license.",
  "",
  "CRAN note: confirm the Google schema redistribution terms are compatible with",
  "the package license before submission. This file documents provenance so the",
  "review can be made explicitly rather than discovered late.",
  ""
)
writeLines(lic_lines, file.path(out_dir, "LICENSE"))
message("  wrote     LICENSE")

message(sprintf("Done. %d schema(s) in %s", length(records), out_dir))
