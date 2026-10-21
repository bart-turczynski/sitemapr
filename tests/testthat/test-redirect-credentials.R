# Offline tests for credential handling across redirect hops (SITE-vquagswr).
#
# sitemapr follows redirects by hand, one fresh request per hop. A hop whose
# origin (scheme, host, port) differs from the first request's must carry no
# `auth` and none of the credential-bearing headers; a same-origin hop keeps
# them. All three hop loops are covered: fetch_follow(), page_fetch_follow()
# and the bounded-concurrency batch path.

cred_policy <- function() {
  request_policy(
    auth = request_auth_bearer("s3cret-token"),
    headers = list(
      "X-Env" = "staging",
      "Cookie" = "session=abc",
      "proxy-authorization" = "Basic cHJveHk6cHc="
    )
  )
}

cred_redirect <- function(url, location, status = 301L) {
  httr2::response(
    status_code = status,
    url = url,
    headers = list(Location = location)
  )
}

cred_ok <- function(url, content_type = "application/xml") {
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list("Content-Type" = content_type),
    body = charToRaw("<?xml version=\"1.0\"?><urlset/>")
  )
}

# Names of the credential-bearing headers on a built request, lower-cased.
cred_header_names <- function(req) {
  nms <- tolower(names(req$headers))
  intersect(nms, c("authorization", "proxy-authorization", "cookie"))
}

# Route a mocked chain by URL and record every built request in hop order.
cred_mock_chain <- function(routes, env = parent.frame()) {
  seen <- new.env(parent = emptyenv())
  seen$reqs <- list()
  httr2::local_mocked_responses(
    function(req) {
      seen$reqs[[length(seen$reqs) + 1L]] <- req
      routes[[req$url]]
    },
    env = env
  )
  seen
}

# ---- fetch_follow() ----------------------------------------------------------

test_that("a cross-origin redirect hop carries no credentials", {
  seen <- cred_mock_chain(list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = cred_ok("https://other.example/b.xml")
  ))
  fetch_source("https://example.com/a.xml", policy = cred_policy())

  expect_length(seen$reqs, 2L)
  expect_setequal(
    cred_header_names(seen$reqs[[1]]),
    c("authorization", "proxy-authorization", "cookie")
  )
  expect_identical(cred_header_names(seen$reqs[[2]]), character(0))
  # A non-credential header still travels.
  expect_identical(seen$reqs[[2]]$headers[["X-Env"]], "staging")
})

test_that("basic auth is dropped on a cross-origin hop too", {
  seen <- cred_mock_chain(list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = cred_ok("https://other.example/b.xml")
  ))
  policy <- request_policy(auth = request_auth_basic("user", "secret"))
  fetch_source("https://example.com/a.xml", policy = policy)

  expect_identical(cred_header_names(seen$reqs[[1]]), "authorization")
  expect_identical(cred_header_names(seen$reqs[[2]]), character(0))
  expect_null(seen$reqs[[2]]$options$userpwd)
})

test_that("a same-origin redirect hop keeps the credentials", {
  seen <- cred_mock_chain(list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://EXAMPLE.com:443/b.xml"
    ),
    "https://EXAMPLE.com:443/b.xml" = cred_ok("https://EXAMPLE.com:443/b.xml")
  ))
  fetch_source("https://example.com/a.xml", policy = cred_policy())

  expect_setequal(
    cred_header_names(seen$reqs[[2]]),
    c("authorization", "proxy-authorization", "cookie")
  )
})

test_that("a same-host scheme or port change counts as cross-origin", {
  for (target in c("http://example.com/b.xml", "https://example.com:8443/b")) {
    seen <- cred_mock_chain(stats::setNames(
      list(
        cred_redirect("https://example.com/a.xml", target),
        cred_ok(target)
      ),
      c("https://example.com/a.xml", target)
    ))
    fetch_source(
      "https://example.com/a.xml",
      policy = cred_policy(),
      scheme_inferred = FALSE
    )
    expect_identical(cred_header_names(seen$reqs[[2]]), character(0))
  }
})

test_that("a chain that returns to the first origin carries them again", {
  seen <- cred_mock_chain(list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = cred_redirect(
      "https://other.example/b.xml",
      "https://example.com/c.xml"
    ),
    "https://example.com/c.xml" = cred_ok("https://example.com/c.xml")
  ))
  fetch_source("https://example.com/a.xml", policy = cred_policy())

  expect_identical(cred_header_names(seen$reqs[[2]]), character(0))
  expect_length(cred_header_names(seen$reqs[[3]]), 3L)
})

test_that("the prepare hook learns whether its hop is cross-origin", {
  state <- new.env(parent = emptyenv())
  state$flags <- logical(0)
  cred_mock_chain(list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = cred_ok("https://other.example/b.xml")
  ))
  policy <- request_policy(prepare = function(req, ctx) {
    state$flags <- c(state$flags, ctx$cross_origin)
    req
  })
  fetch_source("https://example.com/a.xml", policy = policy)
  expect_identical(state$flags, c(FALSE, TRUE))
})

# ---- page_fetch_follow() -----------------------------------------------------

test_that("page inspection drops credentials on a cross-origin hop", {
  seen <- cred_mock_chain(list(
    "https://example.com/p" = cred_redirect(
      "https://example.com/p",
      "https://other.example/q"
    ),
    "https://other.example/q" = cred_ok("https://other.example/q", "text/html")
  ))
  art <- page_fetch("https://example.com/p", policy = cred_policy())

  expect_identical(art$outcome, "usable_body")
  expect_length(cred_header_names(seen$reqs[[1]]), 3L)
  expect_identical(cred_header_names(seen$reqs[[2]]), character(0))
})

# ---- fetch_batch_follow() ----------------------------------------------------

# Run one batch over `urls` with the pool mocked; return every request the
# pool received, in dispatch order.
cred_batch_reqs <- function(urls, routes, policy) {
  seen <- new.env(parent = emptyenv())
  seen$reqs <- list()
  testthat::local_mocked_bindings(
    req_perform_parallel = function(reqs, ..., max_active = 10) {
      seen$reqs <- c(seen$reqs, reqs)
      lapply(reqs, function(req) routes[[req$url]])
    },
    .package = "httr2"
  )
  fetch_batch_follow(
    urls = urls,
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    policy = policy,
    max_active = 2L
  )
  seen$reqs
}

test_that("the batch path drops credentials on a cross-origin hop only", {
  routes <- list(
    "https://example.com/c1.xml" = cred_redirect(
      "https://example.com/c1.xml",
      "https://other.example/c1.xml"
    ),
    "https://example.com/c2.xml" = cred_redirect(
      "https://example.com/c2.xml",
      "https://example.com/c2b.xml"
    ),
    "https://other.example/c1.xml" = cred_ok("https://other.example/c1.xml"),
    "https://example.com/c2b.xml" = cred_ok("https://example.com/c2b.xml")
  )
  reqs <- cred_batch_reqs(
    c("https://example.com/c1.xml", "https://example.com/c2.xml"),
    routes,
    cred_policy()
  )
  by_url <- stats::setNames(reqs, vapply(reqs, `[[`, "", "url"))

  expect_length(cred_header_names(by_url[["https://example.com/c1.xml"]]), 3L)
  expect_identical(
    cred_header_names(by_url[["https://other.example/c1.xml"]]),
    character(0)
  )
  expect_length(cred_header_names(by_url[["https://example.com/c2b.xml"]]), 3L)
})

test_that("batch and sequential paths build identical cross-origin hops", {
  policy <- cred_policy()
  seq_req <- fetch_build_request(
    "https://other.example/b.xml",
    fetch_limits(),
    default_user_agent(),
    policy,
    origin_url = "https://example.com/a.xml"
  )
  routes <- list(
    "https://example.com/a.xml" = cred_redirect(
      "https://example.com/a.xml",
      "https://other.example/b.xml"
    ),
    "https://other.example/b.xml" = cred_ok("https://other.example/b.xml")
  )
  reqs <- cred_batch_reqs("https://example.com/a.xml", routes, policy)
  expect_identical(reqs[[2]]$headers, seq_req$headers)
  expect_identical(reqs[[2]]$options, seq_req$options)
})
