Feature: Bounded sitemapindex traversal
  # Covers: SITE-mzbuuyfy
  # sitemapr recursively expands sitemapindex children, deduplicates,
  # detects cycles, and enforces depth and count limits.

  Scenario: Sitemapindex children are fetched and parsed
    Given fixture "index-simple.xml" referencing two child sitemaps
    When I call read_sitemap on the index
    Then rows from both child sitemaps appear in the result
    And the tree depth for child rows is 1

  Scenario: sitemap_tree shows depth, parent, and provenance for index children
    Given fixture "index-simple.xml"
    When I call sitemap_tree on the index
    Then each child row carries depth 1
    And parent_sitemap references the index URL
    And provenance is "child-of-index"

  Scenario: Duplicate child URLs in an index are expanded only once
    Given a sitemapindex that lists the same child URL twice
    When I call read_sitemap on the index
    Then the child is fetched and parsed exactly once

  Scenario: Self-referential index is detected and stopped
    Given fixture "index-self-ref.xml" where the index lists itself as a child
    When I call read_sitemap on the index
    Then the cycle is detected
    And an INDEX_CYCLE_DETECTED warning finding is produced
    And the self-reference is not followed

  Scenario: A -> B -> A cross-index cycle is detected
    Given fixture "index-cycle-ab.xml" where index A points to B and B points to A
    When I call read_sitemap on index A
    Then the cycle is detected at the second visit of A
    And an INDEX_CYCLE_DETECTED finding is produced for the repeated URL
    And expansion stops without infinite recursion

  Scenario: Max recursion depth of 3 is enforced
    Given fixture "index-deep.xml" with nesting deeper than 3 levels
    When I call read_sitemap on the root index
    Then an INDEX_DEPTH_EXCEEDED finding is produced
    And no children beyond depth 3 are fetched

  Scenario: Max child count cap is enforced
    Given a sitemapindex that declares more child URLs than the configured cap
    When I call read_sitemap with the default child count cap
    Then only the capped number of children are expanded
    And an INDEX_CHILD_COUNT_EXCEEDED finding is produced

  Scenario: Nested sitemapindex emits a warning but is still expanded
    Given fixture "index-nested.xml" where a child is itself a sitemapindex
    When I call read_sitemap on the parent
    Then a SITEMAP_INDEX_NESTED warning finding is produced
    And rows from the nested index's children are still present in the result

  Scenario: Parent-to-child chain is preserved in sitemap_tree
    Given fixture "index-simple.xml"
    When I call sitemap_tree on the index
    Then the tree rows form a connected parent-child chain from root to each leaf
