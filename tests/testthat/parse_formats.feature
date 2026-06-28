Feature: Parse classified content into tidy rows
  # Covers: SITE-saqolkqu
  # sitemapr parses XML urlset, text sitemaps, gzip streams, and local
  # tar.gz archives into a tidy tibble. Parse APIs signal classed conditions;
  # they never emit validation findings.

  Scenario: XML urlset produces a tidy tibble with standard columns
    Given fixture "valid-minimal.xml"
    When I call read_sitemap on the fixture
    Then the result is a tibble
    And the columns include loc, lastmod, changefreq, priority, images, video, news, alternates, source_sitemap

  Scenario: lastmod is returned as POSIXct
    Given fixture "valid-full-fields.xml" containing a lastmod value
    When I call read_sitemap on the fixture
    Then the lastmod column has class POSIXct

  Scenario: Extension data appears as list-columns
    Given fixture "ns-image.xml" with image extension entries
    When I call read_sitemap on the fixture
    Then the images column is a list-column
    And each element contains the structured image data for that URL

  Scenario: Text sitemap produces rows with loc populated and other columns NA
    Given fixture "valid-text.txt"
    When I call read_sitemap on the fixture
    Then each row has a non-NA loc
    And lastmod, changefreq, priority are NA

  Scenario: Gzip-compressed XML is decompressed transparently
    Given fixture "valid.xml.gz"
    When I call read_sitemap on the fixture
    Then the result matches the uncompressed equivalent

  Scenario: Local tar.gz archive is extracted with bounded limits
    Given a local fixture "valid.tar.gz" containing two sitemap files
    When I call read_sitemap on the archive path
    Then rows from both sitemap files appear in the result
    And the source_sitemap column distinguishes the two files

  Scenario: Non-sitemap files inside a tar.gz are skipped with an info finding
    Given a local fixture "mixed.tar.gz" containing one sitemap and one README
    When I call read_sitemap on the archive path
    Then only sitemap rows appear in the result
    And the problems attribute records the skipped non-sitemap file

  Scenario: Path-traversal entries in a tar.gz are rejected
    Given a local fixture "path-traversal.tar.gz" with a "../evil" entry
    When I call read_sitemap on the archive path
    Then the traversal entry is rejected
    And no file is written outside the extraction boundary

  Scenario: Malformed gzip raises a classed condition
    Given fixture "malformed.xml.gz"
    When I call read_sitemap on the fixture
    Then a sitemapr-classed error condition is raised
    And the condition class indicates a decompression failure

  Scenario: source_sitemap column reflects provenance for all formats
    Given a sitemap index with two child XML files
    When I call read_sitemap on the sitemap index
    Then each row's source_sitemap value is the URL of the child that contributed it
    And rows from the index itself (if any) carry the index URL

  Scenario: Parse API never emits findings tibble rows
    Given fixture "valid-full-fields.xml" with a field sitemap validators would flag
    When I call read_sitemap on the fixture
    Then the return value is a tibble of URL rows, not a findings tibble
    And no validate_sitemap-style code column is present

  Scenario: Entry-point fetch failure raises an error condition
    Given a URL that returns a 500 response
    When I call read_sitemap on that URL
    Then an error-class condition is raised
    And the error identifies the URL and the HTTP status

  Scenario: sources attribute is attached to the result
    Given fixture "valid-minimal.xml"
    When I call read_sitemap on the fixture
    Then the result has a sources attribute
    And the attribute contains fetch metadata for each source processed
