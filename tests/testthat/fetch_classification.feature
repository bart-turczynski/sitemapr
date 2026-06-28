Feature: Fetch and byte-level classification of sources
  # Covers: SITE-efrzatkb, SITE-veptsgbs
  # sitemapr fetches each source record with bounded, safe HTTP requests
  # and classifies the content by bytes, not by extension or Content-Type.

  Scenario: Default User-Agent follows the documented pattern
    Given a fixture server that echoes request headers
    When I fetch a sitemap URL with default settings
    Then the User-Agent header matches "sitemapr/<version> (+<contact-url>)"

  Scenario: Caller can supply a custom User-Agent
    Given a custom user_agent "mybot/1.0"
    When I fetch a sitemap URL
    Then the User-Agent header is "mybot/1.0"

  Scenario: Request timeout is configurable and enforced
    Given a fixture server that delays responses by 60 seconds
    When I fetch with a 5-second timeout
    Then the request fails with a timeout condition before the server responds

  Scenario: A mid-body stall times out and never parses a partial body
    Given a fixture server that starts sending a valid XML sitemap then stalls mid-body
    When the request exceeds the configured timeout
    Then sitemapr raises a sitemapr_timeout condition
    And no partial parse result is returned

  Scenario: A body exceeding the per-resource safety ceiling is discarded
    Given a fixture server that serves a body larger than the configured safety ceiling
    When the body is read into memory
    Then sitemapr raises a sitemapr_body_ceiling condition
    And the over-ceiling body is discarded unparsed

  Scenario: Redirects are followed up to the configured limit
    Given a fixture server that redirects 4 times before serving a sitemap
    When I fetch with a max-redirects limit of 5
    Then the final sitemap content is returned

  Scenario: Redirects exceeding the limit produce an error condition
    Given a fixture server that redirects 6 times
    When I fetch with a max-redirects limit of 5
    Then the request fails with a redirect-limit-exceeded condition

  Scenario: Each redirect target is re-evaluated by the SSRF guard
    Given an initial URL that redirects to an RFC-1918 address
    When I fetch the URL
    Then the redirect is rejected by the SSRF guard
    And the rejection reason identifies the redirect target

  Scenario: Loopback addresses are rejected by the structural SSRF guard
    Given a sitemap URL with host "127.0.0.1"
    When I attempt to fetch it
    Then the request is rejected before any network activity
    And the finding code indicates an SSRF guard rejection

  Scenario: IPv4-mapped IPv6 form of a private address is rejected
    Given a sitemap URL with host "::ffff:192.168.1.1"
    When I attempt to fetch it
    Then the request is rejected by the SSRF guard

  Scenario: Cloud metadata endpoint is rejected
    Given a sitemap URL with host "169.254.169.254"
    When I attempt to fetch it
    Then the request is rejected by the SSRF guard

  Scenario: SSRF guard can be disabled for trusted networks
    Given a URL that would normally be rejected by the structural guard
    When I call read_sitemap with ssrf_guard = FALSE
    Then the URL is fetched without an SSRF rejection

  Scenario: XML sitemap is classified by content bytes, not by file extension
    Given a fixture file named "sitemap.txt" that contains valid XML
    When sitemapr classifies the content
    Then the format is classified as "xml-urlset" based on bytes

  Scenario: Gzip content is classified regardless of extension
    Given a fixture file named "sitemap.unknown" that is gzip-compressed XML
    When sitemapr classifies the content
    Then the format is classified as "gzip"

  Scenario: Fetch metadata is attached to each source
    Given a successfully fetched sitemap
    When I inspect the sources attribute
    Then each source record contains requested_url, final_url, status, redirect_chain, content_type, charset, bytes, timing, error_class, format, root, namespaces, and profile_id

  Scenario: A child 4xx response produces a warning, not an error
    Given a sitemap index that references a child URL returning 404
    When I call read_sitemap on the index
    Then a warning-class condition is raised for the child
    And the partial parse result still contains rows from successful children
    And the failed child appears in the problems attribute
