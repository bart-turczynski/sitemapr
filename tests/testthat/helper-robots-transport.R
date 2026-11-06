# Keeps the httr2-mocked robots.txt tests offline on either robotstxtr.
#
# robotstxtr through 0.3.1 fetches robots.txt with httr2, so an active
# httr2::with_mocked_responses() reaches it directly. Later versions fetch
# through ssrfr and never touch httr2, so the same tests would reach for the
# real host. setup-robots-transport.R installs these two stand-ins for ssrfr's
# public hop functions; with an httr2 mock active they answer from that mock,
# and with none they call the real ssrfr.
#
# Each hop is still checked by ssrfr's own ssrf_inspect_url(), but no name is
# resolved. The header-count and several-Location limits are not modeled: no
# mock here reaches them. `ssrfr` is named through a variable because it is not
# in DESCRIPTION yet (it is not on CRAN).

robots_ssrfr_pkg <- "ssrfr"

robots_ssrfr_fn <- function(name) {
  getExportedValue(robots_ssrfr_pkg, name)
}

robots_ssrfr_outcome <- function(token, hop, detail, class) {
  structure(
    c(
      token,
      list(
        hop = as.integer(hop),
        host = NA_character_,
        address = NA_character_,
        url = NA_character_,
        detail = detail
      )
    ),
    class = c(class, "ssrfr_outcome")
  )
}

robots_ssrfr_refusal <- function(code, hop) {
  robots_ssrfr_outcome(list(code = code), hop, list(), "ssrfr_refusal")
}

robots_ssrfr_failure <- function(cause, hop, ...) {
  robots_ssrfr_outcome(list(cause = cause), hop, list(...), "ssrfr_failure")
}

robots_mock_prepare_hop <- function(url, policy, from = NULL) {
  base <- if (is.null(from)) NULL else from$url
  hop <- if (is.null(from)) 1L else from$hop + 1L
  inspection <- robots_ssrfr_fn("ssrf_inspect_url")(url, policy, base = base)
  if (!is.na(inspection$code)) {
    return(robots_ssrfr_refusal(inspection$code, hop))
  }
  target <- if (is.null(base)) {
    url
  } else {
    rurl::resolve_url(url, base, url_standard = "whatwg", output = "serialized")
  }
  state <- new.env(parent = emptyenv())
  state$status <- NULL
  state$location <- NULL
  state$location_count <- NULL
  structure(
    list(
      hop = hop,
      url = sub("#.*$", "", target),
      policy = policy,
      state = state
    ),
    class = "ssrfr_binding"
  )
}

robots_mock_fetch <- function(binding) {
  # The mock is called directly: httr2 reads a NULL answer as "not mocked" and
  # goes to the network, which these tests must never do.
  mock <- getOption("httr2_mock")
  resp <- tryCatch(
    mock(httr2::request(binding$url)),
    error = function(cnd) NULL
  )
  if (is.null(resp)) {
    return(robots_ssrfr_failure("connect-failed", binding$hop))
  }
  status <- httr2::resp_status(resp)
  body <- if (httr2::resp_has_body(resp)) httr2::resp_body_raw(resp) else raw()
  headers <- unlist(as.list(httr2::resp_headers(resp)))
  if (is.null(headers)) {
    headers <- character()
  }
  names(headers) <- ascii_lower(names(headers))

  binding$state$status <- status
  redirect <- status >= 300L && status <= 399L
  if (redirect && binding$hop - 1L >= binding$policy$max_redirects) {
    return(robots_ssrfr_refusal("redirect-limit", binding$hop))
  }
  limit <- binding$policy$max_response_size
  truncating <- isTRUE(binding$policy$truncate_body)
  observed <- as.numeric(length(body))
  truncated <- FALSE
  if (observed > limit) {
    if (!truncating || status < 200L || status > 299L) {
      return(robots_ssrfr_failure(
        "response-too-large",
        binding$hop,
        check = "decoded-bytes",
        limit = "max_response_size",
        status = status,
        observed_bytes = observed
      ))
    }
    body <- body[seq_len(limit)]
    truncated <- TRUE
  }
  locations <- unname(headers[names(headers) == "location"])
  binding$state$location_count <- length(locations)
  if (length(locations) == 1L) {
    binding$state$location <- locations[[1L]]
  }
  response <- list(status = status, headers = headers, body = body)
  if (truncating) {
    response$truncated <- truncated
    response$observed_bytes <- observed
  }
  structure(response, class = "ssrfr_response")
}

local_robots_ssrfr_transport <- function(env) {
  if (!requireNamespace(robots_ssrfr_pkg, quietly = TRUE)) {
    return(invisible())
  }
  real_prepare <- robots_ssrfr_fn("ssrf_prepare_hop")
  real_fetch <- robots_ssrfr_fn("ssrf_fetch")
  mocked <- function() !is.null(getOption("httr2_mock"))
  testthat::local_mocked_bindings(
    ssrf_prepare_hop = function(url, policy, request = NULL, from = NULL) {
      if (mocked()) {
        return(robots_mock_prepare_hop(url, policy, from))
      }
      real_prepare(url, policy, request = request, from = from)
    },
    ssrf_fetch = function(binding) {
      if (mocked()) {
        return(robots_mock_fetch(binding))
      }
      real_fetch(binding)
    },
    .package = robots_ssrfr_pkg,
    .env = env
  )
}
