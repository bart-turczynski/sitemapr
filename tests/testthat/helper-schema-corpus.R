# Conformance corpus for the bundled XSD profiles. Single source of truth shared
# by test-schema-conformance.R (authored schemas accept positives / reject
# negatives) and the dev-only data-raw/schemas/check-parity.R oracle (authored
# schemas match the canonical upstream verdicts).
#
# Each entry roots a document at a schema's GLOBAL element so the profile can be
# validated in isolation. Cases exercise required children, child order, the
# enumerations, the lexical patterns, and the numeric bounds of each profile.

schema_conformance_corpus <- function() {
  # Short upper-case namespace handles and long XML literals below; neither the
  # object-name nor the line-length linter is meaningful for this fixture data.
  # nolint start: line_length_linter, object_name_linter.
  S <- "http://www.sitemaps.org/schemas/sitemap/0.9"
  IMG <- "http://www.google.com/schemas/sitemap-image/1.1"
  VID <- "http://www.google.com/schemas/sitemap-video/1.1"
  NWS <- "http://www.google.com/schemas/sitemap-news/0.9"
  PM <- "http://www.google.com/schemas/sitemap-pagemap/1.0"
  XH <- "http://www.w3.org/1999/xhtml"

  list(
    "sitemap.xsd" = list(
      list(
        sprintf(
          '<urlset xmlns="%s"><url><loc>https://example.com/</loc></url></urlset>',
          S
        ),
        TRUE
      ),
      list(
        sprintf(
          '<urlset xmlns="%s"><url><loc>https://example.com/a</loc><lastmod>2024-01-02</lastmod><changefreq>daily</changefreq><priority>0.8</priority></url></urlset>',
          S
        ),
        TRUE
      ),
      list(
        sprintf(
          '<urlset xmlns="%s"><url><loc>https://example.com/a</loc><priority>1.5</priority></url></urlset>',
          S
        ),
        FALSE
      ),
      list(
        sprintf(
          '<urlset xmlns="%s"><url><loc>https://example.com/a</loc><changefreq>often</changefreq></url></urlset>',
          S
        ),
        FALSE
      ),
      list(
        sprintf(
          '<urlset xmlns="%s"><url><lastmod>2024-01-02</lastmod></url></urlset>',
          S
        ),
        FALSE
      ),
      list(
        sprintf('<urlset xmlns="%s"><url><loc>short</loc></url></urlset>', S),
        FALSE
      )
    ),
    "siteindex.xsd" = list(
      list(
        sprintf(
          '<sitemapindex xmlns="%s"><sitemap><loc>https://example.com/sm.xml</loc></sitemap></sitemapindex>',
          S
        ),
        TRUE
      ),
      list(
        sprintf(
          '<sitemapindex xmlns="%s"><sitemap><loc>https://example.com/sm.xml</loc><lastmod>2024-01-02T03:04:05+00:00</lastmod></sitemap></sitemapindex>',
          S
        ),
        TRUE
      ),
      list(
        sprintf(
          '<sitemapindex xmlns="%s"><sitemap><lastmod>2024-01-02</lastmod></sitemap></sitemapindex>',
          S
        ),
        FALSE
      ),
      list(
        sprintf(
          '<sitemapindex xmlns="%s"><sitemap><loc>https://example.com/sm.xml</loc><lastmod>2005/05/10</lastmod></sitemap></sitemapindex>',
          S
        ),
        FALSE
      )
    ),
    "sitemap-image.xsd" = list(
      list(
        sprintf(
          '<image xmlns="%s"><loc>https://example.com/a.jpg</loc></image>',
          IMG
        ),
        TRUE
      ),
      list(
        sprintf(
          '<image xmlns="%s"><loc>https://example.com/a.jpg</loc><caption>c</caption><geo_location>City</geo_location><title>t</title><license>https://example.com/l</license></image>',
          IMG
        ),
        TRUE
      ),
      list(
        sprintf('<image xmlns="%s"><caption>c</caption></image>', IMG),
        FALSE
      ),
      list(
        sprintf(
          '<image xmlns="%s"><caption>c</caption><loc>https://example.com/a.jpg</loc></image>',
          IMG
        ),
        FALSE
      )
    ),
    "sitemap-news.xsd" = list(
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>en</language></publication><publication_date>2024-01-02</publication_date><title>Hi</title></news>',
          NWS
        ),
        TRUE
      ),
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>zh-cn</language></publication><access>Subscription</access><genres>PressRelease, Blog</genres><publication_date>2024-01-02T03:04:05Z</publication_date><title>Hi</title><keywords>a,b</keywords><stock_tickers>NASDAQ:AMAT</stock_tickers></news>',
          NWS
        ),
        TRUE
      ),
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>english</language></publication><publication_date>2024-01-02</publication_date><title>Hi</title></news>',
          NWS
        ),
        FALSE
      ),
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>en</language></publication><access>Free</access><publication_date>2024-01-02</publication_date><title>Hi</title></news>',
          NWS
        ),
        FALSE
      ),
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>en</language></publication><publication_date>2024-01-02</publication_date></news>',
          NWS
        ),
        FALSE
      ),
      list(
        sprintf(
          '<news xmlns="%s"><publication><name>Ex</name><language>en</language></publication><genres>Foo</genres><publication_date>2024-01-02</publication_date><title>Hi</title></news>',
          NWS
        ),
        FALSE
      )
    ),
    "sitemap-pagemap.xsd" = list(
      list(
        sprintf(
          '<PageMap xmlns="%s"><DataObject type="document"><Attribute name="author" value="x"/></DataObject></PageMap>',
          PM
        ),
        TRUE
      ),
      list(sprintf('<PageMap xmlns="%s"></PageMap>', PM), TRUE),
      list(
        sprintf(
          '<PageMap xmlns="%s"><DataObject><Attribute name="a"/></DataObject></PageMap>',
          PM
        ),
        FALSE
      ),
      list(
        sprintf(
          '<PageMap xmlns="%s"><DataObject type="d"><Attribute>v</Attribute></DataObject></PageMap>',
          PM
        ),
        FALSE
      )
    ),
    "sitemap-video.xsd" = list(
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description></video>',
          VID
        ),
        TRUE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description><content_loc>https://example.com/v.mp4</content_loc><player_loc allow_embed="yes">https://example.com/p</player_loc><duration>600</duration><rating>4.5</rating><tag>a</tag><restriction relationship="allow">US GB</restriction><price currency="USD">1.99</price><tvshow><show_title>S</show_title><video_type>full</video_type><season_number>1</season_number></tvshow><platform relationship="deny">tv</platform><live>no</live><id type="url">https://example.com/x</id></video>',
          VID
        ),
        TRUE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description><rating>6</rating></video>',
          VID
        ),
        FALSE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description><duration>30000</duration></video>',
          VID
        ),
        FALSE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>%s</title><description>D</description></video>',
          VID,
          strrep("x", 101)
        ),
        FALSE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description><restriction>US</restriction></video>',
          VID
        ),
        FALSE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title><description>D</description><id type="bad">x</id></video>',
          VID
        ),
        FALSE
      ),
      list(
        sprintf(
          '<video xmlns="%s"><thumbnail_loc>https://example.com/t.jpg</thumbnail_loc><title>T</title></video>',
          VID
        ),
        FALSE
      )
    ),
    "xhtml-hreflang.xsd" = list(
      list(
        sprintf(
          '<link xmlns="%s" rel="alternate" hreflang="de" href="https://example.com/de/"/>',
          XH
        ),
        TRUE
      ),
      list(sprintf('<link xmlns="%s" rel="alternate"/>', XH), FALSE)
    )
  )
  # nolint end
}
