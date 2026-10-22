Feature: Fetch and byte-level classification of sources
  # Covers: SITE-efrzatkb, SITE-veptsgbs
  # sitemapr fetches each source record with bounded, safe HTTP requests
  # and classifies the content by bytes, not by extension or Content-Type.

  Scenario: A child 4xx response produces a warning, not an error
    Given a sitemap index that references a child URL returning 404
    When I call read_sitemap on the index
    Then a warning-class condition is raised for the child
    And the partial parse result still contains rows from successful children
    And the failed child appears in the problems attribute
