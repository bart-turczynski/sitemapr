Feature: Stable findings output contract
  # Covers: SITE-tqtmfqlv, SITE-nmfuizdy
  # validate_sitemap returns a tibble whose column schema, layer vocabulary,
  # subject ref format, and code taxonomy are part of the compatibility contract.
  # See docs/findings-contract.md for the full specification.

  Scenario: validate_sitemap returns a tibble
    Given any sitemap fixture
    When I call validate_sitemap on the fixture
    Then the return value is a tibble

  Scenario: Findings tibble has the required columns
    Given fixture "schema-invalid-urlset.xml" that produces at least one finding
    When I call validate_sitemap on the fixture
    Then the result has columns: code, severity, layer, subject_type, subject_ref, message, evidence, mode, is_strict_only, remediation_hint

  Scenario: Severity is always one of the four defined values
    Given any fixture that produces findings
    When I call validate_sitemap on the fixture
    Then every row in the severity column is one of "fatal", "error", "warning", "info"

  Scenario: Layer is always one of the nine defined values
    Given any fixture that produces findings
    When I call validate_sitemap on the fixture
    Then every row in the layer column is one of the values in the layer vocabulary

  Scenario: subject_ref follows the stable URI scheme
    Given fixture "url-duplicate-loc.xml" which produces an entry-level finding
    When I call validate_sitemap on the fixture
    Then the subject_ref value begins with "sitemap://"
    And the fragment portion follows the "#entry:<n>" pattern

  Scenario: Evidence excerpt is capped at 500 characters for XML findings
    Given a fixture that produces an XML-level finding with long content
    When I call validate_sitemap on the fixture
    Then the excerpt field in each evidence list is at most 500 characters

  Scenario: Evidence excerpt is capped at 200 characters for text sitemap findings
    Given fixture "text-long-url.txt" that produces a text-sitemap finding
    When I call validate_sitemap on the fixture
    Then the excerpt field in the text finding is at most 200 characters

  Scenario: mode column reflects the call mode
    Given fixture "schema-invalid-urlset.xml"
    When I call validate_sitemap in strict mode
    Then every row in the mode column is "strict"

  Scenario: is_strict_only is TRUE for strict-only rules and FALSE otherwise
    Given fixture "lastmod-date-only.xml"
    When I call validate_sitemap in strict mode
    Then the PROTOCOL_LASTMOD_DATE_ONLY row has is_strict_only TRUE

  Scenario: remediation_hint is NA when not applicable
    Given a finding that has no associated remediation hint
    When I inspect the finding row
    Then the remediation_hint value is NA

  Scenario: strict mode fails on schema violations
    Given fixture "schema-invalid-urlset.xml"
    When I call validate_sitemap in strict mode
    Then at least one finding has severity "error" or "fatal"

  Scenario: non-strict mode performs best-effort parse and still reports schema violations
    Given fixture "schema-invalid-urlset.xml"
    When I call validate_sitemap in non-strict mode
    Then schema findings are still present in the result
    And the findings have severity at most "warning" (not "fatal" or "error")

  Scenario: Strict-only rules are absent from non-strict findings
    Given fixture "lastmod-date-only.xml" which triggers a strict-only rule
    When I call validate_sitemap in non-strict mode
    Then no PROTOCOL_LASTMOD_DATE_ONLY finding is present

  Scenario: Finding codes are stable and treated as a compatibility contract
    Given any fixture that produces a PROTOCOL_DUPLICATE_LOC finding
    When I call validate_sitemap twice on the same fixture with the same mode
    Then the code column values are identical between the two calls

  Scenario: Findings are deterministic across repeated runs
    Given any sitemap fixture
    When I call validate_sitemap twice on the same fixture with the same mode and catalog version
    Then the two result tibbles are identical row-for-row
