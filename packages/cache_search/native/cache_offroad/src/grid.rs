//! Grid geometry: a faithful port of navi's `shared/dem.py` (`grid_window` and the metadata
//! `DEMReader.get_elevation_grid` builds). The pack stores every layer on the global z12 pixel
//! grid (512-px tiles, 2^21 pixels around the world); a query grid is a window of it.
//!
//! navi assigns the stitched window a *linear* lat/lon georeference (`pixel_size_lat` is the
//! tile-range span divided by the pixel count, although z12 rows are Web-Mercator). This port keeps
//! that georeference for all pixel<->lat/lon conversions so output coordinates and endpoint
//! snapping behave as in navi.

pub const TILE_SIZE: i64 = 512;
pub const ZOOM: i32 = 12;
/// Pack tile edge (cells). Two pack tiles per DEM tile edge.
pub const PACK_TILE: i64 = 256;

pub fn lat_lon_to_tile(lat: f64, lon: f64, zoom: i32) -> (i64, i64) {
    let n = (1i64 << zoom) as f64;
    let x = ((lon + 180.0) / 360.0 * n) as i64;
    let lat_rad = lat.to_radians();
    let y = ((1.0 - lat_rad.tan().asinh() / std::f64::consts::PI) / 2.0 * n) as i64;
    (x, y)
}

/// (north, south, west, east)
pub fn tile_to_lat_lon(x: i64, y: i64, zoom: i32) -> (f64, f64, f64, f64) {
    let n = (1i64 << zoom) as f64;
    let pi = std::f64::consts::PI;
    let lon_west = x as f64 / n * 360.0 - 180.0;
    let lon_east = (x + 1) as f64 / n * 360.0 - 180.0;
    let lat_north = (pi * (1.0 - 2.0 * y as f64 / n)).sinh().atan().to_degrees();
    let lat_south = (pi * (1.0 - 2.0 * (y + 1) as f64 / n)).sinh().atan().to_degrees();
    (lat_north, lat_south, lon_west, lon_east)
}

#[derive(Debug, Clone)]
pub struct GridWindow {
    pub x_min: i64,
    pub x_max: i64,
    pub y_min: i64,
    pub y_max: i64,
    pub out_height: i64,
    pub out_width: i64,
    pub row_start: i64,
    pub row_end: i64,
    pub col_start: i64,
    pub col_end: i64,
    pub grid_north: f64,
    pub grid_south: f64,
    pub grid_west: f64,
    pub grid_east: f64,
    pub pixel_size_lat: f64,
    pub pixel_size_lon: f64,
}

pub fn grid_window(south: f64, north: f64, west: f64, east: f64, zoom: i32) -> GridWindow {
    let (mut x_min, mut y_max) = lat_lon_to_tile(south, west, zoom);
    let (mut x_max, mut y_min) = lat_lon_to_tile(north, east, zoom);
    let n = 1i64 << zoom;
    x_min = x_min.max(0);
    x_max = x_max.min(n - 1);
    y_min = y_min.max(0);
    y_max = y_max.min(n - 1);

    let n_tiles_x = x_max - x_min + 1;
    let n_tiles_y = y_max - y_min + 1;
    let out_height = n_tiles_y * TILE_SIZE;
    let out_width = n_tiles_x * TILE_SIZE;

    let (grid_north, _, grid_west, _) = tile_to_lat_lon(x_min, y_min, zoom);
    let (_, grid_south, _, grid_east) = tile_to_lat_lon(x_max, y_max, zoom);

    let pixel_size_lat = (grid_north - grid_south) / out_height as f64;
    let pixel_size_lon = (grid_east - grid_west) / out_width as f64;

    // Python int() truncates toward zero, like `as i64`.
    let mut row_start = ((grid_north - north) / pixel_size_lat.abs()) as i64;
    let mut row_end = ((grid_north - south) / pixel_size_lat.abs()) as i64;
    let mut col_start = ((west - grid_west) / pixel_size_lon) as i64;
    let mut col_end = ((east - grid_west) / pixel_size_lon) as i64;

    row_start = row_start.max(0);
    row_end = row_end.min(out_height);
    col_start = col_start.max(0);
    col_end = col_end.min(out_width);

    GridWindow {
        x_min, x_max, y_min, y_max, out_height, out_width, row_start, row_end, col_start, col_end,
        grid_north, grid_south, grid_west, grid_east, pixel_size_lat, pixel_size_lon,
    }
}

/// Metadata of one query grid (`DEMReader.get_elevation_grid`'s `metadata` dict plus the position of
/// the window in the global pixel grid).
#[derive(Debug, Clone)]
pub struct GridMeta {
    /// (south, north, west, east) of the requested bbox.
    pub bounds: (f64, f64, f64, f64),
    /// Negative (north to south).
    pub pixel_size_lat: f64,
    pub pixel_size_lon: f64,
    pub origin_lat: f64,
    pub origin_lon: f64,
    pub cell_size_m: f64,
    pub rows: usize,
    pub cols: usize,
    /// Global z12 pixel row/col of cell (0,0).
    pub global_row0: i64,
    pub global_col0: i64,
}

impl GridMeta {
    pub fn from_bbox(south: f64, north: f64, west: f64, east: f64) -> GridMeta {
        let w = grid_window(south, north, west, east, ZOOM);
        let center_lat = (south + north) / 2.0;
        let lat_m = 111320.0;
        let lon_m = 111320.0 * center_lat.to_radians().cos();
        let cell_size_lat_m = w.pixel_size_lat.abs() * lat_m;
        let cell_size_lon_m = w.pixel_size_lon.abs() * lon_m;
        let cell_size_m = (cell_size_lat_m + cell_size_lon_m) / 2.0;
        let rows = (w.row_end - w.row_start).max(0) as usize;
        let cols = (w.col_end - w.col_start).max(0) as usize;
        GridMeta {
            bounds: (south, north, west, east),
            pixel_size_lat: -w.pixel_size_lat.abs(),
            pixel_size_lon: w.pixel_size_lon,
            origin_lat: w.grid_north - (w.row_start as f64 + 0.5) * w.pixel_size_lat.abs(),
            origin_lon: w.grid_west + (w.col_start as f64 + 0.5) * w.pixel_size_lon,
            cell_size_m,
            rows,
            cols,
            global_row0: w.y_min * TILE_SIZE + w.row_start,
            global_col0: w.x_min * TILE_SIZE + w.col_start,
        }
    }

    /// Cell count a bbox would produce (`estimate_grid_shape`), no I/O.
    pub fn estimate_shape(south: f64, north: f64, west: f64, east: f64) -> (usize, usize) {
        let w = grid_window(south, north, west, east, ZOOM);
        ((w.row_end - w.row_start).max(0) as usize, (w.col_end - w.col_start).max(0) as usize)
    }

    pub fn pixel_to_latlon(&self, row: i64, col: i64) -> (f64, f64) {
        (
            self.origin_lat + row as f64 * self.pixel_size_lat,
            self.origin_lon + col as f64 * self.pixel_size_lon,
        )
    }

    /// `DEMReader.latlon_to_pixel` (truncating int()).
    pub fn latlon_to_pixel(&self, lat: f64, lon: f64) -> (i64, i64) {
        (
            ((self.origin_lat - lat) / self.pixel_size_lat.abs()) as i64,
            ((lon - self.origin_lon) / self.pixel_size_lon) as i64,
        )
    }

    /// `transitions._latlon_to_pixel`: same, with the +1e-6 round-trip stabiliser.
    pub fn latlon_to_pixel_eps(&self, lat: f64, lon: f64) -> (i64, i64) {
        (
            ((self.origin_lat - lat) / self.pixel_size_lat.abs() + 1e-6) as i64,
            ((lon - self.origin_lon) / self.pixel_size_lon + 1e-6) as i64,
        )
    }

    /// A synthetic linear grid for tests (no relation to the z12 pixel grid).
    pub fn synthetic(rows: usize, cols: usize, south: f64, west: f64, cell_m: f64) -> GridMeta {
        let dlat = cell_m / 111000.0;
        let dlon = cell_m / (111000.0 * south.to_radians().cos());
        GridMeta {
            bounds: (south, south + rows as f64 * dlat, west, west + cols as f64 * dlon),
            pixel_size_lat: -dlat,
            pixel_size_lon: dlon,
            origin_lat: south + rows as f64 * dlat,
            origin_lon: west,
            cell_size_m: cell_m,
            rows,
            cols,
            global_row0: 0,
            global_col0: 0,
        }
    }
}

/// z12 pixel (global row, col) of a lat/lon, as `DEMReader.sample_point` does it.
pub fn global_pixel(lat: f64, lon: f64) -> Option<(i64, i64)> {
    if !(-85.05112878..=85.05112878).contains(&lat) {
        return None;
    }
    let n = (1i64 << ZOOM) as f64;
    let fx = (lon + 180.0) / 360.0 * n;
    let fy = (1.0 - lat.to_radians().tan().asinh() / std::f64::consts::PI) / 2.0 * n;
    let (tx, ty) = (fx as i64, fy as i64);
    let row = (TILE_SIZE - 1).min(((fy - ty as f64) * TILE_SIZE as f64) as i64);
    let col = (TILE_SIZE - 1).min(((fx - tx as f64) * TILE_SIZE as f64) as i64);
    Some((ty * TILE_SIZE + row, tx * TILE_SIZE + col))
}

pub fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let r = 6371000.0;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2) + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    r * c
}
