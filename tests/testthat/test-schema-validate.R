# Direct unit tests for the Layer C finding-producer (R/schema-validate.R),
# driven by the S6.5 fixtures. These exercise validate_schema() in isolation;
# the cucumber feature (tests/testthat/features/schema_validation.feature) is
# deliberately NOT wired here — it activates in Layer F (SITE-ymzvnlpr) once
# validate_sitemap() exists (architecture.md §3; repo convention).

ref <- "sitemap://example.com/sitemap.xml"

read_fixture_doc <- function(name) {
  path <- test_path("fixtures", name)
  read_sitemap_xml(readBin(path, "raw", n = file.info(path)$size))
}

validate_fixture <- function(name, subject_ref = ref) {
  validate_schema(read_fixture_doc(name), subject_ref = subject_ref)
}

# --- Valid documents produce no schema findings ----------------------------

valid_fixtures <- c(
  "valid-minimal.xml",
  "valid-index.xml",
  "ns-image.xml",
  "ns-news.xml",
  "ns-video.xml",
  "ns-hreflang.xml",
  "ns-all-four.xml"
)

for (fx in valid_fixtures) {
  local({
    file <- fx
    test_that(sprintf("%s validates clean (no findings)", file), {
      skip_if(identical(schema_dir(), ""), "package not installed")
      out <- validate_fixture(file)
      expect_s3_class(out, "tbl_df")
      expect_identical(nrow(out), 0L)
    })
  })
}

test_that("the all-four mixed doc validates via a runtime-generated profile", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  doc <- read_fixture_doc("ns-all-four.xml")
  prof <- schema_profile(
    "urlset",
    schema_document_namespaces(doc),
    cache = new.env(parent = emptyenv()),
    dir = withr::local_tempdir()
  )
  expect_identical(prof$kind, "runtime")
  expect_identical(nrow(validate_fixture("ns-all-four.xml")), 0L)
})

# --- Invalid documents map to SCHEMA_INVALID, scoped to the element --------

test_that("a misplaced core element yields a scoped SCHEMA_INVALID", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture("schema-invalid-urlset.xml")
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_INVALID")
  expect_identical(out$layer, "schema")
  expect_identical(out$subject_type, "field")
  expect_identical(out$subject_ref, paste0(ref, "#field:priority"))
  expect_match(out$message, "core namespace")
  expect_match(out$evidence[[1]]$excerpt, "priority", fixed = TRUE)
})

test_that("an invalid extension element is scoped to that extension", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture("ns-video-invalid-in-mixed.xml")
  # The image/news/hreflang siblings are valid: only the video element fires.
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_INVALID")
  expect_identical(out$subject_ref, paste0(ref, "#field:not_a_field"))
  expect_match(out$message, "video namespace", fixed = TRUE)
  expect_match(
    out$evidence[[1]]$excerpt,
    "sitemap-video/1.1}not_a_field",
    fixed = TRUE
  )
})

# --- Unknown namespace -----------------------------------------------------

test_that("an unrecognised namespace yields SCHEMA_UNKNOWN_NAMESPACE", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture("ns-unknown.xml")
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_UNKNOWN_NAMESPACE")
  expect_identical(out$subject_type, "document")
  expect_identical(out$subject_ref, ref)
  expect_match(out$message, "https://example.com/ns/custom", fixed = TRUE)
  expect_identical(out$evidence[[1]]$excerpt, "https://example.com/ns/custom")
})

# --- XXE safety ------------------------------------------------------------

test_that("the XXE external entity is not expanded (no file contents leak)", {
  doc <- read_fixture_doc("xxe-attempt.xml")
  loc <- xml2::xml_text(xml2::xml_find_first(doc, "//*[local-name()='loc']"))
  # &xxe; expands to nothing, leaving the bare prefix — never host file bytes.
  expect_identical(loc, "https://example.com/")
})

test_that("an entity-bearing tree yields one clean SCHEMA_INVALID", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture("xxe-attempt.xml")
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_INVALID")
  expect_match(out$message, "entity references", fixed = TRUE)
  # The raw libxml2 internal-error text must never leak into the finding.
  expect_no_match(out$message, "xmlSchemaVDocWalk", fixed = TRUE)
})

# --- Scattered / defensive branches ----------------------------------------

test_that("a document with no declared namespaces yields an empty set", {
  doc <- read_sitemap_xml(
    charToRaw("<urlset><url><loc>https://a/</loc></url></urlset>")
  )
  expect_identical(schema_document_namespaces(doc), character())
})

test_that("a non-element libxml2 error maps to a document-scoped finding", {
  out <- schema_invalid_row(
    "A structural failure that names no element",
    subject_ref = ref
  )
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_INVALID")
  expect_identical(out$subject_type, "document")
  expect_identical(out$subject_ref, ref)
})

test_that("an invalid result with no usable error message still emits a row", {
  # xml_validate reported invalid but surfaced no message: the failure must not
  # be silently dropped.
  out <- schema_invalid_findings(c(NA_character_, ""), subject_ref = ref)
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "SCHEMA_INVALID")
  expect_identical(out$subject_type, "document")
})

test_that("an unsupported root element yields no schema findings", {
  doc <- read_sitemap_xml(charToRaw('<rss version="2.0"><channel/></rss>'))
  out <- validate_schema(doc, subject_ref = ref)
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
})

# --- Contract shape --------------------------------------------------------

test_that("findings carry the contract columns and types, minus Layer F bits", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture("schema-invalid-urlset.xml")
  expect_named(
    out,
    c(
      "code",
      "severity",
      "layer",
      "subject_type",
      "subject_ref",
      "message",
      "evidence",
      "is_strict_only"
    )
  )
  expect_type(out$code, "character")
  expect_type(out$severity, "character")
  expect_type(out$subject_ref, "character")
  expect_type(out$evidence, "list")
  expect_type(out$is_strict_only, "logical")
  # mode + filtering/dedup/sort are Layer F's; they are absent here.
  expect_false("mode" %in% names(out))
  # Evidence is the contract's named list.
  expect_named(
    out$evidence[[1]],
    c("excerpt", "line", "column")
  )
  # Schema findings fire in both modes (not strict-only) at error severity.
  expect_false(out$is_strict_only)
  expect_true(all(out$severity %in% c("error", "fatal")))
})

test_that("empty_schema_findings has the full schema, zero rows", {
  out <- empty_schema_findings()
  expect_identical(nrow(out), 0L)
  expect_true(all(
    c(
      "code",
      "severity",
      "layer",
      "subject_type",
      "subject_ref",
      "message",
      "evidence",
      "is_strict_only"
    ) %in%
      names(out)
  ))
})

test_that("an NA subject_ref produces fragment-only refs", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  out <- validate_fixture(
    "schema-invalid-urlset.xml",
    subject_ref = NA_character_
  )
  expect_identical(out$subject_ref, "#field:priority")
})

# --- No Java / subprocess --------------------------------------------------

test_that("schema validation spawns no subprocess (pure libxml2)", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  spawned <- 0L
  traced <- character()
  for (fn in c("system", "system2")) {
    ok <- tryCatch(
      {
        suppressMessages(trace(
          fn,
          quote(spawned <<- spawned + 1L),
          print = FALSE,
          where = baseenv()
        ))
        TRUE
      },
      error = function(e) FALSE
    )
    if (ok) traced <- c(traced, fn)
  }
  skip_if(length(traced) == 0L, "unable to trace base process functions")
  on.exit(
    for (fn in traced) {
      suppressMessages(untrace(fn, where = baseenv()))
    },
    add = TRUE
  )
  validate_fixture("ns-all-four.xml")
  validate_fixture("schema-invalid-urlset.xml")
  expect_identical(spawned, 0L)
})

test_that("the package declares no system requirement beyond xml2's", {
  # No Java, no JAVA_HOME, no SystemRequirements (architecture.md §8). Read the
  # installed package metadata rather than the source DESCRIPTION by relative
  # path: under `R CMD check` the tests run from the `.Rcheck` tree where
  # `../../DESCRIPTION` does not exist, so the relative read errored there.
  sysreq <- packageDescription("sitemapr", fields = "SystemRequirements")
  expect_true(is.na(sysreq))
})
