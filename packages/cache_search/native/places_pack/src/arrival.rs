//! Arrival points: where a route to a place goes when that is not the place's own point (project decision, 2026-10-29:
//! "match what Apple Maps does"). A route to an airport's centre ends on the airfield's service roads, and one to a park's
//! or campus's centre ends at whatever road is nearest the middle; people go to the terminal's curb, the main door, the
//! parking. Only the OSM data decides it, through the `arrival` rules of categories.json:
//!
//! 0. A hospital or emergency room (a place of one of `emergency_categories`): its emergency entrance (an `emergency_entrance`
//!    anchor) nearest its point, inside its outline or within `adjacent_m` of it (within `emergency_entrance_m` of a point
//!    place, 150 m); else its main door, the same way; else the rules below.
//! 1. An airport (a place of one of `airport_kinds`): its passenger terminal, among the terminals inside its outline (or
//!    within `airport_terminal_m` of a point airport) the one people reach from the car: one with public doors, then the one
//!    nearest public parking (concourses are airside, far from it), then the most doors, then the largest. The point is the
//!    middle door of its main doors (of all its doors when none is marked main), else the terminal's centre. The doors line
//!    the curb, so the middle one is on the frontage road's side.
//! 2. A large area (outline at least `large_m` across: a park, a campus, a mall, a stadium): the public parking nearest its
//!    point, inside the outline or within `adjacent_m` of it. (The main doors inside a campus's outline are its buildings'.)
//! 3. Any other place with an outline and main doors on it (a large building with no parking too): the main door nearest
//!    its point.
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
/// How far from a terminal its nearest parking is looked for.
const PARKING_SEARCH_M: f64 = 1000.0;

/// How many places got an arrival point, by rule.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ArrivalReport {
    pub emergency: usize,
    pub terminal: usize,
    pub entrance: usize,
    pub parking: usize,
}

impl ArrivalReport {
    pub fn total(&self) -> usize {
        self.emergency + self.terminal + self.entrance + self.parking
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

/// The anchors within `reach` metres of `here`.
fn within_reach<'a>(xs: Vec<&'a Anchor>, here: (f64, f64), reach: f64) -> Vec<&'a Anchor> {
    xs.into_iter().filter(|a| metres(here, (a.lat, a.lon)) <= reach).collect()
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
    let emergency = Index::new(anchors, |k| k == AnchorKind::EmergencyEntrance);
    for r in rows.iter_mut() {
        if r.arrival.is_some() {
            continue;
        }
        let here = (r.lat, r.lon);
        let kind = r.kind_id.clone().unwrap_or_else(|| generic_kind_id(&r.kind));
        let mut got: Option<((f64, f64), usize)> = None;
        let nearest = |xs: Vec<&Anchor>| xs.into_iter().min_by(|a, b| metres(here, (a.lat, a.lon)).total_cmp(&metres(here, (b.lat, b.lon)))).map(|a| (a.lat, a.lon));
        if r.category.as_ref().is_some_and(|c| cfg.emergency_categories.contains(c)) {
            // Its own area, or around a point; a point's anchors must be within emergency_entrance_m.
            let (region, reach) = match r.extent {
                Some(e) => (grow(e, cfg.adjacent_m), f64::INFINITY),
                None => (grow([r.lat, r.lon, r.lat, r.lon], cfg.emergency_entrance_m), cfg.emergency_entrance_m),
            };
            got = nearest(within_reach(emergency.within(&region), here, reach)).map(|p| (p, 3));
            if got.is_none() {
                let main = doors.within(&region).into_iter().filter(|d| is_main(d)).collect();
                got = nearest(within_reach(main, here, reach)).map(|p| (p, 1));
            }
        }
        if got.is_none() && cfg.airport_kinds.iter().any(|k| *k == kind) {
            let region = match r.extent {
                Some(e) => grow(e, cfg.adjacent_m),
                None => grow([r.lat, r.lon, r.lat, r.lon], cfg.airport_terminal_m),
            };
            let near = |t: &&Anchor| r.extent.is_some() || metres(here, (t.lat, t.lon)) <= cfg.airport_terminal_m;
            // The nearest public parking to a terminal, within PARKING_SEARCH_M (farther counts as none).
            let to_parking = |t: &Anchor| {
                parking.within(&grow(t.extent, PARKING_SEARCH_M)).iter().map(|p| metres((t.lat, t.lon), (p.lat, p.lon))).fold(PARKING_SEARCH_M * 2.0, f64::min)
            };
            let best = terminals
                .within(&region)
                .into_iter()
                .filter(near)
                .map(|t| (t, doors.within(&grow(t.extent, cfg.outline_m)), to_parking(t)))
                .min_by(|a, b| {
                    (a.1.is_empty(), a.2, std::cmp::Reverse(a.1.len()))
                        .partial_cmp(&(b.1.is_empty(), b.2, std::cmp::Reverse(b.1.len())))
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then_with(|| area(&b.0.extent).total_cmp(&area(&a.0.extent)))
                });
            if let Some((t, ds, _)) = best {
                let main: Vec<&Anchor> = ds.iter().copied().filter(|d| is_main(d)).collect();
                let p = middle(if main.is_empty() { &ds } else { &main }).unwrap_or((t.lat, t.lon));
                got = Some((p, 0));
            }
        }
        if got.is_none() {
            if let Some(e) = r.extent {
                if cfg.large_m > 0.0 && across(&e) >= cfg.large_m {
                    got = nearest(parking.within(&grow(e, cfg.adjacent_m))).map(|p| (p, 2));
                }
                if got.is_none() {
                    got = nearest(doors.within(&grow(e, cfg.outline_m)).into_iter().filter(|d| is_main(d)).collect()).map(|p| (p, 1));
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
                3 => rep.emergency += 1,
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
    /// public doors along Terminal Drive and the garage across the road, concourse A with no doors, concourse B (larger, far
    /// from the garage) with as many doors as the terminal, and a main door on another building.
    fn slc() -> (Raw, Vec<Anchor>) {
        let airport = place("aeroway=aerodrome", 40.7880, -111.9780, Some([40.75, -112.02, 40.82, -111.94]));
        let terminal = area_anchor(AnchorKind::Terminal, [40.7840, -111.9871, 40.7853, -111.9838]);
        let concourse_a = area_anchor(AnchorKind::Terminal, [40.7850, -111.9922, 40.7863, -111.9789]);
        let concourse_b = area_anchor(AnchorKind::Terminal, [40.7885, -111.9916, 40.7900, -111.9788]);
        let mut anchors = vec![terminal, concourse_a, concourse_b, area_anchor(AnchorKind::Parking, [40.7815, -111.9870, 40.7830, -111.9830])];
        for lon in [-111.9858, -111.9854, -111.9849, -111.9844, -111.9840] {
            anchors.push(pt(AnchorKind::Entrance, 40.7841, lon));
        }
        for lon in [-111.9875, -111.9868, -111.9860, -111.9849, -111.9842] {
            anchors.push(pt(AnchorKind::Entrance, 40.7890, lon));
        }
        anchors.push(pt(AnchorKind::MainEntrance, 40.7709, -112.0067));
        (airport, anchors)
    }

    #[test]
    fn an_airport_arrives_at_its_passenger_terminals_curb() {
        let (airport, anchors) = slc();
        let mut rows = vec![airport];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep, ArrivalReport { emergency: 0, terminal: 1, entrance: 0, parking: 0 });
        assert_eq!(rows[0].arrival, Some((40.7841, -111.9849)), "the middle door of the terminal's row, not concourse B's");
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

    fn hospital(cat: &str, lat: f64, lon: f64, extent: Option<[f64; 4]>) -> Raw {
        let mut r = place("amenity=hospital", lat, lon, extent);
        r.category = Some(cat.into());
        r
    }

    #[test]
    fn a_hospital_arrives_at_its_emergency_entrance_then_its_main_door() {
        // A hospital site about 400 m across (large: it would otherwise take its parking) with an emergency entrance, a
        // main door and a lot; another hospital's emergency entrance 1 km away.
        let site = [40.7690, -111.8430, 40.7720, -111.8390];
        let anchors = vec![
            pt(AnchorKind::EmergencyEntrance, 40.7712, -111.8395),
            pt(AnchorKind::MainEntrance, 40.7700, -111.8410),
            area_anchor(AnchorKind::Parking, [40.7701, -111.8420, 40.7705, -111.8415]),
            pt(AnchorKind::EmergencyEntrance, 40.7800, -111.8410),
        ];
        let mut rows = vec![hospital("hospital", 40.7703, -111.8411, Some(site))];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep.emergency, 1);
        assert_eq!(rows[0].arrival, Some((40.7712, -111.8395)), "the emergency entrance, not the nearer main door or the parking");
        // An emergency room listed as a point 120 m from its entrance takes it too; one 600 m away does not.
        let mut er = vec![hospital("emergency_room", 40.7702, -111.8400, None), hospital("emergency_room", 40.7660, -111.8400, None)];
        assign(&mut er, &anchors, &cfg());
        assert_eq!(er[0].arrival, Some((40.7712, -111.8395)));
        assert_eq!(er[1].arrival, None, "nothing within 150 m");
        // A point hospital 190 m from its neighbour's emergency entrance takes its own main door instead.
        let mut own = anchors.clone();
        own.push(pt(AnchorKind::MainEntrance, 40.7731, -111.8393));
        let mut next_door = vec![hospital("hospital", 40.7729, -111.8395, None)];
        let rep = assign(&mut next_door, &own, &cfg());
        assert_eq!((rep.emergency, next_door[0].arrival), (0, Some((40.7731, -111.8393))));
        // No emergency entrance: the main door, not the parking.
        let mut rows = vec![hospital("hospital", 40.7703, -111.8411, Some(site))];
        let rep = assign(&mut rows, &anchors[1..3], &cfg());
        assert_eq!((rep.emergency, rep.entrance, rows[0].arrival), (0, 1, Some((40.7700, -111.8410))));
        // Neither: the existing rules (a large site's parking).
        let mut rows = vec![hospital("hospital", 40.7703, -111.8411, Some(site))];
        let rep = assign(&mut rows, &anchors[2..3], &cfg());
        assert_eq!(rep.parking, 1);
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
    fn a_large_area_arrives_at_its_nearest_parking_and_a_small_one_at_none() {
        // A park about 900 m across with two lots (390 m and 450 m from its point), a main door of a building inside it, and a
        // lot across town.
        let park = place("leisure=park", 40.7230, -111.8480, Some([40.7190, -111.8530, 40.7270, -111.8430]));
        let anchors = vec![
            area_anchor(AnchorKind::Parking, [40.7195, -111.8470, 40.7199, -111.8460]),
            area_anchor(AnchorKind::Parking, [40.7260, -111.8520, 40.7268, -111.8500]),
            area_anchor(AnchorKind::Parking, [40.7400, -111.8700, 40.7420, -111.8600]),
            pt(AnchorKind::MainEntrance, 40.7231, -111.8481),
        ];
        let small = place("amenity=cafe", 40.7230, -111.8480, Some([40.7229, -111.8481, 40.7231, -111.8479]));
        let mut rows = vec![park, small];
        let rep = assign(&mut rows, &anchors, &cfg());
        assert_eq!(rep.parking, 1);
        let (la, lo) = rows[0].arrival.unwrap();
        assert!((la - 40.7197).abs() < 1e-9 && (lo + 111.8465).abs() < 1e-9, "the nearer lot, not the building's door: {la},{lo}");
        assert_eq!(rows[1].arrival, Some((40.7231, -111.8481)), "a small place takes a main door on it");
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
