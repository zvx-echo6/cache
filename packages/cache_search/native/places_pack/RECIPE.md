# places_pack recipe

Builds one region's `places.sqlite` (format in `cache_places/src/schema.rs`, read by `cache_places`).

## Today (desktop, inputs already downloaded)

```
cargo run --release -p places_pack -- build \
  --id idaho --name Idaho --admin-state Idaho \
  --overture-csv overture_places_idaho_bbox.csv \
  --osm-pbf idaho-latest.osm.pbf \
  --admins admins.sqlite \
  --out idaho/places.sqlite
```

- `--overture-csv`: Overture places exported as CSV, 14 columns (id, geometry as hex EWKB, name, basic_category, confidence,
  phone, website, socials, brand_name, brand_wikidata, osm_type, osm_id, source_record_id, raw_sources). It has no address
  columns, so Overture-only places get street from nowhere and their town from the nearest locality.
- `--osm-pbf`: a Geofabrik regional extract. Nodes and ways (centre of up to 48 sampled nodes) are read; relations are not.
- `--admins`: Valhalla's admins.sqlite (countries level 2, states level 4, SpatiaLite blobs; decoded in `admins.rs`). It
  gives each place its state and country, and `--admin-state` picks the region's bounding box. It has no US country
  polygon and no counties, so `--country` (default US) fills the country and `county` stays empty.
- `--rules` (default: `categories.json`, compiled in): the category rules. They are data and are copied into the
  pack's `categories.rules` and `meta.builder_rules`.
- `kinds` in the rules (`categories.json`): what kind of place each record is (`drinking_water`, `picnic_shelter`, ...), from its OSM
  tags or Overture category, first match wins; copied into the pack's `kinds` table with a label and a description, and into each
  place's `kind_id`. A place no kind rule covers takes its raw type's value as its kind. `places_pack inspect` lists the kinds.
- `--no-general`: only the starter categories (about 2 MB for Idaho) instead of every named place (about 29 MB).

## Later (GitHub Actions, per region)

Inputs stay pluggable: each input is a `PlaceSource` (`model.rs`) that turns its records into `Raw` places and
`RawLocality`s using the rules; merge, geography and writing do not know which source was used.

1. Overture: replace the CSV step with a second `PlaceSource` reading Overture's official release GeoParquet
   (`s3://overturemaps-us-west-2/release/<release>/theme=places/type=place/`, filtered to the region's bbox). Columns map
   one to one: `id`, `geometry` (WKB point), `names.primary`, `categories.primary` (= basic_category), `confidence`,
   `phones[0]`, `websites[0]`, `brand.names.primary`, plus `addresses[0]` (freeform, locality, region), which the CSV lacks
   and which would give Overture places a street and a real locality. Needs a Parquet reader crate (not added yet).
2. OSM: download the region's `.osm.pbf` from Geofabrik (`download.geofabrik.de/<region>-latest.osm.pbf`); use as is.
3. Admin boundaries: the same admins.sqlite, or a replacement `Admins` loader (Natural Earth, or OSM admin_level 4 and 6
   relations, which would also give counties).
4. Build, then `places_pack inspect` for the per-category counts, and publish `places.sqlite` with the region pack.

Attribution: OSM data is ODbL, so the app credits "(c) OpenStreetMap contributors"; the pack's `meta.attribution` says so.

## Wikipedia and Wikidata (the `wiki` step, after `build`)

```
places_pack wiki --pack idaho/places.sqlite \
  --geo-tags enwiki-<date>-geo_tags.sql.gz --page-props enwiki-<date>-page_props.sql.gz \
  --items-per-site wikidatawiki-latest-wb_items_per_site.sql.gz \
  --index enwiki-<date>-pages-articles-multistream-index.txt.bz2 \
  --xml-url https://dumps.wikimedia.org/enwiki/<date>/enwiki-<date>-pages-articles-multistream.xml.bz2
```

All from dumps.wikimedia.org (use one dated enwiki dump for the index and the XML; offsets only match within one dump). The
host allows few connections per address: download one file at a time (a parallel start got HTTP 429), and the step itself
makes one range request at a time. Sizes: geo_tags 54 MB, page_props 484 MB, index 285 MB, wb_items_per_site 1.9 GB; the
27 GB XML dump is never downloaded: only the bzip2 streams holding the wanted articles are fetched by HTTP Range
(about 800 streams, a few hundred MB, for Idaho).

IDs only, in this order: (1) the OSM `wikidata`, `wikipedia=en:...`, `wikivoyage=en:...` tags kept by `build`; (2) Overture
`brand_wikidata` is kept as `brand_wikidata` and is never used as the place's own item; (3) for places with no tag, an
English Wikipedia article whose primary coordinate is within 6 km (towns) or 150 m (other places) AND whose title, minus
", State" or " (kind)", is the place's own name. The article's Wikidata item comes from `page_props.wikibase_item`, and its
enwiki and enwikivoyage titles from Wikidata's `wb_items_per_site`. The summary is the article's first paragraph with the
wikitext markup removed, cut to 500 characters at a sentence end.
