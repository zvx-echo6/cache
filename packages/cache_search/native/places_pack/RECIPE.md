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
- `arrival` in the rules: where a route to a place goes when that is not its point (`arrival.rs`): a hospital's or
  emergency room's emergency entrance (else its main door), an airport's passenger
  terminal (its middle door; the terminal with public doors nearest public parking), a large area's nearest public parking
  (an outline at least 250 m across: parks, campuses, malls), or another place's main door. The OSM tags of terminals, doors
  and parking are rules, as data; the points go in each place's `arrival_lat`/`arrival_lon`. Only OSM areas (ways) and
  airports get one; relations are not read. A pack, tile or merged database built before this has no arrival columns and
  reads as before; places get arrival points only when the places are built again.
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

## Places in regions: the tiled build (build host)

The places that regions download are cut on Valhalla's level 1 grid (docs/PLACES-TILES.md). Every step runs in a
container on the build host; nothing is installed on the host itself.

1. Overture extract (`python:3.12-slim` with `duckdb==1.1.3`, pip-installed in the container):
   `python scripts/overture_extract.py --release <release> --bbox=W,S,E,N --out in/` writes `overture_places.csv` (the 14
   columns above plus `taxonomy_primary`, `street`, `locality`, `postcode`, `region`, `tile`), `overture_addresses.csv`
   (sorted by tile, street, postcode, postal city, id) and `overture_taxonomy.tsv` (the release's category paths).
2. OSM: the Geofabrik extract for the area (a box can be cut from a larger one with `osmium extract -b`).
3. `places_pack harvest --osm-pbf area.osm.pbf --overture-csv in/overture_places.csv --out work/harvest.sqlite`: the rules
   applied once, every place and town written by level 1 tile.
4. `places_pack blocks --harvest work/harvest.sqlite --admins admins.sqlite --out work/blocks [--bbox=W,S,E,N] --jobs N`:
   one format 2 pack per level 0 cell (4 degrees), built with a 0.25 degree halo that is dropped afterwards.
5. `places_pack addresses --csv in/overture_addresses.csv --blocks work/blocks --admins admins.sqlite --out work/addresses.sqlite`:
   the street rows, one street at a time; `street_expanded` writes out USPS Publication 28 suffixes and directionals
   (`usps-pub28.tsv`), in the data only.
6. (`wiki` and `embed` on the blocks, later.)
7. `places_pack cut --blocks work/blocks --addresses work/addresses.sqlite --build na-places-YYYY-MM-DD --out out --jobs N`:
   `out/<build>/1/aaa/bbb.sqlite.gz` and `out/<build>/index.tsv`.
8. `places_pack common --blocks work/blocks --build <build> --out out/<build>/common.sqlite --taxonomy in/overture_taxonomy.tsv
   --kinds-described kinds-described.tsv --overture-release <release> --osm-source "<file and date>"`.

Kind descriptions: `scripts/describe_kinds.py --common out/<build>/common.sqlite --tsv kinds-described.tsv` asks
claude-haiku-5-5 (Message Batches API, about 50 kinds per request) for one plain line per kind that is not in the file yet,
and appends it with the model and date. The file is reviewed and kept here; run `common` again afterwards. A kind the
rules define keeps the rules' description; a kind with no line uses its Overture taxonomy path or OSM tag key.
