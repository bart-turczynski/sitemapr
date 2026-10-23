# Offline tests for credential handling across the fetch chains one call starts
# (SITE-ylpbrfyo).
#
# An index child or a robots.txt `Sitemap:` line starts a new fetch chain, with
# no redirect involved. Credentials stay on the origin of the URL the caller
# passed: a chain on another origin carries no `auth` and none of the
# credential-bearing headers, on the sequential and the batch paths alike.

chain_policy <- function() {
  request_policy(
    auth = request_auth_bearer("s3cret-token"),
    headers = list("X-Env" = "staging", "Cookie" = "session=abc")
  )
}

chain_xml <- function(url, body) {
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list("Content-Type" = "application/xml"),
    body = charToRaw(body)
  )
}

chain_index <- function(url, locs) {
  entries <- paste0("<sitemap><loc>", locs, "</loc></sitemap>", collapse = "")
  chain_xml(
    url,
    paste0(
      "<?xml version=\"1.0\"?>",
      "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
      entries,
      "</sitemapindex>"
    )
  )
}

chain_urlset <- function(url) {
  chain_xml(
    url,
    paste0(
      "<?xml version=\"1.0\"?>",
      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
      "<url><loc>https://example.com/page</loc></url>",
      "</urlset>"
    )
  )
}

chain_redirect <- function(url, location) {
  httr2::response(
    status_code = 301L,
    url = url,
    headers = list(Location = location)
  )
}

# Names of the credential-bearing headers on a built request, lower-cased.
chain_cred_names <- function(req) {
  nms <- ascii_lower(names(req$headers))
  intersect(nms, c("authorization", "proxy-authorization", "cookie"))
}

# Route mocked requests by URL (404 for anything unrouted) and record every
# built request by URL.
chain_mock <- function(routes, env = parent.frame()) {
  seen <- new.env(parent = emptyenv())
  seen$reqs <- list()
  httr2::local_mocked_responses(
    function(req) {
      seen$reqs[[req$url]] <- req
      resp <- routes[[req$url]]
      if (is.null(resp)) {
        resp <- httr2::response(status_code = 404L, url = req$url)
      }
      resp
    },
    env = env
  )
  seen
}

chain_index_routes <- function() {
  list(
    "https://example.com/index.xml" = chain_index(
      "https://example.com/index.xml",
      c("https://example.com/a.xml", "https://other.example/b.xml")
    ),
    "https://example.com/a.xml" = chain_urlset("https://example.com/a.xml"),
    "https://other.example/b.xml" = chain_urlset("https://other.example/b.xml")
  )
}

# ---- index children ----------------------------------------------------------

test_that("an index child on another origin is fetched with no credentials", {
  seen <- chain_mock(chain_index_routes())
  read_sitemap("https://example.com/index.xml", policy = chain_policy())

  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/a.xml"]]),
    c("authorization", "cookie")
  )
  other <- seen$reqs[["https://other.example/b.xml"]]
  expect_identical(chain_cred_names(other), character(0))
  # A non-credential header still travels.
  expect_identical(other$headers[["X-Env"]], "staging")
})

test_that("the batch path drops credentials on a cross-origin child", {
  seen <- chain_mock(chain_index_routes())
  read_sitemap(
    "https://example.com/index.xml",
    policy = chain_policy(),
    max_active = 2L
  )

  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/a.xml"]]),
    c("authorization", "cookie")
  )
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

test_that("sequential and batch paths build identical cross-origin children", {
  seq_seen <- chain_mock(chain_index_routes())
  read_sitemap("https://example.com/index.xml", policy = chain_policy())
  seq_req <- seq_seen$reqs[["https://other.example/b.xml"]]

  batch_seen <- chain_mock(chain_index_routes())
  read_sitemap(
    "https://example.com/index.xml",
    policy = chain_policy(),
    max_active = 2L
  )
  batch_req <- batch_seen$reqs[["https://other.example/b.xml"]]

  expect_identical(batch_req$headers, seq_req$headers)
  expect_identical(batch_req$options, seq_req$options)
})

test_that("the entry URL's origin binds, not the index's after a redirect", {
  seen <- chain_mock(list(
    "https://example.com/index.xml" = chain_redirect(
      "https://example.com/index.xml",
      "https://other.example/index.xml"
    ),
    "https://other.example/index.xml" = chain_index(
      "https://other.example/index.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = chain_urlset("https://other.example/b.xml")
  ))
  read_sitemap("https://example.com/index.xml", policy = chain_policy())

  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

test_that("a cross-origin child is credential-free in audits and trees", {
  seen <- chain_mock(chain_index_routes())
  validate_sitemap("https://example.com/index.xml", policy = chain_policy())
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )

  seen <- chain_mock(chain_index_routes())
  sitemap_tree(
    "https://example.com/index.xml",
    from = "sitemap",
    policy = chain_policy()
  )
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

test_that("a cross-origin child is credential-free in audits and reports", {
  seen <- chain_mock(chain_index_routes())
  audit_sitemap("https://example.com/index.xml", policy = chain_policy())
  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/a.xml"]]),
    c("authorization", "cookie")
  )
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )

  seen <- chain_mock(chain_index_routes())
  report_sitemap("https://example.com/index.xml", policy = chain_policy())
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

test_that("index bytes pin the source_url's origin", {
  routes <- chain_index_routes()
  index_bytes <- routes[["https://example.com/index.xml"]]$body
  seen <- chain_mock(routes)
  sitemap_tree_from_bytes(
    index_bytes,
    source_url = "https://example.com/index.xml",
    policy = chain_policy()
  )

  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/a.xml"]]),
    c("authorization", "cookie")
  )
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

# ---- robots.txt Sitemap: lines -----------------------------------------------

chain_robots_routes <- function() {
  list(
    "https://example.com/robots.txt" = httr2::response(
      status_code = 200L,
      url = "https://example.com/robots.txt",
      headers = list("Content-Type" = "text/plain"),
      body = charToRaw(paste0(
        "User-agent: *\nAllow: /\n",
        "Sitemap: https://example.com/a.xml\n",
        "Sitemap: https://other.example/b.xml\n"
      ))
    ),
    "https://example.com/a.xml" = chain_urlset("https://example.com/a.xml"),
    "https://other.example/b.xml" = chain_urlset("https://other.example/b.xml")
  )
}

test_that("a robots.txt Sitemap: line on another origin gets no credentials", {
  seen <- chain_mock(chain_robots_routes())
  sitemap_tree(
    "https://example.com",
    use_known_paths = FALSE,
    policy = chain_policy()
  )

  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/robots.txt"]]),
    c("authorization", "cookie")
  )
  expect_setequal(
    chain_cred_names(seen$reqs[["https://example.com/a.xml"]]),
    c("authorization", "cookie")
  )
  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/b.xml"]]),
    character(0)
  )
})

test_that("a discovered cross-origin index keeps its children credential-free", {
  routes <- chain_robots_routes()
  routes[["https://other.example/b.xml"]] <- chain_index(
    "https://other.example/b.xml",
    "https://other.example/c.xml"
  )
  routes[["https://other.example/c.xml"]] <- chain_urlset(
    "https://other.example/c.xml"
  )
  seen <- chain_mock(routes)
  sitemap_tree(
    "https://example.com",
    use_known_paths = FALSE,
    policy = chain_policy()
  )

  expect_identical(
    chain_cred_names(seen$reqs[["https://other.example/c.xml"]]),
    character(0)
  )
})

# ---- the prepare hook --------------------------------------------------------

test_that("the prepare hook is told a cross-origin child is cross-origin", {
  seen_ctx <- new.env(parent = emptyenv())
  policy <- request_policy(prepare = function(req, ctx) {
    seen_ctx[[ctx$url]] <- ctx$cross_origin
    req
  })
  chain_mock(chain_index_routes())
  read_sitemap("https://example.com/index.xml", policy = policy)

  expect_false(seen_ctx[["https://example.com/a.xml"]])
  expect_true(seen_ctx[["https://other.example/b.xml"]])
})
