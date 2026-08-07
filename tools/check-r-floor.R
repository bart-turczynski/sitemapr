#!/usr/bin/env Rscript

# Declared-R-floor guard (run by the verify gate).
#
# DESCRIPTION's `Depends: R (>= x.y)` is a promise: the package installs and
# runs on that version of R. A hard dependency that declares a HIGHER floor
# breaks the promise — the declared floor becomes uninstallable, not merely
# untested — and nothing else in the chain notices. `R CMD check --as-cran`
# does not cross-check the two, so SITE-dtohylpx (`R (>= 4.0.0)` declared
# against httr2's `R (>= 4.1)`) shipped and was caught by reading, not by a
# gate. This stage closes that class (SITE-bugdqgwj).
#
# SCOPE: the whole hard-dependency closure, not only the direct dependencies.
# Depends/Imports/LinkingTo are followed transitively because a floor two hops
# down is exactly as uninstallable as one hop down — pslr, reached only through
# rurl, declares a floor of its own. Suggests is excluded at every level: it is
# optional by definition, so it cannot make the declared floor uninstallable.
#
# KNOWN LIMITATION, stated rather than hidden: this reads the INSTALLED
# dependency DESCRIPTIONs, so it checks the versions present on THIS machine,
# not the minimum versions DESCRIPTION permits. A dependency whose oldest
# permitted version declares a higher floor than the installed one slips
# through. Reading declared minimums would mean resolving them from a
# repository — a network dependency, and every stage in this chain but `readme`
# is deliberately offline. The installed-version reading still catches the
# class that bit here.
#
# Run from the package root (as the verify gate does).

manifest_path <- "DESCRIPTION"
if (!file.exists(manifest_path)) {
  stop(
    sprintf("%s not found (run from the package root).", manifest_path),
    call. = FALSE
  )
}

# One installed package's DESCRIPTION as a named character vector, or NULL when
# the package is not installed.
installed_desc <- function(pkg) {
  path <- system.file("DESCRIPTION", package = pkg)
  if (!nzchar(path)) {
    return(NULL)
  }
  read.dcf(path)[1, ]
}

# Package names in the hard-dependency fields, version constraints stripped.
# "R" is dropped: it is the thing being checked, not a package to follow.
hard_deps <- function(desc) {
  fields <- intersect(c("Depends", "Imports", "LinkingTo"), names(desc))
  named <- unlist(lapply(fields, function(field) {
    value <- desc[[field]]
    if (is.na(value)) {
      return(character(0))
    }
    trimws(sub("[(].*", "", strsplit(value, ",", fixed = TRUE)[[1]]))
  }))
  setdiff(named[nzchar(named)], "R")
}

# The `R (>= x.y)` floor a DESCRIPTION declares, or NA when it declares none.
# Base packages and most leaf packages declare none, which is not a problem —
# it simply contributes nothing to the maximum.
declared_floor <- function(desc) {
  has_depends <- !is.null(desc) &&
    "Depends" %in% names(desc) &&
    !is.na(desc[["Depends"]])
  if (!has_depends) {
    return(NA_character_)
  }
  spec <- desc[["Depends"]]
  found <- regmatches(spec, regexpr("R *[(] *>= *[0-9.]+ *[)]", spec))
  if (!length(found)) {
    return(NA_character_)
  }
  gsub("[^0-9.]", "", found)
}

# Breadth-first walk of the hard-dependency closure. An uninstalled package is
# fatal rather than skipped: skipping it silently would let the very dependency
# that raises the floor drop out of the maximum, which is the failure mode this
# stage exists to prevent.
hard_closure <- function(roots) {
  seen <- character(0)
  queue <- roots
  while (length(queue)) {
    pkg <- queue[[1]]
    queue <- queue[-1L]
    if (pkg %in% seen) {
      next
    }
    seen <- c(seen, pkg)
    desc <- installed_desc(pkg)
    if (is.null(desc)) {
      stop(
        sprintf(
          "hard dependency '%s' is not installed; cannot read its R floor.",
          pkg
        ),
        call. = FALSE
      )
    }
    queue <- c(queue, hard_deps(desc))
  }
  sort(seen)
}

manifest <- read.dcf(manifest_path)[1, ]
declared <- declared_floor(manifest)
if (is.na(declared)) {
  stop(
    "DESCRIPTION declares no 'Depends: R (>= x.y)' floor to check.",
    call. = FALSE
  )
}

floor_of <- function(pkg) declared_floor(installed_desc(pkg))
deps <- hard_closure(hard_deps(manifest))
floors <- vapply(deps, floor_of, character(1))
floors <- floors[!is.na(floors)]

# Seeded with 0.0.0 so the maximum is defined even if nothing declares a floor.
required <- max(package_version(c("0.0.0", floors)))
raisers <- names(floors)[package_version(floors) == required]

if (package_version(declared) < required) {
  stop(
    sprintf(
      paste0(
        "DESCRIPTION declares 'R (>= %s)' but the hard-dependency closure ",
        "requires R (>= %s), forced by: %s.\n",
        "  The declared floor is uninstallable, not merely untested. Raise ",
        "Depends to R (>= %s)."
      ),
      declared,
      as.character(required),
      toString(raisers),
      as.character(required)
    ),
    call. = FALSE
  )
}

cat(sprintf(
  "R floor OK (declared %s; %d hard deps, max floor %s from %s)\n",
  declared,
  length(deps),
  as.character(required),
  toString(raisers)
))
