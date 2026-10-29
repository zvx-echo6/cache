//! Arrival points: where a route to a place goes when that is not the place's own point (project decision, 2026-10-29:
//! "match what Apple Maps does"). A route to an airport's centre ends on the airfield's service roads, and one to a park's
//! or campus's centre ends at whatever road is nearest the middle; people go to the terminal's curb, the main door, the
//! parking. Only the OSM data decides it, through the `arrival` rules of categories.json:
//!
//! 1. An airport (a place of one of `airport_kinds`): its passenger terminal, the terminal inside its outline (or within
//!    `airport_terminal_m` of a point airport) with the most public doors, then the largest. The point is the middle door
//!    of its main doors (of all its doors when none is marked main), else the terminal's centre. The doors line the curb, so
//!    the middle one is on the frontage road's side.
//! 2. A place with an outline and main doors on it: the main door nearest its point.
//! 3. A large area (outline at least `large_m` across: a park, a campus, a mall, a stadium) with neither: its largest public
//!    parking, inside the outline or within `adjacent_m` of it.
//!
//! Anything else has no arrival point; the router then snaps the place's point itself (cache_offroad's `snap`, which moves
//! an end off service roads to a public road nearby).
use crate::model::{Anchor, AnchorKind, Raw};
use crate::rules::{generic_kind_id, ArrivalCfg};
use cache_places::geo::haversine_km;
use std::collections::HashMap;

const M_PER_DEG: f64 = 111_320.0;
/// The anchor index's cell, in degrees (about 1.1 km of latitude).
const CELL: f64 = 0.01;

/// How many places got an arrival point, by rule.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ArrivalReport {
    pub terminal: usize,
    pub entrance: usize,
    pub parking: usize,
}

impl ArrivalReport {
    pub fn total(&self) -> usize {
        self.terminal + self.entrance + self.parking
    }
}

fn metres(a: (f64, f64), b: (f64, f64)) -> f64 {
    haversine_km(a.0, a.1, b.0, b.1) * 1000.0
}

/// The box [south, west, north, east] grown by `m` metres on every side.
fn grow(b: [f64; 4], m: f64) -> [f64; 4] {
    let dlat = m / M_PER_DEG;
    let dlon = m / (M_PER_DEG * ((b[0] + b[2]) / 2.0).to_radians().cos().max(0.01));
    [b[0] - dlat, b[1] - dlon, b[2] + dlat, b[3] + dlon]
}

fn inside(lat: f64, lon: f64, b: &[f64; 4]) -> bool {
    b[0] <= lat && lat <= b[2] && b[1] <= lon && lon <= b[3]
}

/// The box's diagonal in metres.
fn across(b: &[f64; 4]) -> f64 {
    metres((b[0], b[1]), (b[2], b[3]))
}

/// The box's area in square metres.
fn area(b: &[f64; 4]) -> f64 {
    let h = (b[2] - b[0]) * M_PER_DEG;
    let w = (b[3] - b[1]) * M_PER_DEG * ((b[0] + b[2]) / 2.0).to_radians().cos();
    h.max(0.0) * w.max(0.0)
}

/// The anchors of one kind by 0.01 degree cell.
struct Index<'a> {
    anchors: &'a [Anchor],
    cells: HashMap<(i32, i32), Vec<usize>>,
}

impl<'a> Index<'a> {
    fn new(anchors: &'a [Anchor], keep: impl Fn(AnchorKind) -> bool) -> Index<'a> {
        let mut cells: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (i, a) in anchors.iter().enumerate() {
            if keep(a.kind) {
                cells.entry(Self::key(a.lat, a.lon)).or_default().push(i);
            }
        }
        Index { anchors, cells }
    }
    fn key(lat: f64, lon: f64) -> (i32, i32) {
        ((lat / CELL).floor() as i32, (lon / CELL).floor() as i32)
    }
    /// The anchors whose points are inside the box.
    fn within(&self, b: &[f64; 4]) -> Vec<&'a Anchor> {
        let (r0, c0) = Self::key(b[0], b[1]);
        let (r1, c1) = Self::key(b[2], b[3]);
        let mut out = Vec::new();
        for r in r0..=r1 {
            for c in c0..=c1 {
                for &i in self.cells.get(&(r, c)).into_iter().flatten() {
                    let a = &self.anchors[i];
                    if inside(a.lat, a.lon, b) {
                        out.push(a);
                    }
                }
            }
        }
        out
    }
}

/// The door in the middle of a row of doors: the one with the least distance to all the others.
fn middle(doors: &[&Anchor]) -> Option<(f64, f64)> {
    doors
        .iter()
        .map(|d| (doors.iter().map(|o| metres((d.lat, d.lon), (o.lat, o.lon))).sum::<f64>(), (d.lat, d.lon)))
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .map(|x| x.1)
}

fn is_main(a: &Anchor) -> bool {
    a.kind == AnchorKind::MainEntrance
}

/// Gives the places their arrival points (see the module notes). A place that already has one keeps it.
pub fn assign(rows: &mut [Raw], anchors: &[Anchor], cfg: &ArrivalCfg) -> ArrivalReport {
    let mut rep = ArrivalReport::default();
    if anchors.is_empty() {
        return rep;
    }
    let terminals = Index::new(anchors, |k| k == AnchorKind::Terminal);
    let doors = Index::new(anchors, |k| matches!(k, AnchorKind::Entrance | AnchorKind::MainEntrance));
    let parking = Index::new(anchors, |k| k == AnchorKind::Parking);
    for r in rows.iter_mut() {
        if r.arrival.is_some() {
            continue;
        }
        let here = (r.lat, r.lon);
        let kind = r.kind_id.clone().unwrap_or_else(|| generic_kind_id(&r.kind));
        let mut got: Option<((f64, f64), usize)> = None;
        if cfg.airport_kinds.iter().any(|k| *k == kind) {
            let region = match r.extent {
                Some(e) => grow(e, cfg.adjacent_m),
                None => grow([r.lat, r.lon, r.lat, r.lon], cfg.airport_terminal_m),
            };
            let near = |t: &&Anchor| r.extent.is_some() || metres(here, (t.lat, t.lon)) <= cfg.airport_terminal_m;
            let best = terminals
                .within(&region)
                .into_iter()
                .filter(near)
                .map(|t| (t, doors.within(&grow(t.extent, cfg.outline_m))))
                .max_by(|a, b| (a.1.len(), area(&a.0.extent)).partial_cmp(&(b.1.len(), area(&b.0.extent))).unwrap_or(std::cmp::Ordering::Equal));
            if let Some((t, ds)) = best {
                let main: Vec<&Anchor> = ds.iter().copied().filter(|d| is_main(d)).collect();
                let p = middle(if main.is_empty() { &ds } else { &main }).unwrap_or((t.lat, t.lon));
                got = Some((p, 0));
            }
        }
        if got.is_none() {
            if let Some(e) = r.extent {
                let main = doors.within(&grow(e, cfg.outline_m)).into_iter().filter(|d| is_main(d));
                if let Some(d) = main.min_by(|a, b| metres(here, (a.lat, a.lon)).total_cmp(&metres(here, (b.lat, b.lon)))) {
                    got = Some(((d.lat, d.lon), 1));
                } else if cfg.large_m > 0.0 && across(&e) >= cfg.large_m {
                    let lots = parking.within(&grow(e, cfg.adjacent_m));
                    let best = lots.into_iter().max_by(|a, b| {
                        area(&a.extent).total_cmp(&area(&b.extent)).then_with(|| metres(here, (b.lat, b.lon)).total_cmp(&metres(here, (a.lat, a.lon))))
                    });
                    if let Some(l) = best {
                        got = Some(((l.lat, l.lon), 2));
                    }
                }
            }
        }
        if let Some((p, rule)) = got {
            if metres(here, p) < 1.0 {
                continue;
            }
            r.arrival = Some(p);
            match rule {
                0 => rep.terminal += 1,
                1 => rep.entrance += 1,
                _ => rep.parking += 1,
            }
        }
    }
    rep
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Wiki;
    use crate::rules::Rules;

    fn cfg() -> ArrivalCfg {
        Rules::parse(include_str!("../categories.json")).unwrap().arrival
    }

    fn place(kind: &str, lat: f64, lon: f64, extent: Option<[f64; 4]>) -> Raw {
        Raw {
            source: "osm",
            source_id: "osm:w1".into(),
            name: Some("Test".into()),
            alt: vec![],
            category: None,
            kind: kind.into(),
            kind_id: None,
            lat,
            lon,
            street: None,
            city: None,
            phone: None,
            hours: None,
            website: None,
            confidence: None,
            wiki: Wiki::default(),
            brand_wikidata: None,
            enrich: None,
            matched: None,
            extent,
            arrival: None,
        }
    }

    fn pt(kind: AnchorKind, lat: f64, lon: f64) -> Anchor {
        Anchor { kind, lat, lon, extent: [lat, lon, lat, lon] }
    }

    fn area_anchor(kind: AnchorKind, b: [f64; 4]) -> Anchor {
        Anchor { kind, lat: (b[0] + b[2]) / 2.0, lon: (b[1] + b[3]) / 2.0, extent: b }
    }

    /// Salt Lake City's airport, shaped like the OSM data: the aerodrome's outline, the landside terminal with its row of
    /// public doors along Terminal Drive, two larger concourses with none, and a door on another building.
    fn slc() -> (Raw, Vec<Anchor>) {
        let airport = place("aeroway=aerodrome", 40.7880, -111.9780, Some([40.75, -112.02, 40.82, -111.94]));
        let terminal = area_anchor(AnchorKind::Terminal, [40.7832, -111.9880, 40.7846, -111.9835]);
        let concourse_a = area_anchor(AnchorKind::Terminal, [40.7850, -112.0050, 40.7870, -111.9890]);
        let concourse_b = area_anchor(AnchorKind::Terminal, [40.7880, -112.0050, 40.7900, -111.9890]);
        let mut anchors = vec![terminal, concourse_a, concourse_b];
        for lon in [-111.9858, -111.9854, -111.9849, -111.9844, -111.9840] {
            anchors.push(pt(AnchorKind::Entrance, 40.7841, lon));
        }
        anchors.push(pt(AnchorKind::MainEntrance, 40.7709, -112.0067));
        (airport, anchors)
    }

    #[test]
    fn an_airport_arrives_at_its_passenger_terminals_curb() {
        let (airport, anchors) = slc();
        let mut rows = vec![airport];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep, ArrivalReport { terminal: 1, entrance: 0, parking: 0 });
        assert_eq!(rows[0].arrival, Some((40.7841, -111.9849)), "the middle door of the terminal's row, not a concourse");
    }

    #[test]
    fn a_point_airport_takes_a_terminal_nearby_and_not_one_far_away() {
        // Boise's airport is a point in the data (Overture); its terminal is 1.2 km off, another airport's 8 km.
        let mut rows = vec![place("airport", 43.5644, -116.2228, None)];
        let anchors = vec![area_anchor(AnchorKind::Terminal, [43.5640, -116.2240, 43.5650, -116.2210]), area_anchor(AnchorKind::Terminal, [43.6300, -116.2300, 43.6310, -116.2290])];
        let mut moved = rows.clone();
        moved[0].lat -= 0.011; // 1.2 km south of the terminal
        assign(&mut moved, &anchors, &cfg());
        let (la, lo) = moved[0].arrival.expect("the terminal");
        assert!((la - 43.5645).abs() < 1e-9 && (lo + 116.2225).abs() < 1e-9, "no doors: the terminal's centre");
        rows[0].lat = 43.70;
        assert_eq!(assign(&mut rows, &anchors, &cfg()).total(), 0, "nothing within 3 km");
    }

    #[test]
    fn a_building_arrives_at_its_main_door() {
        let mut rows = vec![place("amenity=hospital", 40.7700, -111.8400, Some([40.7690, -111.8410, 40.7710, -111.8390]))];
        let anchors = vec![
            pt(AnchorKind::Entrance, 40.7710, -111.8400),
            pt(AnchorKind::MainEntrance, 40.7690, -111.8395),
            pt(AnchorKind::MainEntrance, 40.7750, -111.8400),
        ];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep.entrance, 1);
        assert_eq!(rows[0].arrival, Some((40.7690, -111.8395)), "the main door on its outline, not one on another building");
    }

    #[test]
    fn a_large_area_arrives_at_its_largest_parking_and_a_small_one_at_none() {
        // A park about 900 m across with two lots and one across town.
        let park = place("leisure=park", 40.7230, -111.8480, Some([40.7190, -111.8530, 40.7270, -111.8430]));
        let anchors = vec![
            area_anchor(AnchorKind::Parking, [40.7195, -111.8470, 40.7199, -111.8460]),
            area_anchor(AnchorKind::Parking, [40.7260, -111.8520, 40.7268, -111.8500]),
            area_anchor(AnchorKind::Parking, [40.7400, -111.8700, 40.7420, -111.8600]),
        ];
        let small = place("amenity=cafe", 40.7230, -111.8480, Some([40.7229, -111.8481, 40.7231, -111.8479]));
        let mut rows = vec![park, small];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep.parking, 1);
        assert_eq!(rows[0].arrival, Some((40.7264, -111.8510)));
        assert_eq!(rows[1].arrival, None, "a small place with no main door has no arrival point");
    }

    #[test]
    fn points_and_rules_without_arrival_give_none() {
        let (mut airport, anchors) = slc();
        airport.kind = "amenity=cafe".into();
        airport.extent = None;
        let mut rows = vec![airport];
        assert_eq!(assign(&mut rows, &anchors, &cfg()).total(), 0, "a point that is no airport");
        // Rules with no arrival section pick out no anchors, so nothing gets an arrival point.
        assert_eq!(ArrivalCfg::default().anchor(&[("aeroway", "terminal")]), None);
        assert_eq!(ArrivalCfg::default().anchor(&[("entrance", "main")]), None);
        let (airport, _) = slc();
        let mut rows = vec![airport];
        assert_eq!(assign(&mut rows, &[], &cfg()).total(), 0);
    }
}
