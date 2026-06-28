# The bundled clean-room XSD profiles must accept the documents the protocols
# permit and reject those they forbid. This guards the authored schemas against
# regressions; equivalence with the canonical upstream XSDs is checked
# separately by the dev-only data-raw/schemas/check-parity.R oracle.

schemas_dir <- system.file("schemas", package = "sitemapr")

validate_doc <- function(xml, xsd_path) {
  doc <- xml2::read_xml(xml, options = c("NOBLANKS"))
  isTRUE(as.logical(xml2::xml_validate(doc, xml2::read_xml(xsd_path))))
}

test_that("bundled schemas directory ships", {
  skip_if(identical(schemas_dir, ""), "package not installed")
  expect_true(dir.exists(schemas_dir))
})

corpus <- schema_conformance_corpus()

for (schema_file in names(corpus)) {
  local({
    file <- schema_file
    cases <- corpus[[file]]
    test_that(sprintf("%s accepts/rejects per the protocol", file), {
      skip_if(identical(schemas_dir, ""), "package not installed")
      xsd <- file.path(schemas_dir, file)
      expect_true(file.exists(xsd))
      for (case in cases) {
        xml <- case[[1]]
        expected <- case[[2]]
        expect_identical(
          validate_doc(xml, xsd), expected,
          info = sprintf("%s: %s", file, substr(xml, 1, 80))
        )
      }
    })
  })
}
