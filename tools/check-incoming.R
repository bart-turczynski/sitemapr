#!/usr/bin/env Rscript

# CRAN incoming guard, a cheap gate of the fleet-ci local gate
# (.fleet-ci.yml's cheap_gates).
#
#   Rscript tools/check-incoming.R      # from the package root
#
# The `incoming` stage of the former tools/verify.R, moved here unchanged
# when the fleet-ci gate replaced that chain (SEOR-stasqeuk). The gate's
# R CMD check runs with CRAN incoming off, so these two checks matter more
# there, not less; t2-ascran runs the full incoming check in T2.

# The `incoming` stage: two checks from `R CMD check --as-cran`'s `checking
# CRAN incoming feasibility` that a local run skips, because R gates each on
# an environment variable that defaults to FALSE and CRAN sets to TRUE
# (`tools:::.check_package_CRAN_incoming()`, R 4.6.0). Both reached
# win-builder's NOTE before this gate saw them (SITE-bncwavxq).
#
# - `_R_CHECK_CRAN_INCOMING_USE_ASPELL_`: aspell over DESCRIPTION's Title and
#   Description. inst/WORDLIST does not apply there -- CRAN's dictionary is
#   aspell en_US plus en_GB and en_stats -- so the `spelling` stage, which
#   honors the WORDLIST, passed "tibbles" that CRAN flagged. Turning the
#   variable on locally would not help: it needs the `aspell` program, which
#   neither this machine nor the CI image has. So this checks the same text
#   with spelling's bundled hunspell en_US, after removing what CRAN's own
#   ignore patterns remove: 'quoted' names, foo() calls and <https://...>
#   links. Quoting is CRAN's convention for a name aspell cannot know.
# - `_R_CHECK_CRAN_INCOMING_CHECK_FILE_URIS_`: every relative link in the
#   package docs (README.md included) must resolve inside the BUILT package.
#   On a source tree the target exists, so a link to a .Rbuildignore'd file
#   such as CONTRIBUTING.md looks fine here and dangles in the tarball. This
#   reads .Rbuildignore and fails such a link too.
#
# Offline and quick. Unexported `tools` functions fail loudly if they go, as
# in verify_urls().
verify_incoming <- function(dir = ".") {
  ns <- asNamespace("tools")
  fns <- c("url_db_from_package_sources", "parse_URI_reference")
  gone <- fns[!vapply(fns, exists, NA, envir = ns, inherits = FALSE)]
  if (length(gone)) {
    stop(
      sprintf(
        "%s no longer exist(s) in R %s, so the `incoming` stage cannot run.",
        toString(sprintf("tools:::%s()", gone)),
        getRversion()
      ),
      call. = FALSE
    )
  }
  problems <- c(
    verify_incoming_spelling(dir),
    verify_incoming_file_uris(dir, ns)
  )
  if (length(problems)) {
    cat(sprintf("  %s\n", problems), sep = "")
    stop(
      sprintf("%d CRAN incoming problem(s)", length(problems)),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

verify_incoming_spelling <- function(dir) {
  fields <- read.dcf(
    file.path(dir, "DESCRIPTION"),
    fields = c("Title", "Description")
  )
  text <- paste0(" ", gsub("[[:space:]]+", " ", fields), " ")
  # The ignore patterns of .aspell_package_description_for_CRAN().
  ignore <- c(
    "(?<=[ \t[:punct:]])'[^']*'(?=[ \t[:punct:]])",
    paste0(
      "(?<=[ \t[:punct:]])([[:alnum:]]+::)?[[:alnum:]_.]*\\(\\)",
      "(?=[ \t[:punct:]])"
    ),
    "(?<=[<])(https?://|DOI:|doi:|arXiv:)[^>]+(?=[>])"
  )
  for (pattern in ignore) {
    text <- gsub(pattern, " ", text, perl = TRUE)
  }
  bad <- spelling::spell_check_text(text, ignore = character(), lang = "en_US")
  if (!nrow(bad)) {
    return(character())
  }
  sprintf(
    paste(
      "DESCRIPTION: possibly misspelled for CRAN's aspell: %s (reword, or",
      "quote a name as 'name'; inst/WORDLIST does not apply)"
    ),
    bad$word
  )
}

verify_incoming_file_uris <- function(dir, ns) {
  db <- get("url_db_from_package_sources", envir = ns)(dir)
  parts <- get("parse_URI_reference", envir = ns)(db$URL)
  path <- parts[, "path"]
  # Absolute paths (R's /doc/html, /library ...) and `../` links out of man/
  # or inst/doc are R's own help-system cases; anchors have no path.
  local <- parts[, "scheme"] %in%
    c("", "file") &
    nzchar(path) &
    !startsWith(path, "/") &
    !startsWith(path, "../")
  if (!any(local)) {
    return(character())
  }
  ignore <- readLines(file.path(dir, ".Rbuildignore"), warn = FALSE)
  ignore <- ignore[nzchar(trimws(ignore)) & !startsWith(ignore, "#")]
  ignored <- function(rel) {
    # A file is dropped when it or any directory above it matches, as in
    # `R CMD build`, which matches case-insensitively with perl regexes.
    steps <- strsplit(rel, "/", fixed = TRUE)[[1L]]
    prefixes <- vapply(
      seq_along(steps),
      function(i) paste(steps[seq_len(i)], collapse = "/"),
      ""
    )
    any(vapply(
      ignore,
      function(p) any(grepl(p, prefixes, perl = TRUE, ignore.case = TRUE)),
      NA
    ))
  }
  out <- character()
  for (i in which(local)) {
    parent <- dirname(db$Parent[[i]])
    rel <- sub("/+$", "", path[[i]])
    rel <- if (parent %in% c(".", "")) rel else file.path(parent, rel)
    rel <- sub("^\\./", "", rel)
    if (!file.exists(file.path(dir, rel)) || ignored(rel)) {
      out <- c(
        out,
        sprintf(
          paste(
            "%s: link to %s, which the built package does not contain",
            "(link by repository URL instead)"
          ),
          db$Parent[[i]],
          db$URL[[i]]
        )
      )
    }
  }
  out
}


if (!interactive()) {
  verify_incoming()
  cat("incoming: PASS\n")
}
