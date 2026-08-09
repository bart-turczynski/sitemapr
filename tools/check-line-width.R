#!/usr/bin/env Rscript

# Line-width agreement guard (run by the verify gate).
#
# Two files pin the same number for different tools: `air.toml`'s
# `line-width` (what the pre-commit formatter WRITES) and `.lintr`'s
# `line_length_linter()` (what the verify gate REJECTS). Each file's comments
# say it mirrors the other, but comments are not enforcement — raising one and
# not the other puts the formatter and the gate in direct conflict, where every
# commit reformats a line the next lint stage then fails on. Nothing else in
# the chain compares them: lintr never reads air.toml, and air never reads
# .lintr. This stage closes that (SITE-yvspdyen).
#
# Both reads are deliberately textual rather than parsed. air.toml would
# otherwise need a TOML parser (a new dependency for one integer), and `.lintr`
# is a YAML file whose `linters:` value is unevaluated R source, so there is no
# structured read short of parsing the expression. A missing pin on either side
# is fatal rather than skipped: falling back to a tool default is exactly the
# silent divergence this exists to catch.
#
# Run from the package root (as the verify gate does).

# `line-width` from air.toml's [format] table. Section-aware, so a same-named
# key added under some future table cannot be mistaken for the format pin.
air_line_width <- function(path = "air.toml") {
  if (!file.exists(path)) {
    stop(
      sprintf("%s not found (run from the package root).", path),
      call. = FALSE
    )
  }
  lines <- trimws(readLines(path, warn = FALSE))
  section <- ""
  for (line in lines) {
    if (grepl("^\\[", line)) {
      section <- gsub("^\\[|\\]$", "", line)
      next
    }
    if (!identical(section, "format")) {
      next
    }
    found <- regmatches(
      line,
      regexec("^line-width *= *([0-9]+)", line)
    )[[1]]
    if (length(found)) {
      return(as.integer(found[[2]]))
    }
  }
  stop(
    sprintf("%s declares no [format] line-width.", path),
    call. = FALSE
  )
}

# The width argument of .lintr's line_length_linter(). Reads the whole file as
# one string: the linters: block spans lines, and the call could wrap.
lintr_line_length <- function(path = ".lintr") {
  if (!file.exists(path)) {
    stop(
      sprintf("%s not found (run from the package root).", path),
      call. = FALSE
    )
  }
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  found <- regmatches(
    text,
    regexec("line_length_linter\\( *([0-9]+) *\\)", text)
  )[[1]]
  if (!length(found)) {
    stop(
      sprintf(
        paste0(
          "%s configures no line_length_linter(<width>); the gate would ",
          "fall back to lintr's default and stop matching air.toml."
        ),
        path
      ),
      call. = FALSE
    )
  }
  as.integer(found[[2]])
}

air_width <- air_line_width()
lint_width <- lintr_line_length()

if (!identical(air_width, lint_width)) {
  stop(
    sprintf(
      paste0(
        "line-width disagreement: air.toml formats at %d but .lintr rejects ",
        "past %d.\n",
        "  air rewrites code on commit and lintr fails it on push, so this ",
        "makes the two gates unsatisfiable together. Set both to the same ",
        "number."
      ),
      air_width,
      lint_width
    ),
    call. = FALSE
  )
}

cat(sprintf("line width OK (air.toml and .lintr both %d)\n", air_width))
