Feature: Discovery of sitemap candidates from a site root
  # Covers: SITE-avdanhik, SITE-pgtudaic, SITE-stxkwfbq
  # From a site/root URL, sitemapr discovers sitemaps from two sources: the
  # robots.txt Sitemap: directive (ADR-005) and a fixed guessed-path catalog. It
  # classifies candidates as accepted or rejected and returns the result as part
  # of sitemap_tree(). Robots rules (Disallow/Allow) are never applied.

  Scenario: Generic guessed paths are tried in catalog order
    Given a site root URL "https://example.com"
    When discovery runs against a fixture server
    Then the candidates include standard paths such as "/sitemap.xml" and "/sitemap_index.xml"
    And candidates are tried in the documented catalog order

  Scenario: CMS-specific paths are included in the catalog
    Given a site root URL "https://example.com"
    When discovery runs
    Then the candidates include at least one CMS-specific path
    And CMS paths appear after generic paths in the ordered catalog

  Scenario: Candidate deduplication prevents duplicate requests
    Given a guess catalog that would produce the same URL twice
    When discovery runs
    Then the URL is requested only once

  Scenario: A 200 response promotes a candidate to accepted
    Given a fixture server returns 200 for "/sitemap.xml"
    When discovery runs against "https://example.com"
    Then the sitemap_tree row for "/sitemap.xml" has status "accepted"
    And the reason records the catalog match

  Scenario: A 404 response produces a rejected not-found candidate, not a finding
    Given a fixture server returns 404 for all guesses
    When discovery runs against "https://example.com"
    Then the sitemap_tree rows have status "rejected"
    And the reason is "not-found"
    And validate_sitemap produces no finding for missing guesses

  Scenario: Max candidate cap is enforced
    Given a guess catalog with more entries than the configured candidate cap
    When discovery runs with a cap of 5
    Then at most 5 candidates are evaluated

  Scenario: sitemap_tree includes both accepted and rejected candidates
    Given a fixture where one guess resolves and one returns 404
    When I call sitemap_tree("https://example.com")
    Then the result contains a row for the accepted URL
    And the result contains a row for the rejected URL
    And both rows carry provenance "guessed-path"

  Scenario: sitemap_tree includes depth, parent, URL, page count, gzip, status, reason, provenance
    Given a resolved discovery candidate
    When I call sitemap_tree("https://example.com")
    Then each result row has columns depth, parent_sitemap, sitemap_url, page_count, gzip, status, reason, provenance

  Scenario: robots.txt Sitemap directives are added as discovery candidates
    Given a fixture whose robots.txt lists a non-catalog sitemap
    When discovery runs against "https://example.com"
    Then the result contains a row for the robots-listed sitemap
    And the robots-listed row carries provenance "robots"

  Scenario: robots discovery can be disabled
    Given a fixture whose robots.txt lists a non-catalog sitemap
    When discovery runs against "https://example.com" with robots disabled
    Then no request is made to "/robots.txt"
    And the result has no robots-listed row
