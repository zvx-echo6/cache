"""Overture extract for places_pack: places, addresses and the category taxonomy of one release, cut to a box.

Runs in a container (python:3.12-slim with duckdb==1.1.3, pip-installed inside the container only):

    python overture_extract.py --release 2026-10-21.0 --bbox=W,S,E,N --out DIR [--threads 12] [--memory 10GB]

Writes to DIR:
- overture_places.csv: the 14 columns `places_pack` has always read (id, geometry as hex WKB, name, basic_category,
  confidence, phone, website, socials, brand_name, brand_wikidata, osm_type, osm_id, source_record_id, raw_sources), plus
  taxonomy_primary (the place's most specific category in Overture's taxonomy: `diner`, where basic_category says
  `casual_eatery`), street, locality, postcode and region from the first address, and the level 1 tile. Permanently
  closed places are left out. Sorted by (tile, id).
- overture_addresses.csv: id, number, street, unit, postcode, postal_city, state (the first address level), country,
  lat, lon, tile; rows without a number or a street are left out. Sorted by (tile, street, postcode, postal_city, id), so
  `places_pack addresses` can read it one street at a time.
- overture_taxonomy.tsv: every category of the release's taxonomy that any place has as its primary (worldwide, not only
  the box), with its path (`taxonomy.hierarchy`, " > "-joined; the most common one when places disagree). The kind
  descriptions fall back to it.
"""

import argparse
import os
import time

import duckdb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", required=True)
    ap.add_argument("--bbox", required=True, help="W,S,E,N in degrees")
    ap.add_argument("--out", required=True)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--memory", default="8GB")
    a = ap.parse_args()
    w, s, e, n = (float(x) for x in a.bbox.split(","))
    os.makedirs(a.out, exist_ok=True)
    c = duckdb.connect()
    c.execute("INSTALL httpfs; INSTALL spatial; LOAD httpfs; LOAD spatial")
    c.execute(f"SET s3_region = 'us-west-2'; SET threads = {a.threads}; SET memory_limit = '{a.memory}'")
    c.execute(f"SET temp_directory = '{os.path.join(a.out, 'duckdb.tmp')}'")
    root = f"s3://overturemaps-us-west-2/release/{a.release}"
    box = f"bbox.xmin >= {w} AND bbox.xmax < {e} AND bbox.ymin >= {s} AND bbox.ymax < {n}"
    # (preserve_insertion_order stays on: without it COPY may write rows out of the ORDER BY order, and `addresses` reads
    # one street at a time.)
    # Valhalla level 1 (cache_places::schema::tile_id_l1): row * 360 + column, a point on an edge goes north-east.
    tile = "CAST(floor(ST_Y(geometry) + 90) * 360 + floor(ST_X(geometry) + 180) AS INTEGER)"

    t = time.time()
    c.execute(f"""
        COPY (
          SELECT id,
                 ST_AsHEXWKB(geometry) AS geometry,
                 names."primary" AS name,
                 basic_category,
                 confidence,
                 phones[1] AS phone,
                 websites[1] AS website,
                 array_to_string(socials, ';') AS socials,
                 brand.names."primary" AS brand_name,
                 brand.wikidata AS brand_wikidata,
                 list_filter(sources, x -> x.dataset = 'OpenStreetMap')[1].record_id[1:1] AS osm_type,
                 regexp_extract(list_filter(sources, x -> x.dataset = 'OpenStreetMap')[1].record_id, '^[nwr]?([0-9]+)', 1) AS osm_id,
                 sources[1].record_id AS source_record_id,
                 array_to_string(list_transform(sources, x -> x.dataset), ';') AS raw_sources,
                 taxonomy."primary" AS taxonomy_primary,
                 regexp_replace(addresses[1].freeform, '\\s+', ' ', 'g') AS street,
                 addresses[1].locality AS locality,
                 addresses[1].postcode AS postcode,
                 addresses[1].region AS region,
                 {tile} AS tile
          FROM read_parquet('{root}/theme=places/type=place/*')
          WHERE {box} AND coalesce(operating_status, '') <> 'permanently_closed'
          ORDER BY tile, id
        ) TO '{os.path.join(a.out, 'overture_places.csv')}' (HEADER, DELIMITER ',')
    """)
    print(f"places {c.execute(f"SELECT count(*) FROM read_csv('{os.path.join(a.out, 'overture_places.csv')}')").fetchone()[0]} in {time.time() - t:.0f} s", flush=True)

    t = time.time()
    c.execute(f"""
        COPY (
          SELECT category, path FROM (
            SELECT category, path, row_number() OVER (PARTITION BY category ORDER BY n DESC, path) AS r FROM (
              SELECT taxonomy."primary" AS category, array_to_string(taxonomy.hierarchy, ' > ') AS path, count(*) AS n
              FROM read_parquet('{root}/theme=places/type=place/*')
              WHERE taxonomy."primary" IS NOT NULL
              GROUP BY 1, 2))
          WHERE r = 1 ORDER BY category
        ) TO '{os.path.join(a.out, 'overture_taxonomy.tsv')}' (HEADER, DELIMITER '\t')
    """)
    print(f"taxonomy in {time.time() - t:.0f} s", flush=True)

    t = time.time()
    c.execute(f"""
        COPY (
          SELECT id, trim(number) AS number, regexp_replace(trim(street), '\\s+', ' ', 'g') AS street, unit, postcode, postal_city,
                 address_levels[1]."value" AS state, country,
                 round(ST_Y(geometry), 7) AS lat, round(ST_X(geometry), 7) AS lon,
                 {tile} AS tile
          FROM read_parquet('{root}/theme=addresses/type=address/*')
          WHERE {box} AND trim(coalesce(number, '')) <> '' AND trim(coalesce(street, '')) <> ''
          ORDER BY tile, street, postcode, postal_city, id
        ) TO '{os.path.join(a.out, 'overture_addresses.csv')}' (HEADER, DELIMITER ',')
    """)
    print(f"addresses {c.execute(f"SELECT count(*) FROM read_csv('{os.path.join(a.out, 'overture_addresses.csv')}')").fetchone()[0]} in {time.time() - t:.0f} s", flush=True)


if __name__ == "__main__":
    main()
