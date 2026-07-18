# Tests for the pure hreflang cluster graph primitive (R/hreflang-graph.R).
# Fixtures are built in-line so each graph is deterministic and self-contained.
# No findings/severity are asserted here — this is the data structure only.

# One <xhtml:link> as the parser emits it: an empty list carrying rel/hreflang/
# href as R attributes (the xml2::as_list() shape).
mk_link <- function(hreflang, href, rel = "alternate") {
  structure(list(), rel = rel, hreflang = hreflang, href = href)
}

# A faithful row tibble from parallel loc / alternates lists.
mk_rows <- function(loc, alternates) {
  sitemap_rows(loc = loc, alternates = alternates)
}

test_that("a corpus with no alternates yields the empty graph shape", {
  rows <- mk_rows(
    loc = c("https://a.com/x", "https://a.com/y"),
    alternates = list(NULL, NULL)
  )
  g <- build_hreflang_graph(rows)
  expect_identical(nrow(g$nodes), 0L)
  expect_identical(nrow(g$edges), 0L)
  expect_identical(nrow(g$clusters), 0L)
  expect_named(
    g$nodes,
    c("url_key", "url_raw", "node_kind", "cluster")
  )
  expect_named(
    g$edges,
    c("source_key", "target_key", "hreflang", "n_occurrences", "occurrences")
  )
})

test_that("a reciprocal pair is one cluster with both directed edges", {
  rows <- mk_rows(
    loc = c("https://a.com/en", "https://a.com/de"),
    alternates = list(
      list(
        mk_link("en", "https://a.com/en"),
        mk_link("de", "https://a.com/de")
      ),
      list(
        mk_link("en", "https://a.com/en"),
        mk_link("de", "https://a.com/de")
      )
    )
  )
  g <- build_hreflang_graph(rows)
  expect_identical(nrow(g$nodes), 2L)
  expect_true(all(g$nodes$node_kind == "internal"))
  expect_length(unique(g$nodes$cluster), 1L)
  # en->en, en->de, de->en, de->de : four directed edges.
  expect_identical(nrow(g$edges), 4L)
  expect_identical(g$clusters$size, 2L)
  expect_identical(g$clusters$n_internal, 2L)
  expect_identical(g$clusters$n_external, 0L)
})

test_that("external targets are represented explicitly, not dropped", {
  rows <- mk_rows(
    loc = "https://a.com/en",
    alternates = list(list(
      mk_link("de", "https://other.com/de"),
      mk_link("fr", "https://other.com/fr")
    ))
  )
  g <- build_hreflang_graph(rows)
  ext <- g$nodes[g$nodes$node_kind == "external", ]
  expect_identical(nrow(ext), 2L)
  expect_setequal(
    ext$url_key,
    c("https://other.com/de", "https://other.com/fr")
  )
  # Source and its external targets share one cluster.
  expect_length(unique(g$nodes$cluster), 1L)
  expect_identical(g$clusters$n_external, 2L)
  expect_identical(g$clusters$n_internal, 1L)
})

test_that("duplicate edges collapse and retain every occurrence", {
  # Two rows whose loc canonicalizes to the same key (default-port collapse),
  # each declaring the same target/token -> one edge, two occurrences.
  rows <- mk_rows(
    loc = c("https://a.com/en", "https://a.com:443/en"),
    alternates = list(
      list(mk_link("de", "https://a.com/de")),
      list(mk_link("de", "https://a.com/de"))
    )
  )
  g <- build_hreflang_graph(rows)
  edge <- g$edges[
    g$edges$source_key == "https://a.com/en" &
      g$edges$target_key == "https://a.com/de",
  ]
  expect_identical(nrow(edge), 1L)
  expect_identical(edge$n_occurrences, 2L)
  ev <- edge$occurrences[[1L]]
  expect_identical(nrow(ev), 2L)
  # Raw evidence is retained, including the distinct raw source bytes.
  expect_setequal(
    ev$source_raw,
    c("https://a.com/en", "https://a.com:443/en")
  )
  expect_setequal(ev$row, c(1L, 2L))
})

test_that("an asymmetric link still clusters both URLs (undirected)", {
  # a declares b as an alternate; b declares nothing back.
  rows <- mk_rows(
    loc = c("https://a.com/a", "https://a.com/b"),
    alternates = list(
      list(mk_link("de", "https://a.com/b")),
      NULL
    )
  )
  g <- build_hreflang_graph(rows)
  # Only one directed edge exists.
  expect_identical(nrow(g$edges), 1L)
  expect_identical(g$edges$source_key, "https://a.com/a")
  expect_identical(g$edges$target_key, "https://a.com/b")
  # But both nodes are present and in the same cluster.
  expect_setequal(g$nodes$url_key, c("https://a.com/a", "https://a.com/b"))
  expect_length(unique(g$nodes$cluster), 1L)
})

test_that("disjoint alternate sets form separate, stably-ordered clusters", {
  rows <- mk_rows(
    loc = c("https://z.com/1", "https://a.com/1"),
    alternates = list(
      list(mk_link("de", "https://z.com/2")),
      list(mk_link("de", "https://a.com/2"))
    )
  )
  g <- build_hreflang_graph(rows)
  expect_identical(nrow(g$clusters), 2L)
  # Cluster ids are ordered by the smallest member key: a.com before z.com.
  members1 <- g$clusters$members[[1L]]
  members2 <- g$clusters$members[[2L]]
  expect_true(all(startsWith(members1, "https://a.com/")))
  expect_true(all(startsWith(members2, "https://z.com/")))
})

test_that("a missing hreflang token still forms an edge with NA token", {
  rows <- mk_rows(
    loc = "https://a.com/en",
    alternates = list(list(
      structure(list(), rel = "alternate", href = "https://a.com/de")
    ))
  )
  g <- build_hreflang_graph(rows)
  expect_identical(nrow(g$edges), 1L)
  expect_true(is.na(g$edges$hreflang))
})

test_that("a relative href becomes a distinct external node (raw fallback)", {
  rows <- mk_rows(
    loc = "https://a.com/en",
    alternates = list(list(mk_link("de", "/de")))
  )
  g <- build_hreflang_graph(rows)
  target <- g$nodes[g$nodes$node_kind == "external", ]
  expect_identical(nrow(target), 1L)
  # No absolute canonical form, so the trimmed raw bytes key the node.
  expect_identical(target$url_key, "/de")
})

test_that("the graph is invariant to input row order", {
  rows <- mk_rows(
    loc = c("https://a.com/en", "https://a.com/de", "https://a.com/fr"),
    alternates = list(
      list(
        mk_link("de", "https://a.com/de"),
        mk_link("fr", "https://a.com/fr")
      ),
      list(mk_link("en", "https://a.com/en")),
      list(mk_link("x-default", "https://ext.com/root"))
    )
  )
  g1 <- build_hreflang_graph(rows)
  g2 <- build_hreflang_graph(rows[c(3L, 1L, 2L), ])
  expect_identical(g1$nodes, g2$nodes)
  # Edge core (identity + count) is order-independent; the occurrences' `row`
  # column tracks the input tibble and so is intentionally not compared.
  core <- c("source_key", "target_key", "hreflang", "n_occurrences")
  expect_identical(g1$edges[core], g2$edges[core])
  expect_identical(g1$clusters, g2$clusters)
})

test_that("it consumes real parser output (alternates list-column shape)", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ',
    'xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    "<url><loc>https://a.com/en</loc>",
    '<xhtml:link rel="alternate" hreflang="de" href="https://a.com/de"/>',
    "</url></urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  g <- build_hreflang_graph(rows)
  expect_identical(nrow(g$edges), 1L)
  expect_identical(g$edges$hreflang, "de")
  expect_setequal(g$nodes$url_key, c("https://a.com/en", "https://a.com/de"))
})
