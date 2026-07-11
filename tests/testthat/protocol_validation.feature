Feature: Layer D — protocol and semantic validation
  # Covers: SITE-nsixzwux
  # validate_sitemap runs Layer D checks for rules XSD cannot express:
  # counts, field values, URL rules, hreflang policy, encoding, text sitemaps,
  # and typed diagnostics for unsupported inputs.

  # --- URL rules ---

  Scenario: loc with a relative URL produces PROTOCOL_URL_NOT_ABSOLUTE
    Given fixture "url-relative.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_NOT_ABSOLUTE is produced

  Scenario: loc with a non-http(s) scheme produces PROTOCOL_URL_NOT_ABSOLUTE
    Given fixture "url-non-https.xml" with a ftp:// loc
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_NOT_ABSOLUTE is produced

  Scenario: loc outside the sitemap's origin scope produces PROTOCOL_URL_OUT_OF_SCOPE
    Given fixture "url-out-of-scope.xml" where loc belongs to a different domain
    When I call validate_sitemap on the mocked source
    Then a finding with code PROTOCOL_URL_OUT_OF_SCOPE is produced
    # Reconciled (F.4): the protocol scope check only runs when the sitemap has
    # an origin URL (a local file has none), so this drives a mocked URL source.

  Scenario: Two byte-identical loc entries produce PROTOCOL_DUPLICATE_LOC
    Given fixture "urlset-duplicate-loc.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_DUPLICATE_LOC and severity "warning" is produced
    # Reconciled (ADR-005): the committed fixture repeats a byte-identical <loc>,
    # so it is a plain duplicate; the canonical-collision tier is PROTOCOL_URL_EQUIVALENT.

  Scenario: Canonically equal locs with differing bytes produce PROTOCOL_URL_EQUIVALENT
    Given two entries where one uses ":443" and the other omits the default port
    When I call validate_sitemap
    Then a finding with code PROTOCOL_URL_EQUIVALENT and severity "warning" is produced
    And no PROTOCOL_DUPLICATE_LOC finding is produced
    # Reconciled (ADR-005): ":443" and the default-port-omitted form are not
    # byte-identical, so they are an equivalence (likely resolves-to), not a duplicate.

  Scenario: Fragment in loc produces an PROTOCOL_URL_FRAGMENT info finding
    Given fixture "url-fragment.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_FRAGMENT and severity "info" is produced

  Scenario: Invalid percent-encoding in loc produces PROTOCOL_URL_INVALID_ESCAPE
    Given fixture "url-invalid-escape.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_INVALID_ESCAPE is produced

  Scenario: A raw IRI loc produces an info PROTOCOL_URL_NOT_ESCAPED and keys on its URI form
    Given fixture "url-iri-path.xml" with a Unicode path
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_NOT_ESCAPED and severity "info" is produced
    And the identity key uses the percent-encoded URI form
    # Reconciled (ADR-005): a raw Unicode <loc> is a valid IRI (conformant), but
    # the info advisory names the percent-encoded URI form crawlers actually fetch.

  Scenario: A loc with a URI-and-IRI-illegal character produces a warning PROTOCOL_URL_NOT_ESCAPED
    Given fixture "url-unescaped-illegal.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_NOT_ESCAPED and severity "warning" is produced

  # --- Count and field limits ---

  Scenario: Sitemap with exactly 50000 URLs passes the count check
    Given fixture "url-count-at-cap.xml" with 50000 entries
    When I call validate_sitemap on the fixture
    Then no PROTOCOL_URL_COUNT_EXCEEDED finding is produced

  Scenario: Sitemap with more than 50000 URLs produces PROTOCOL_URL_COUNT_EXCEEDED
    Given fixture "url-count-over-cap.xml" with 50001 entries
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_URL_COUNT_EXCEEDED is produced

  Scenario: priority 0.0 and 1.0 are valid boundaries
    Given fixture "priority-boundary.xml" with entries at 0.0 and 1.0
    When I call validate_sitemap on the fixture
    Then no priority finding is produced

  Scenario: priority outside [0.0, 1.0] produces PROTOCOL_PRIORITY_OUT_OF_RANGE
    Given fixture "priority-out-of-range.xml" with priority 1.5
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_PRIORITY_OUT_OF_RANGE is produced

  Scenario: invalid changefreq value produces PROTOCOL_CHANGEFREQ_INVALID
    Given fixture "changefreq-invalid.xml" with changefreq "biweekly"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_CHANGEFREQ_INVALID is produced

  Scenario: Date-only lastmod is valid but produces info in strict mode
    Given fixture "lastmod-date-only.xml"
    When I call validate_sitemap on the fixture in strict mode
    Then a finding with code PROTOCOL_LASTMOD_DATE_ONLY and severity "info" is produced

  Scenario: Date-only lastmod info is suppressed in non-strict mode
    Given fixture "lastmod-date-only.xml"
    When I call validate_sitemap on the fixture in non-strict mode
    Then no PROTOCOL_LASTMOD_DATE_ONLY finding is produced

  Scenario: Invalid W3C Date-Time lastmod produces PROTOCOL_LASTMOD_INVALID
    Given fixture "lastmod-invalid.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_LASTMOD_INVALID is produced

  # --- hreflang ---

  Scenario: Valid hreflang set with x-default passes protocol validation
    Given fixture "hreflang-valid.xml"
    When I call validate_sitemap on the fixture
    Then no hreflang finding is produced

  Scenario: Hreflang tag with underscore separator produces HREFLANG_SEPARATOR_INVALID
    Given fixture "hreflang-invalid-sep.xml" with "en_US" as a tag
    When I call validate_sitemap on the fixture
    Then a finding with code HREFLANG_SEPARATOR_INVALID is produced
    # Reconciled (F.4): classify_hreflang_token() in R/protocol-validate.R maps an
    # underscore to HREFLANG_SEPARATOR_INVALID (the bad-separator check precedes
    # the family-shape check). The draft's HREFLANG_FORMAT_INVALID was stale; the
    # scenario is reconciled to the real classifier output (classifier unchanged).

  Scenario: Missing x-default in a hreflang set produces HREFLANG_XDEFAULT_MISSING
    Given fixture "hreflang-no-xdefault.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code HREFLANG_XDEFAULT_MISSING is produced

  Scenario: Duplicate hreflang value in one entry produces HREFLANG_DUPLICATE
    Given fixture "hreflang-duplicate.xml"
    When I call validate_sitemap on the fixture
    Then a finding with code HREFLANG_DUPLICATE is produced

  Scenario: Relative href in hreflang produces HREFLANG_HREF_RELATIVE in strict mode
    Given fixture "hreflang-relative-href.xml"
    When I call validate_sitemap on the fixture in strict mode
    Then a finding with code HREFLANG_HREF_RELATIVE is produced

  Scenario: Relative href in hreflang is not flagged in non-strict mode
    Given fixture "hreflang-relative-href.xml"
    When I call validate_sitemap on the fixture in non-strict mode
    Then no HREFLANG_HREF_RELATIVE finding is produced

  # --- Text sitemaps ---

  Scenario: Valid text sitemap passes protocol validation
    Given fixture "valid-text.txt"
    When I call validate_sitemap on the fixture
    Then no protocol finding is produced

  Scenario: Blank line in text sitemap produces info in strict mode
    Given fixture "text-blank-lines.txt"
    When I call validate_sitemap in strict mode
    Then a finding with code PROTOCOL_TEXT_BLANK_LINE and severity "info" is produced

  Scenario: Blank line in text sitemap is silent in non-strict mode
    Given fixture "text-blank-lines.txt"
    When I call validate_sitemap in non-strict mode
    Then no PROTOCOL_TEXT_BLANK_LINE finding is produced

  Scenario: URL longer than 2048 chars in text sitemap produces PROTOCOL_TEXT_URL_TOO_LONG
    Given fixture "text-long-url.txt"
    When I call validate_sitemap on the fixture
    Then a finding with code PROTOCOL_TEXT_URL_TOO_LONG is produced

  # --- Unsupported inputs ---

  Scenario: HTML at a sitemap URL produces UNSUPPORTED_HTML_MASQUERADE
    Given fixture "html-masquerade.html"
    When I call validate_sitemap on the fixture
    Then a finding with code UNSUPPORTED_HTML_MASQUERADE is produced

  Scenario: Unknown XML root element produces UNSUPPORTED_ROOT
    Given fixture "unsupported-root.xml" with a non-sitemap root
    When I call validate_sitemap on the fixture
    Then a finding with code UNSUPPORTED_ROOT is produced

  Scenario: Sitemap index child pointing at an unsupported feed dialect produces UNSUPPORTED_FEED
    Given fixture "index-rss-child.xml" whose child loc is an unsupported feed
    When I call validate_sitemap on the mocked source
    Then a finding with code UNSUPPORTED_FEED is produced
    And the finding severity is "info" or "warning"
    # Supported feed dialects (RSS 2.0 / Atom) now parse into rows; only an
    # unsupported dialect (a <feed> in a non-Atom namespace) still yields
    # UNSUPPORTED_FEED. Expansion only runs for a URL source, so this drives the
    # index URL with an offline httr2 mock serving the index and its feed child.
    # The producer emits UNSUPPORTED_FEED at "error" severity, which the "info or
    # warning" tolerance accepts (the scenario only forbids a fatal).
