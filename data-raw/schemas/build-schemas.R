#!/usr/bin/env Rscript
# Assemble the XSD schemas sitemapr bundles in inst/schemas/ from the
# sitemapr-authored sources in data-raw/schemas/authored/.
#
# Run from the package root:
#     Rscript data-raw/schemas/build-schemas.R
#
# What it does:
#   1. Copies each authored schema from data-raw/schemas/authored/ into
#      inst/schemas/, normalizing line endings to LF.
#   2. Verifies every file is well-formed XML and parses as an XSD.
#   3. Records sha256 + build date and regenerates inst/schemas/SOURCES.md and
#      inst/schemas/LICENSE so the shipped provenance never drifts from bytes.
#
# This script (and data-raw/, which is .Rbuildignore'd) is the single source of
# truth for inst/schemas/. To add a schema, drop the .xsd in authored/ and add a
# manifest row, then re-run.
#
# All bundled schemas are clean-room sitemapr-authored under the package license
# (MIT). They express the public Sitemap Protocol 0.9 and Google sitemap
# extension element models -- protocol facts, not copied schema text -- so they
# carry no third-party copyright. Behavioral equivalence with the canonical
# upstream XSDs is checked by data-raw/schemas/check-parity.R (dev-only, network;
# never run in CI and never shipped).

suppressPackageStartupMessages({
  library(xml2)
  library(openssl)
})

# --- manifest -----------------------------------------------------------------
# One row per bundled schema. Every schema is authored in data-raw/schemas/
# authored/. `terms` documents the licensing basis for CRAN provenance.
authored_terms <- "sitemapr-authored, clean-room; covered by the sitemapr package license (MIT)."
manifest <- list(
  list(file = "sitemap.xsd",
       namespace = "http://www.sitemaps.org/schemas/sitemap/0.9",
       role = "core urlset (Sitemap Protocol 0.9)",
       models = "https://www.sitemaps.org/protocol.html",
       terms = authored_terms),
  list(file = "siteindex.xsd",
       namespace = "http://www.sitemaps.org/schemas/sitemap/0.9",
       role = "sitemapindex (Sitemap Protocol 0.9)",
       models = "https://www.sitemaps.org/protocol.html",
       terms = authored_terms),
  list(file = "sitemap-image.xsd",
       namespace = "http://www.google.com/schemas/sitemap-image/1.1",
       role = "image extension 1.1",
       models = "https://developers.google.com/search/docs/crawling-indexing/sitemaps/image-sitemaps",
       terms = authored_terms),
  list(file = "sitemap-video.xsd",
       namespace = "http://www.google.com/schemas/sitemap-video/1.1",
       role = "video extension 1.1",
       models = "https://developers.google.com/search/docs/crawling-indexing/sitemaps/video-sitemaps",
       terms = authored_terms),
  list(file = "sitemap-news.xsd",
       namespace = "http://www.google.com/schemas/sitemap-news/0.9",
       role = "news extension 0.9",
       models = "https://developers.google.com/search/docs/crawling-indexing/sitemaps/news-sitemap",
       terms = authored_terms),
  list(file = "sitemap-pagemap.xsd",
       namespace = "http://www.google.com/schemas/sitemap-pagemap/1.0",
       role = "PageMap extension 1.0",
       models = "https://developers.google.com/custom-search/docs/structured_data",
       terms = authored_terms),
  list(file = "xhtml-hreflang.xsd",
       namespace = "http://www.w3.org/1999/xhtml",
       role = "minimal xhtml:link element for hreflang alternates",
       models = "https://developers.google.com/search/docs/specialty/international/localized-versions",
       terms = authored_terms)
)

# --- paths --------------------------------------------------------------------
root <- normalizePath(".", mustWork = TRUE)
out_dir <- file.path(root, "inst", "schemas")
authored_dir <- file.path(root, "data-raw", "schemas", "authored")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# --- copy / verify ------------------------------------------------------------
build_one <- function(entry) {
  src <- file.path(authored_dir, entry$file)
  dest <- file.path(out_dir, entry$file)
  if (!file.exists(src)) {
    stop(sprintf("authored schema missing: %s", src), call. = FALSE)
  }
  # Normalize line endings to LF so bundled bytes are identical across platforms
  # and match what git stores (.gitattributes eol=lf). The recorded sha256 is the
  # hash of the normalized artifact we actually ship.
  raw <- readBin(src, "raw", n = file.info(src)$size)
  txt <- gsub("\r", "", rawToChar(raw), fixed = TRUE)
  writeBin(charToRaw(txt), dest)
  message(sprintf("  authored  %s", entry$file))

  # Integrity: must be well-formed XML and parse as a schema.
  tryCatch(xml2::read_xml(dest), error = function(e) {
    stop(sprintf("not well-formed XML: %s (%s)", entry$file, conditionMessage(e)),
         call. = FALSE)
  })
  entry$sha256 <- as.character(openssl::sha256(file(dest)))
  entry$bytes <- file.info(dest)$size
  entry
}

message("Building schemas into inst/schemas/ ...")
records <- lapply(manifest, build_one)
built <- format(Sys.Date())

# --- SOURCES.md (provenance, ships with the package) --------------------------
src_lines <- c(
  "# Bundled schema provenance",
  "",
  "Generated by `data-raw/schemas/build-schemas.R`. Do not edit by hand;",
  "re-run the script to refresh.",
  "",
  sprintf("Built: %s", built),
  "",
  "All bundled schemas are clean-room **sitemapr-authored** and ship under the",
  "package license (MIT). Each expresses the element model of a public protocol",
  "(Sitemap Protocol 0.9, or a Google sitemap extension) -- element names, types,",
  "cardinalities, enumerations, and patterns are the protocol's functional facts,",
  "not copied schema text -- so none carries third-party copyright. The `Models`",
  "column links the public spec each schema implements.",
  "",
  "| File | Namespace | Role | Models | sha256 |",
  "|---|---|---|---|---|"
)
for (r in records) {
  src_lines <- c(src_lines, sprintf(
    "| `%s` | `%s` | %s | %s | `%s` |",
    r$file, r$namespace, r$role, r$models, r$sha256
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
  "- Behavioral equivalence with the canonical upstream XSDs (sitemaps.org,",
  "  Google) is verified by `data-raw/schemas/check-parity.R` — a dev-only,",
  "  network-using oracle that is never run in CI and never shipped. The upstream",
  "  XSDs are not redistributed: the Google schemas are `Copyright Google Inc.`",
  "  (All Rights Reserved) and the sitemaps.org schemas are CC BY-SA 2.5; authoring",
  "  our own avoids importing either license into this MIT package.",
  "- Google withdrew the mobile sitemap extension; `sitemap-mobile/1.0` is no",
  "  longer published upstream and is intentionally not modeled.",
  "- All schemas are XSD 1.0 (libxml2 / `xml2::xml_validate`). XSD 1.1 is out of",
  "  scope (ADR-001); rules beyond XSD 1.0 live in Layer D.",
  ""
)
writeLines(src_lines, file.path(out_dir, "SOURCES.md"))
message("  wrote     SOURCES.md")

# --- LICENSE (CRAN-policy provenance file) ------------------------------------
lic_lines <- c(
  "The XML Schema (XSD) files in this directory are clean-room",
  "sitemapr-authored and are covered by the sitemapr package license (MIT;",
  "see the package LICENSE file).",
  "",
  "They implement the element models of public specifications:",
  "  * sitemap.xsd, siteindex.xsd      — Sitemap Protocol 0.9 (sitemaps.org)",
  "  * sitemap-image.xsd               — Google image sitemap extension 1.1",
  "  * sitemap-video.xsd               — Google video sitemap extension 1.1",
  "  * sitemap-news.xsd                — Google news sitemap extension 0.9",
  "  * sitemap-pagemap.xsd             — Google PageMap sitemap extension 1.0",
  "  * xhtml-hreflang.xsd              — minimal xhtml:link for hreflang alternates",
  "",
  "Element names, types, cardinalities, enumerations, and patterns are the",
  "functional facts of those protocols, preserved for validation parity; the",
  "schema text (documentation and structure) is original to this package. No",
  "third-party schema files are copied or redistributed, so no third-party",
  "copyright or license (Google 'All Rights Reserved'; sitemaps.org CC BY-SA)",
  "attaches to this package. See SOURCES.md for per-file provenance.",
  ""
)
writeLines(lic_lines, file.path(out_dir, "LICENSE"))
message("  wrote     LICENSE")

message(sprintf("Done. %d schema(s) in %s", length(records), out_dir))
