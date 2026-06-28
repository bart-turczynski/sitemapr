Feature: Layer C — XSD schema validation
  # Covers: SITE-qcjvesdw
  # validate_sitemap runs Layer C XSD validation against bundled profiles
  # and runtime-generated mixed-namespace profiles. Validation is in-process
  # via xml2::xml_validate; no Java, no subprocess.

  Scenario: Valid core urlset passes schema validation
    Given fixture "valid-minimal.xml"
    When I call validate_sitemap on the fixture in strict mode
    Then no schema-layer findings are produced

  Scenario: Valid sitemapindex passes schema validation
    Given fixture "valid-index.xml"
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: Invalid XML structure produces a SCHEMA_INVALID finding
    Given fixture "schema-invalid-urlset.xml" with a misplaced element
    When I call validate_sitemap on the fixture in strict mode
    Then a finding with code SCHEMA_INVALID and layer "schema" is produced
    And the finding severity is "error" or "fatal"

  Scenario: Image extension document validates against the bundled image profile
    Given fixture "ns-image.xml"
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: News extension document validates against the bundled news profile
    Given fixture "ns-news.xml"
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: Video extension document validates against the bundled video profile
    Given fixture "ns-video.xml"
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: Hreflang extension document validates against the bundled hreflang profile
    Given fixture "ns-hreflang.xml"
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: Document using all four extensions validates via a runtime-generated mixed profile
    Given fixture "ns-all-four.xml" using image, news, video, and hreflang namespaces simultaneously
    When I call validate_sitemap on the fixture
    Then no schema-layer findings are produced

  Scenario: A broken element in one extension is caught even in a multi-extension document
    Given fixture "ns-video-invalid-in-mixed.xml" with an invalid video element alongside valid others
    When I call validate_sitemap on the fixture
    Then a SCHEMA_INVALID finding is produced scoped to the video extension
    And the finding evidence identifies the invalid element

  Scenario: An unknown namespace is flagged
    Given fixture "ns-unknown.xml" with a namespace not in the bundled catalog
    When I call validate_sitemap on the fixture
    Then a SCHEMA_UNKNOWN_NAMESPACE finding is produced

  Scenario: XXE attempt via entity expansion has no effect
    Given a fixture XML document containing an external entity declaration
    When I call validate_sitemap on the fixture
    Then no entity expansion occurs
    And the document is treated as if the entity reference is empty

  Scenario: Schema validation is in-process without Java or subprocess
    Given any valid sitemap fixture
    When I call validate_sitemap on the fixture
    Then the process list shows no Java subprocess spawned during the call
