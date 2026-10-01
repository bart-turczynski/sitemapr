# Locale-independent ASCII case folding (SITE-rkstwdsr, fleet sweep
# SEOR-rxxuzhmc; modeled on pslr's R/ascii.R, pslr f322d57).
#
# Base R's tolower() and toupper() follow the session's LC_CTYPE. Under a
# Turkish or Azeri locale on glibc, "I" lowercases to the dotless "ı" and "i"
# uppercases to the dotted "İ", so a comparison on a protocol string fails
# silently: "TEXT/HTML" stops matching "text/html", "ICANN" stops matching
# "icann". Every string sitemapr folds (schemes, hosts, content types, header
# and attribute names, `rel` tokens, hreflang tags, encoding labels, file
# extensions) is ASCII by definition or compared against ASCII constants, so
# only A-Z and a-z are mapped and anything else passes through unchanged.
# .lintr bans tolower(), toupper() and casefold() so a new call site cannot
# reintroduce the locale dependence.
ascii_lower <- function(x) {
  chartr(paste(LETTERS, collapse = ""), paste(letters, collapse = ""), x)
}

ascii_upper <- function(x) {
  chartr(paste(letters, collapse = ""), paste(LETTERS, collapse = ""), x)
}
