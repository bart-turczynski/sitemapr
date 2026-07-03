# Unit tests for runtime mixed-namespace profile generation
# (R/schema-profile.R).

core_ns <- "http://www.sitemaps.org/schemas/sitemap/0.9"
image_ns <- "http://www.google.com/schemas/sitemap-image/1.1"
news_ns <- "http://www.google.com/schemas/sitemap-news/0.9"
video_ns <- "http://www.google.com/schemas/sitemap-video/1.1"

test_that("the wrapper XSD imports every supplied namespace by abs path", {
  imports <- c(a = "/abs/sitemap.xsd", b = "/abs/sitemap-image.xsd")
  names(imports) <- c(core_ns, image_ns)
  xsd <- schema_wrapper_xsd(imports)
  doc <- xml2::read_xml(xsd)
  imports_nodes <- xml2::xml_find_all(doc, "//*[local-name()='import']")
  expect_length(imports_nodes, 2L)
  expect_setequal(
    xml2::xml_attr(imports_nodes, "namespace"),
    c(core_ns, image_ns)
  )
  locs <- xml2::xml_attr(imports_nodes, "schemaLocation")
  expect_true(all(startsWith(locs, "/abs/")))
})

test_that("the generated wrapper is itself well-formed XML", {
  imports <- c("/abs/sitemap.xsd", "/abs/sitemap-news.xsd")
  names(imports) <- c(core_ns, news_ns)
  expect_no_error(xml2::read_xml(schema_wrapper_xsd(imports)))
})

test_that("a mixed-namespace doc resolves to a generated runtime wrapper", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  cache <- new.env(parent = emptyenv())
  dir <- withr::local_tempdir()
  res <- schema_profile(
    "urlset",
    c(core_ns, image_ns),
    cache = cache,
    dir = dir
  )
  expect_identical(res$kind, "runtime")
  expect_true(file.exists(res$schema_path))
  # Written into the supplied (temp) dir, never the installed schema tree.
  expect_identical(
    normalizePath(dirname(res$schema_path)),
    normalizePath(dir)
  )
})

test_that("the wrapper references bundled schemas by absolute path", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  res <- schema_profile(
    "urlset",
    c(core_ns, image_ns),
    cache = new.env(parent = emptyenv()),
    dir = withr::local_tempdir()
  )
  doc <- xml2::read_xml(res$schema_path)
  locs <- xml2::xml_attr(
    xml2::xml_find_all(doc, "//*[local-name()='import']"),
    "schemaLocation"
  )
  expect_true(all(startsWith(locs, schema_dir())))
  # system.file gives an absolute path, so the locations are absolute.
  expect_true(all(startsWith(locs, "/")))
})

test_that("repeated resolution of the same combo reuses one cached wrapper", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  cache <- new.env(parent = emptyenv())
  dir <- withr::local_tempdir()
  a <- schema_profile("urlset", c(core_ns, image_ns), cache = cache, dir = dir)
  b <- schema_profile("urlset", c(image_ns, core_ns), cache = cache, dir = dir)
  expect_identical(a$schema_path, b$schema_path)
  expect_length(list.files(dir), 1L)
})

test_that("a regenerated wrapper is produced if the cached file vanished", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  cache <- new.env(parent = emptyenv())
  dir <- withr::local_tempdir()
  a <- schema_profile("urlset", c(core_ns, news_ns), cache = cache, dir = dir)
  unlink(a$schema_path)
  b <- schema_profile("urlset", c(core_ns, news_ns), cache = cache, dir = dir)
  expect_true(file.exists(b$schema_path))
})

test_that("core-only documents need no generated wrapper", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  dir <- withr::local_tempdir()
  res <- schema_profile(
    "urlset",
    core_ns,
    cache = new.env(parent = emptyenv()),
    dir = dir
  )
  expect_identical(res$kind, "bundled")
  expect_identical(basename(res$schema_path), "sitemap.xsd")
  expect_length(list.files(dir), 0L)
})

test_that("an unknown namespace produces no wrapper, just the signal", {
  dir <- withr::local_tempdir()
  res <- schema_profile(
    "urlset",
    c(core_ns, "https://example.com/ns/x"),
    schemas_dir = "/x",
    cache = new.env(parent = emptyenv()),
    dir = dir
  )
  expect_identical(res$kind, "unknown-namespace")
  expect_identical(res$unknown_namespaces, "https://example.com/ns/x")
  expect_length(list.files(dir), 0L)
})

test_that("a generated runtime wrapper actually validates a mixed document", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  res <- schema_profile(
    "urlset",
    c(core_ns, image_ns),
    cache = new.env(parent = emptyenv()),
    dir = withr::local_tempdir()
  )
  schema <- xml2::read_xml(res$schema_path)
  ok <- xml2::read_xml(paste0(
    "<urlset xmlns=\"",
    core_ns,
    "\" xmlns:image=\"",
    image_ns,
    "\">",
    "<url><loc>https://example.com/a</loc>",
    "<image:image><image:loc>https://example.com/i.jpg</image:loc>",
    "</image:image></url></urlset>"
  ))
  bad <- xml2::read_xml(paste0(
    "<urlset xmlns=\"",
    core_ns,
    "\" xmlns:image=\"",
    image_ns,
    "\">",
    "<url><loc>https://example.com/a</loc>",
    "<image:image><image:bogus>x</image:bogus></image:image></url></urlset>"
  ))
  expect_true(as.logical(xml2::xml_validate(ok, schema)))
  expect_false(as.logical(xml2::xml_validate(bad, schema)))
})

test_that("an arbitrary multi-extension wrapper validates a real document", {
  skip_if(identical(schema_dir(), ""), "package not installed")
  res <- schema_profile(
    "urlset",
    c(core_ns, image_ns, video_ns, news_ns),
    cache = new.env(parent = emptyenv()),
    dir = withr::local_tempdir()
  )
  expect_identical(res$kind, "runtime")
  schema <- xml2::read_xml(res$schema_path)
  # A urlset mixing core + image + news markup validates against one wrapper.
  ok <- xml2::read_xml(paste0(
    "<urlset xmlns=\"", core_ns, "\"",
    " xmlns:image=\"", image_ns, "\"",
    " xmlns:news=\"", news_ns, "\">",
    "<url><loc>https://example.com/a</loc>",
    "<image:image><image:loc>https://example.com/i.jpg</image:loc>",
    "</image:image>",
    "<news:news><news:publication>",
    "<news:name>Example</news:name><news:language>en</news:language>",
    "</news:publication>",
    "<news:publication_date>2026-07-04</news:publication_date>",
    "<news:title>Headline</news:title></news:news>",
    "</url></urlset>"
  ))
  expect_true(as.logical(xml2::xml_validate(ok, schema)))
})
