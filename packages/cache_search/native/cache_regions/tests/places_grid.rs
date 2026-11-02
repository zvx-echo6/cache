//! cache_places keeps its own copy of the level 1 grid (places tiles are cut on it); it must agree with this crate's.

use cache_places::schema::{parse_tile_path_l1, tile_id_l1, tile_path_l1, tile_rect_l1};
use cache_regions::geo::{parse_tile_path, tile_id, tile_path, tile_rect};

#[test]
fn places_level_1_tiles_are_valhallas() {
    // Every whole and half degree across the world, the edges and a bit beyond them, and points a hair either side of an edge.
    let mut lats: Vec<f64> = (-182..=182).map(|i| i as f64 * 0.5).collect();
    let mut lons: Vec<f64> = (-362..=362).map(|i| i as f64 * 0.5).collect();
    for v in [40.0, -111.0, 0.0] {
        lats.extend([v - 1e-9, v + 1e-9]);
        lons.extend([v - 1e-9, v + 1e-9]);
    }
    for &lat in &lats {
        for &lon in &lons {
            let t = tile_id_l1(lat, lon);
            assert_eq!(t as u64, tile_id(1, lon, lat), "{lat},{lon}");
        }
    }
    for t in (0u32..64800).step_by(7).chain([64799]) {
        assert_eq!(tile_path_l1(t), tile_path(1, t as u64));
        assert_eq!(tile_rect_l1(t), tile_rect(1, t as u64));
        assert_eq!(parse_tile_path_l1(&tile_path_l1(t)), parse_tile_path(&tile_path(1, t as u64)).map(|(_, id)| id as u32));
    }
}
