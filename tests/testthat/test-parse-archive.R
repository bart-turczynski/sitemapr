# Unit tests for bounded, safe local .tar.gz extraction (R/parse-archive.R).
# Pure/offline: every archive is built in-memory by a minimal ustar writer and
# gzipped to a tempfile, so we control exact member names (including unsafe
# ones the real `tar()` would normalise away). No network.

# ---- minimal ustar tar writer ------------------------------------------------
# We deliberately reimplement the writer rather than use utils::tar() so the
# fixtures can carry path-traversal/absolute names byte-for-byte. The reader
# (R/parse-archive.R) does not verify the header checksum, so the checksum field
# is left as the conventional spaces.

tar_header <- function(name, size, typeflag = "0") {
  h <- raw(512L)
  put <- function(h, off, s) {
    b <- charToRaw(s)
    h[(off + 1L):(off + length(b))] <- b
    h
  }
  h <- put(h, 0L, name)
  h <- put(h, 124L, sprintf("%011o", size)) # size (NUL terminator from zeros)
  h <- put(h, 148L, "        ") # checksum field: 8 spaces (unverified)
  h <- put(h, 156L, typeflag)
  h <- put(h, 257L, "ustar") # magic (offset 257); version "00" follows
  h <- put(h, 263L, "00")
  h
}

pad_block <- function(x) {
  r <- length(x) %% 512L
  if (r == 0L) x else c(x, raw(512L - r))
}

# entries: list of list(name=, content=<chr|raw|NULL>, typeflag="0")
write_tar_gz <- function(entries, path) {
  blocks <- raw(0L)
  for (e in entries) {
    tf <- if (is.null(e$typeflag)) "0" else e$typeflag
    content <- e$content
    if (is.null(content)) content <- raw(0L)
    if (is.character(content)) content <- charToRaw(content)
    blocks <- c(
      blocks, tar_header(e$name, length(content), tf), pad_block(content)
    )
  }
  blocks <- c(blocks, raw(1024L)) # two zero blocks: end-of-archive marker
  con <- gzfile(path, "wb")
  writeBin(blocks, con)
  close(con)
  invisible(path)
}

urlset_xml <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls, "</urlset>"
  )
}

gz_bytes <- function(text) {
  tf <- withr::local_tempfile(fileext = ".gz")
  con <- gzfile(tf, "wb")
  writeBin(charToRaw(text), con)
  close(con)
  readBin(tf, what = "raw", n = file.info(tf)$size)
}

# ---- happy path --------------------------------------------------------------

test_that("two sitemap members both contribute rows, distinguished by source", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "a.xml", content = urlset_xml("https://a/1", "https://a/2")),
    list(name = "b.xml", content = urlset_xml("https://b/1"))
  ), path)

  res <- parse_sitemap_archive(path, source_ref = "arc")
  expect_setequal(
    res$rows$loc, c("https://a/1", "https://a/2", "https://b/1")
  )
  expect_setequal(
    unique(res$rows$source_sitemap),
    c("arc#archive-member:a.xml", "arc#archive-member:b.xml")
  )
  expect_identical(nrow(res$problems), 0L)
})

test_that("a text sitemap member parses to rows", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "urls.txt", content = "https://a/\nhttps://b/\n")
  ), path)
  res <- parse_sitemap_archive(path)
  expect_identical(res$rows$loc, c("https://a/", "https://b/"))
})

test_that("an inner .gz member is decompressed and parsed", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "inner.xml.gz", content = gz_bytes(urlset_xml("https://g/1")))
  ), path)
  res <- parse_sitemap_archive(path)
  expect_identical(res$rows$loc, "https://g/1")
})

# ---- skipping & rejection ----------------------------------------------------

test_that("a non-sitemap file is skipped with an info problem", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "sitemap.xml", content = urlset_xml("https://a/1")),
    list(name = "README.md", content = "# hello\nsome prose\n")
  ), path)
  res <- parse_sitemap_archive(path, source_ref = "arc")
  expect_identical(res$rows$loc, "https://a/1")
  expect_identical(nrow(res$problems), 1L)
  expect_identical(res$problems$severity, "info")
  expect_match(res$problems$subject_ref, "README.md", fixed = TRUE)
})

test_that("a path-traversal member is rejected with a warning problem", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "ok.xml", content = urlset_xml("https://a/1")),
    list(name = "../evil.xml", content = urlset_xml("https://evil/"))
  ), path)
  res <- parse_sitemap_archive(path)
  expect_identical(res$rows$loc, "https://a/1") # evil URL never parsed
  expect_identical(res$problems$severity, "warning")
  expect_match(res$problems$message, "traversal")
})

test_that("absolute and drive-letter member names are unsafe", {
  expect_true(tar_is_unsafe_name("/etc/passwd"))
  expect_true(tar_is_unsafe_name("C:/win.xml"))
  expect_true(tar_is_unsafe_name("a/../b"))
  expect_true(tar_is_unsafe_name(""))
  expect_false(tar_is_unsafe_name("dir/sub/sitemap.xml"))
})

test_that("directory and special entries are skipped silently", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "d/", content = NULL, typeflag = "5"),
    list(name = "link", content = NULL, typeflag = "2"), # symlink
    list(name = "d/s.xml", content = urlset_xml("https://a/1"))
  ), path)
  res <- parse_sitemap_archive(path)
  expect_identical(res$rows$loc, "https://a/1")
  expect_identical(nrow(res$problems), 0L) # dirs/special: no problem rows
})

# ---- limits ------------------------------------------------------------------

test_that("exceeding the file-count limit raises sitemapr_archive_limit", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "a.xml", content = urlset_xml("https://a/1")),
    list(name = "b.xml", content = urlset_xml("https://b/1")),
    list(name = "c.xml", content = urlset_xml("https://c/1"))
  ), path)
  expect_error(
    parse_sitemap_archive(path, limits = archive_limits(max_file_count = 2L)),
    class = "sitemapr_archive_limit"
  )
})

test_that("exceeding the on-disk size limit raises sitemapr_archive_limit", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "a.xml", content = urlset_xml("https://a/1"))
  ), path)
  expect_error(
    parse_sitemap_archive(path, limits = archive_limits(max_archive_bytes = 1)),
    class = "sitemapr_archive_limit"
  )
})

test_that("exceeding the decompressed limit raises sitemapr_archive_limit", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(
    list(name = "a.xml", content = urlset_xml("https://a/1"))
  ), path)
  expect_error(
    parse_sitemap_archive(
      path,
      limits = archive_limits(max_decompressed_bytes = 1)
    ),
    class = "sitemapr_archive_limit"
  )
})

# ---- empty & malformed -------------------------------------------------------

test_that("an archive with no regular files raises sitemapr_empty_archive", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  write_tar_gz(list(list(name = "d/", content = NULL, typeflag = "5")), path)
  expect_error(
    parse_sitemap_archive(path),
    class = "sitemapr_empty_archive"
  )
})

test_that("a corrupt outer gzip raises sitemapr_decompression_error", {
  path <- withr::local_tempfile(fileext = ".tar.gz")
  writeBin(as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x11, 0x22)), path)
  expect_error(
    parse_sitemap_archive(path),
    class = "sitemapr_decompression_error"
  )
})

test_that("a truncated tar body raises sitemapr_malformed_archive", {
  # A header claiming a 5000-byte body, but no body bytes follow.
  bad_tar <- c(tar_header("big.xml", 5000L), raw(512L))
  path <- withr::local_tempfile(fileext = ".tar.gz")
  con <- gzfile(path, "wb")
  writeBin(bad_tar, con)
  close(con)
  expect_error(
    parse_sitemap_archive(path),
    class = "sitemapr_malformed_archive"
  )
})

test_that("a missing archive file raises sitemapr_archive_not_found", {
  expect_error(
    parse_sitemap_archive(tempfile(fileext = ".tar.gz")),
    class = "sitemapr_archive_not_found"
  )
})
