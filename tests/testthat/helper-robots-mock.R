# The shared mocked robots.txt transport. Lives in a helper because two test
# files drive it: the producer tests (test-robots-validate.R) and the
# robots-aware entry-point tests (test-validate-sitemap-robots.R).
#
# A mocked robots.txt transport. Each origin's /robots.txt gets a deterministic
# response keyed on its host: `disallow.example` blocks `/private`,
# `allow.example` serves a body that allows everything, `missing.example` 404s
# (allow-all), and `boom.example` 500s (indeterminate).
mock_robots <- function(req) {
  host <- httr2::url_parse(req$url)$hostname
  if (identical(host, "disallow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /private\n")
    ))
  }
  if (identical(host, "allow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /other\n")
    ))
  }
  if (identical(host, "missing.example")) {
    return(httr2::response(status_code = 404L, url = req$url, body = raw(0)))
  }
  httr2::response(status_code = 503L, url = req$url, body = raw(0))
}

with_robots <- function(code) {
  httr2::with_mocked_responses(mock_robots, code)
}
