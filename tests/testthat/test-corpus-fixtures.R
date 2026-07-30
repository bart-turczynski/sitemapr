# Broad-coverage smoke test + golden reference over the imported
# sitemap-validator fixture corpus (SITE-uivyzfhe).
#
# Every language-agnostic fixture under fixtures/corpus/ is driven through the
# public validate_sitemap() entry point. The corpus was imported wholesale from
# sitemap-validator's fixtures/ (see fixtures/COPYRIGHTS) so the recorded
# outcomes can double as a cross-port reference: the TS validator run over the
# same files should classify each one the same way.
#
# HOW FAR THAT ACTUALLY HOLDS (audited SITE-bqooxeze, 2026-07-30 — this file
# used to assert flatly that the two trees are byte-identical, and they are
# not):
#
#   79 of 80 paths are shared, and 78 of those are byte-identical.
#   Three divergences exist, all of them sitemapr's own doing:
#     * xml/unsupported-root.xml   CONTENT differs. sitemapr rewrote it from an
#                                  <rss> feed to a <catalog> document at 8d5bf83
#                                  because feeds became parseable and the
#                                  fixture stopped exercising UNSUPPORTED_ROOT.
#                                  The sibling still ships the <rss> original,
#                                  so this row compares two different documents.
#     * xml/video-no-player-or-content-loc.xml  sitemapr ONLY, added at 64e4119
#                                  (SITE-ciedgveo).
#     * xml/valid-pagemap.xml      sibling ONLY, never imported here.
#   Both unilateral changes happened despite the standing rule against them, and
#   neither was visible from this file, which kept asserting byte-identity.
#
#   79 of 80 fixtures ARE referenced by the sibling (all via fixtures/index.ts,
#   many also by fixtures/fixtures.test.ts and its e2e suites). The worry raised
#   on SITE-vepzywnc — that the encoding/ fixtures are referenced nowhere over
#   there — is REFUTED: all six are. The one unreferenced file is sitemapr's own
#   unilateral addition above.
#
#   The sibling has no golden TABLE: its expectations are hand-written
#   assertions in fixtures.test.ts. So corpus-golden.tsv is regenerated only
#   ever from THIS implementation, and cannot by itself catch a case where both
#   the code and the golden are wrong together (it has happened twice:
#   text/utf8-bom.txt enshrined the BOM bug; encoding/bom-conflict.xml sat at
#   <none> because the producer did not exist). Recording the sibling side
#   independently is the open follow-up; this file does not claim to do it.
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
#
# A third invariant lives in the parameterized-case layer at the bottom of this
# file, which reaches behaviour no fixture FILE can express. See its header.

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
      expect_named(res$tbl, contract_cols, info = rel)
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

# ---- parameterized cases -----------------------------------------------------
#
# Some shipped behaviour cannot be reached by handing a fixture to
# validate_sitemap() as a LOCAL FILE, and no fixture file can fix that. Adding
# more files to a corpus that must stay in step with the sibling would not help,
# because the missing ingredient is not content:
#
#   * A limit-driven rule needs the LIMIT LOWERED, not a bigger fixture. Pinning
#     PROTOCOL_URL_COUNT_EXCEEDED from the corpus would otherwise mean
#     committing a 50 001-URL document.
#   * Anything keyed off RESPONSE HEADERS needs a response. A local file has
#     none, so charset and content_type are always NA and the whole
#     classification-by-declared-type surface is outside the corpus by
#     construction.
#   * The aggregate traversal budgets are per-TRAVERSAL. A local index is never
#     traversed (its children are remote URLs), so INDEX_TOTAL_SITEMAPS_EXCEEDED
#     and INDEX_TOTAL_URLS_EXCEEDED cannot trip from a file at any limit —
#     verified, not assumed.
#
# Cases therefore layer OVER the corpus: the same shared fixture bytes, plus
# per-case options, per-case validate_sitemap() arguments, and optionally a
# served response.
#
# They are pinned in their OWN golden (corpus-cases-golden.tsv), deliberately
# not mixed into corpus-golden.tsv. corpus-golden.tsv is the cross-port artifact
# and every row in it is a claim about both ports; the sibling has no notion of
# these parameters, so folding cases in would quietly claim an agreement nobody
# checked.

# The URL a served case is fetched from. Any OTHER URL the traversal reaches is
# an index child, answered with a minimal one-URL urlset so expansion has
# something real to count without a second fixture.
#
# Deliberately on example.com, the host every corpus fixture's own URLs use: a
# different host would make each served case additionally report
# PROTOCOL_URL_OUT_OF_SCOPE, burying the behaviour under test in noise created
# by the harness rather than by the fixture.
corpus_case_url <- "https://example.com/case.xml"

corpus_case_child <- paste0(
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
  "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
  "<url><loc>https://example.com/a</loc></url>",
  "</urlset>"
)

corpus_case_mock <- function(bytes, content_type) {
  function(req) {
    body <- if (identical(req$url, corpus_case_url)) {
      bytes
    } else {
      charToRaw(corpus_case_child)
    }
    httr2::response(
      200,
      url = req$url,
      headers = list(`Content-Type` = content_type),
      body = body
    )
  }
}

# One case. `label` names what is being varied and becomes half of the golden
# key, so a case is identifiable without reading this file.
corpus_case <- function(
  file,
  label,
  options = list(),
  args = list(),
  content_type = NULL
) {
  list(
    file = file,
    label = label,
    options = options,
    args = args,
    content_type = content_type
  )
}

# Drive one case and normalize its result exactly as corpus_outcome() does, so
# the two goldens read the same way.
corpus_case_outcome <- function(case) {
  path <- file.path(corpus_root(), case$file)
  run <- function() {
    target <- if (is.null(case$content_type)) path else corpus_case_url
    do.call(validate_sitemap, c(list(target), case$args))
  }
  served <- function() {
    if (is.null(case$content_type)) {
      return(run())
    }
    bytes <- readBin(path, "raw", file.size(path))
    httr2::with_mocked_responses(
      corpus_case_mock(bytes, case$content_type),
      run()
    )
  }
  suppressWarnings(tryCatch(
    withr::with_options(case$options, {
      codes <- sort(unique(served()$code))
      if (length(codes)) paste(codes, collapse = " ") else "<none>"
    }),
    error = function(e) {
      sm <- grep("^sitemapr_", class(e), value = TRUE)
      if (length(sm)) paste0("!", sm[[1]]) else paste0("!BASE:", class(e)[[1]])
    }
  ))
}

# The registered cases. Each names the SITE-bqooxeze "want" it discharges, so a
# case cannot quietly lose its reason for existing.
corpus_cases <- function() {
  list(
    # Want 2: the URL-count cap, on both the text and the XML path. The text
    # path's cap had no coverage anywhere in the corpus because it needs a
    # parameter, not a file.
    corpus_case(
      "text/valid.txt",
      "max_url_count=1",
      options = list(sitemapr.max_url_count = 1L)
    ),
    corpus_case(
      "xml/valid-core.xml",
      "max_url_count=1",
      options = list(sitemapr.max_url_count = 1L)
    ),
    # Want 6: the inflated-size ceilings. Lowering the ceiling over a real 280-
    # byte gzip fixture reaches the same guard a committed multi-megabyte
    # expansion blob would, without a blob the 5 MB pre-commit hook would fight
    # and without inventing a generated-fixture convention the sibling has never
    # agreed to. Note the two paths differ: a top-level .xml.gz is judged on its
    # UNCOMPRESSED size and reports a finding, while the archive ceiling raises
    # a classed condition instead.
    corpus_case(
      "compressed/valid.xml.gz",
      "max_uncompressed_bytes=100",
      options = list(sitemapr.max_uncompressed_bytes = 100)
    ),
    corpus_case(
      "compressed/valid.tar.gz",
      "archive.max_decompressed=100",
      options = list(sitemapr.archive.max_decompressed = 100)
    ),
    # Want 7: the aggregate traversal budgets, which had zero corpus rows and
    # could not get one. Both need the index SERVED so its children are actually
    # fetched and counted.
    corpus_case(
      "xml/valid-index.xml",
      "served max_total_sitemaps=2",
      content_type = "application/xml",
      args = list(index_limits = index_limits(max_total_sitemaps = 2))
    ),
    corpus_case(
      "xml/valid-index.xml",
      "served max_total_urls=1",
      content_type = "application/xml",
      args = list(index_limits = index_limits(max_total_urls = 1))
    ),
    # The response-metadata surface itself: a charset only a response can carry,
    # disagreeing with the document's own declaration and, separately, supplying
    # the only encoding signal a document has. An AGREEING charset is not
    # registered here: it produces no finding, so it would be a case that cannot
    # fail, which the guard below rejects on purpose.
    corpus_case(
      "encoding/declared-utf8-no-bom.xml",
      "served charset=ISO-8859-1",
      content_type = "application/xml; charset=ISO-8859-1"
    ),
    corpus_case(
      "encoding/no-encoding.xml",
      "served charset=ISO-8859-1",
      content_type = "application/xml; charset=ISO-8859-1"
    )
  )
}

test_that("every parameterized case names a fixture that exists", {
  for (case in corpus_cases()) {
    expect_true(
      file.exists(file.path(corpus_root(), case$file)),
      info = case$file
    )
  }
})

test_that("parameterized-case outcomes match their committed golden", {
  cases <- corpus_cases()
  keys <- vapply(
    cases,
    function(case) paste0(case$file, "#", case$label),
    character(1)
  )
  outcomes <- vapply(cases, corpus_case_outcome, character(1))
  current <- paste0(keys, "\t", outcomes)
  golden_path <- test_path("fixtures", "corpus-cases-golden.tsv")

  if (nzchar(Sys.getenv("REGEN_CORPUS_GOLDEN"))) {
    writeLines(current, golden_path)
    skip("Regenerated fixtures/corpus-cases-golden.tsv")
  }

  expect_identical(current, readLines(golden_path))
})

test_that("each case actually changes the plain-file outcome", {
  # A case whose parameter makes no difference is dead weight that would still
  # pass its golden. Every registered case must diverge from the same fixture
  # validated as a plain local file with default limits.
  for (case in corpus_cases()) {
    expect_false(
      identical(corpus_case_outcome(case), corpus_outcome(case$file)$label),
      info = paste0(case$file, "#", case$label)
    )
  }
})
