Feature: Input normalization to source records
  # Covers: SITE-qebdxvlt
  # sitemapr accepts several input forms, applies entrypoint policy,
  # delegates URL mechanics to rurl, and produces normalized source records
  # with both original and normalized values before any network activity.

  Scenario: Direct sitemap URL is accepted without modification to scheme
    Given a direct sitemap URL "https://example.com/sitemap.xml"
    When I create source records
    Then the source record has provenance "submitted-directly"
    And the normalized URL preserves the https scheme
    And the original URL is retained alongside the normalized URL

  Scenario: Explicit http scheme is preserved
    Given a direct sitemap URL "http://example.com/sitemap.xml"
    When I create source records
    Then the normalized URL retains the http scheme
    And no scheme substitution occurs

  Scenario: Schemeless input receives https
    Given a site URL "example.com"
    When I create source records
    Then the normalized URL begins with "https://"
    And the original input "example.com" is retained

  Scenario: Site root URL is reduced to its origin
    Given a site URL "https://example.com/blog/post-1"
    When I create source records
    Then the normalized URL is "https://example.com"

  Scenario: Unicode host is normalized via IDNA
    Given a site URL "https://münchen.de/sitemap.xml"
    When I create source records
    Then the normalized host is the Punycode form "xn--mnchen-3ya.de"
    And the original Unicode host is retained

  Scenario: Host and scheme are lowercased
    Given a direct sitemap URL "HTTPS://EXAMPLE.COM/sitemap.xml"
    When I create source records
    Then the normalized URL is "https://example.com/sitemap.xml"

  Scenario: Path dot-segments are resolved
    Given a direct sitemap URL "https://example.com/a/../sitemaps/./sitemap.xml"
    When I create source records
    Then the normalized path is "/sitemaps/sitemap.xml"

  Scenario: Local file path is accepted and classified
    Given a local file path "/path/to/sitemap.xml"
    When I create source records
    Then the source record has provenance "submitted-directly"
    And no network request is made

  Scenario: URL vector produces multiple source records
    Given a list of sitemap URLs:
      | https://example.com/sitemap1.xml |
      | https://example.com/sitemap2.xml |
    When I create source records
    Then there are 2 source records
    And each has provenance "submitted-list"

  Scenario: URL vector deduplication enforced before cap
    Given a list with the same URL repeated twice
    When I create source records
    Then there is 1 source record after deduplication

  Scenario: URL vector cap is enforced
    Given a list of 26 sitemap URLs
    When I create source records with default limits
    Then an error is raised citing the submitted-list cap of 25

  Scenario: Full-URL identity key is not rurl::clean_url
    Given two sitemap entries with the same scheme+host+path but different ports
    When sitemapr evaluates duplicate loc
    Then the entries are treated as distinct because port is part of the identity key
