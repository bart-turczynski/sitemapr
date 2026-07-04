# Broad-coverage smoke test + golden reference over the imported
# sitemap-validator fixture corpus (SITE-uivyzfhe).
#
# Every language-agnostic fixture under fixtures/corpus/ is driven through the
# public validate_sitemap() entry point. The corpus is byte-identical to
# sitemap-validator's fixtures/ (see fixtures/COPYRIGHTS), so the recorded
# outcomes double as a cross-port golden reference: the TS validator run over
# the same files should classify each one the same way.
#
# Two invariants are locked in:
#   1. No fixture may crash with an uncaught base-R error. Each is either
#      validated into the 10-column findings contract or fails with a *classed*
#      sitemapr_* condition (a documented limitation: corrupt/tar archives,
#      UTF-16, malformed/empty XML). A bare simpleError is a bug.
#   2. The per-fixture outcome (finding codes, or the classed-error class) is
#      pinned in a committed golden map (fixtures/corpus-golden.tsv) — a plain
#      file rather than a testthat snapshot, since _snaps/ is gitignored here.
#      Regenerate after an intended behavior change with:
#        REGEN_CORPUS_GOLDEN=1 Rscript -e \
#          'devtools::load_all(); \
#           testthat::test_file("tests/testthat/test-corpus-fixtures.R")'

contract_cols <- c(
  "code",
  "severity",
  "layer",
  "subject_type",
  "subject_ref",
  "message",
  "evidence",
  "mode",
  "is_strict_only",
  "remediation_hint"
)

corpus_root <- function() test_path("fixtures", "corpus")

corpus_files <- function() sort(list.files(corpus_root(), recursive = TRUE))

# Drive one fixture through validate_sitemap() and normalize the result. On
# success: the sorted unique finding codes (or "<none>"). On failure: the
# most-specific sitemapr_* condition class, or a "BASE:" label flagging an
# uncaught base-R error. Encoding-mismatch warnings from the XML reader are
# expected library noise and suppressed — only the outcome classification is
# under test here.
corpus_outcome <- function(rel) {
  path <- file.path(corpus_root(), rel)
  suppressWarnings(tryCatch(
    {
      out <- validate_sitemap(path)
      codes <- sort(unique(out$code))
      list(
        ok = TRUE,
        tbl = out,
        label = if (length(codes)) paste(codes, collapse = " ") else "<none>"
      )
    },
    error = function(e) {
      sm <- grep("^sitemapr_", class(e), value = TRUE)
      list(
        ok = FALSE,
        classed = length(sm) > 0L,
        label = if (length(sm)) {
          paste0("!", sm[[1]])
        } else {
          paste0("!BASE:", class(e)[[1]])
        }
      )
    }
  ))
}

test_that("the imported corpus is present", {
  # Guards against an accidental deletion silently emptying the coverage.
  expect_gt(length(corpus_files()), 70L)
})

test_that("no corpus fixture crashes with an uncaught base-R error", {
  for (rel in corpus_files()) {
    res <- corpus_outcome(rel)
    if (res$ok) {
      expect_true(inherits(res$tbl, "tbl_df"), info = rel)
      expect_identical(names(res$tbl), contract_cols, info = rel)
    } else {
      expect_true(
        res$classed,
        info = paste0(rel, " raised a non-sitemapr error: ", res$label)
      )
    }
  }
})

test_that("corpus outcomes match the committed golden reference", {
  files <- corpus_files()
  outcomes <- vapply(
    files,
    function(rel) corpus_outcome(rel)$label,
    character(1)
  )
  current <- paste0(files, "\t", outcomes)
  golden_path <- test_path("fixtures", "corpus-golden.tsv")

  if (nzchar(Sys.getenv("REGEN_CORPUS_GOLDEN"))) {
    writeLines(current, golden_path)
    skip("Regenerated fixtures/corpus-golden.tsv")
  }

  expect_identical(current, readLines(golden_path))
})
