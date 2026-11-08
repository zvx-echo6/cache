//! Resolution: the same answer on every device, a pure function of all the events and the libraries' facts. See
//! server/builder/LIBRARY-LOG.md ("Resolution").
//!
//! Events are ordered by (`at`, `dev`), then by position, so the answer does not depend on the order the files are read in (the
//! position only orders two events of one device with the same `at`, and one device's file keeps its line order).

use crate::events::{By, FactFields, FolderMode, Kind, CALL_PREFIX};
use crate::library::{LibraryInput, SuggestedDiv};
use crate::quality::{compare_copies, CopyQuality};
use crate::events::Event;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// A call number: `CDS 210-002`, or `CDS 210-002.1` for the second claim on the number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub div: String,
    pub seq: u32,
    /// 0 for the first claim on (div, seq); k for the k-th later one.
    pub suffix: u32,
    pub text: String,
}

/// `CDS ` + div + `-` + the sequence in 3 digits (wider past 999) + `.k` when `suffix` is above 0.
pub fn call_text(div: &str, seq: u32, suffix: u32) -> String {
    if suffix > 0 {
        format!("{CALL_PREFIX} {div}-{seq:03}.{suffix}")
    } else {
        format!("{CALL_PREFIX} {div}-{seq:03}")
    }
}

/// An active place a copy was found in a linked folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    pub dev: String,
    pub folder_id: String,
    pub relpath: String,
    pub version: Option<u32>,
    pub source_blake3: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderState {
    pub dev: String,
    pub folder_id: String,
    pub label: String,
    pub mode: FolderMode,
}

/// One copy of a book.
#[derive(Debug, Clone, PartialEq)]
pub struct CopyView {
    pub copy: String,
    /// `<library_id>/<doc_id>` of every library that holds it, sorted. Empty when no library given holds it.
    pub locs: Vec<String>,
    /// The pack's title; `None` when no library given holds the copy.
    pub title: Option<String>,
    /// The call number this copy holds on its own (held quietly while it is in a book with an earlier number).
    pub own_call: Option<Call>,
    pub locations: Vec<Location>,
}

impl CopyView {
    pub fn available(&self) -> bool {
        !self.locs.is_empty()
    }
}

/// Where the book's title came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TitleFrom {
    /// A `title` event of the person's Bookshelves log.
    Log,
    /// The publisher's seed-log `title`.
    Seed,
    /// The reading copy's pack title.
    Pack,
}

impl TitleFrom {
    pub fn as_str(self) -> &'static str {
        match self {
            TitleFrom::Log => "log",
            TitleFrom::Seed => "seed",
            TitleFrom::Pack => "pack",
        }
    }
}

/// A suggested division, shown until the person shelves the book.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Suggest {
    pub div: String,
    pub label: Option<String>,
    /// `seed` (a published library's seed log) or `pack` (the pack's `book.suggested`).
    pub from: &'static str,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Book {
    /// The smallest copy key of the book (changes when books merge or split).
    pub id: String,
    pub copies: Vec<CopyView>,
    /// The copy to read: `prefer`, else the best by the samebook order.
    pub reading: String,
    pub shelf: Option<String>,
    /// Some event has placed or unsorted it.
    pub shelved: bool,
    pub by: Option<By>,
    pub call: Option<Call>,
    pub title: String,
    pub title_from: TitleFrom,
    /// Other copies' differing pack titles.
    pub aka: Vec<String>,
    pub removed: bool,
    pub suggested: Option<Suggest>,
    /// Per field: the person's own `facts`, else the publisher's seed-log `facts`, else the pack's `book` block (the reading copy's).
    pub author: Option<String>,
    pub edition: Option<String>,
    pub year: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Resolved {
    /// Books with at least one copy in a given library, by `id`.
    pub books: Vec<Book>,
    /// For each division, the numbers that were retired.
    pub retired: BTreeMap<String, BTreeSet<u32>>,
    /// For each division with any number, the next free one: 1 + the highest ever assigned or retired, over every device's log.
    pub next: BTreeMap<String, u32>,
    pub folders: Vec<FolderState>,
}

impl Resolved {
    /// The book that holds `copy`.
    pub fn book_of(&self, copy: &str) -> Option<&Book> {
        self.books.iter().find(|b| b.copies.iter().any(|c| c.copy == copy))
    }

    /// The next free number in a division.
    pub fn next_seq(&self, div: &str) -> u32 {
        self.next.get(div).copied().unwrap_or(1)
    }
}

type Stamp = (u64, String, usize);

fn newer<T>(old: Option<&(Stamp, T)>, s: &Stamp) -> bool {
    old.is_none_or(|(o, _)| o < s)
}

struct CopyData {
    locs: BTreeSet<String>,
    title: String,
    quality: Option<CopyQuality>,
    suggested: Option<SuggestedDiv>,
    seed_title: Option<String>,
    seed_place: Option<String>,
    fields: FactFields,
    seed_fields: FactFields,
}

#[derive(Clone)]
struct PairEv {
    stamp: Stamp,
    same: bool,
    score: Option<f64>,
}

#[derive(Default)]
struct Pair {
    user: Option<PairEv>,
    auto: Option<PairEv>,
}

struct Edge {
    score: f64,
    by: By,
}

type Adj = BTreeMap<String, BTreeSet<String>>;

fn key(a: &str, b: &str) -> (String, String) {
    if a <= b {
        (a.to_string(), b.to_string())
    } else {
        (b.to_string(), a.to_string())
    }
}

/// The shortest path from `from` to `to` (neighbours in text order, so the same path every time).
fn path(adj: &Adj, from: &str, to: &str) -> Option<Vec<String>> {
    let mut prev: BTreeMap<&str, &str> = BTreeMap::new();
    let mut seen: BTreeSet<&str> = BTreeSet::from([from]);
    let mut q: VecDeque<&str> = VecDeque::from([from]);
    while let Some(n) = q.pop_front() {
        if n == to {
            let mut out = vec![to.to_string()];
            let mut cur = to;
            while let Some(p) = prev.get(cur) {
                out.push((*p).to_string());
                cur = *p;
            }
            out.reverse();
            return Some(out);
        }
        for m in adj.get(n).into_iter().flatten() {
            if seen.insert(m.as_str()) {
                prev.insert(m.as_str(), n);
                q.push_back(m.as_str());
            }
        }
    }
    None
}

fn cmp_quality(a: (&str, Option<&CopyQuality>), b: (&str, Option<&CopyQuality>)) -> Ordering {
    match (a.1, b.1) {
        (Some(x), Some(y)) => compare_copies(x, y),
        (Some(_), None) => Ordering::Greater,
        (None, Some(_)) => Ordering::Less,
        (None, None) => b.0.cmp(a.0),
    }
}

#[derive(Default)]
struct Agg {
    shelf: Option<(Stamp, (Option<String>, By))>,
    title: Option<(Stamp, String)>,
    removed: Option<(Stamp, bool)>,
    prefer: Option<(Stamp, String)>,
    author: Option<(Stamp, String)>,
    edition: Option<(Stamp, String)>,
    year: Option<(Stamp, u32)>,
}

/// Resolves the events against the libraries' facts.
///
/// 1. **Groups.** For each pair of copies the latest of its `same` and `notsame` events wins, and a `user` event outranks an
///    `auto` one. Books are the connected groups of live `same` links. A `notsame` between two copies still linked through a
///    third cuts the weakest link on the path (lowest `score`, `auto` before `user`) until they are apart.
/// 2. **Call number.** Each copy keeps the `assign` events written for it (its latest one that no `retire` cancels). The book's
///    number is the earliest of those among its copies, in the book's shelf division; the others are held, not retired, so a split
///    gives each copy its number back. Clash suffixes rank all claims on a (division, number) by (`at`, `copy`).
/// 3. **Shelf, title, removed, reading copy** as in LIBRARY-LOG.md.
#[allow(clippy::type_complexity)]
pub fn resolve(events: &[Event], libs: &[LibraryInput]) -> Resolved {
    let mut r = Resolved::default();
    let mut libs: Vec<&LibraryInput> = libs.iter().collect();
    libs.sort_by(|a, b| a.library_id.cmp(&b.library_id));

    // ---- the facts of the copies the libraries hold
    let mut data: BTreeMap<String, CopyData> = BTreeMap::new();
    for lib in libs {
        for p in &lib.copies {
            let d = data.entry(p.copy.clone()).or_insert_with(|| CopyData {
                locs: BTreeSet::new(),
                title: p.title.clone(),
                quality: p.quality(),
                suggested: p.suggested.clone(),
                seed_title: None,
                seed_place: None,
                fields: p.fields.clone(),
                seed_fields: FactFields::default(),
            });
            d.locs.insert(format!("{}/{}", lib.library_id, p.doc_id));
            if d.seed_title.is_none() {
                d.seed_title = lib.seed.title.get(&p.doc_id).cloned();
            }
            if let Some(f) = lib.seed.facts.get(&p.doc_id) {
                d.seed_fields = d.seed_fields.or(f);
            }
            if d.seed_place.is_none() {
                d.seed_place = lib.seed.place.get(&p.doc_id).cloned().flatten();
            }
        }
    }

    // ---- one pass over the events
    let stamps: Vec<Stamp> = events.iter().enumerate().map(|(i, e)| (e.at, e.dev.clone(), i)).collect();
    let mut all_copies: BTreeSet<String> = data.keys().cloned().collect();
    let mut pairs: BTreeMap<(String, String), Pair> = BTreeMap::new();
    let mut assigns: BTreeMap<&str, Vec<(&Stamp, &str, u32)>> = BTreeMap::new();
    let mut retires: BTreeSet<(&str, &str, u32)> = BTreeSet::new();
    let mut claims: BTreeMap<(&str, u32), BTreeSet<(u64, &str)>> = BTreeMap::new();
    let mut max_seq: BTreeMap<&str, u32> = BTreeMap::new();
    let mut folder_events: BTreeMap<(&str, &str), (&Stamp, FolderState)> = BTreeMap::new();
    let mut location_events: BTreeMap<(&str, &str, &str, &str), (&Stamp, Option<Location>)> = BTreeMap::new();
    for (e, stamp) in events.iter().zip(&stamps) {
        if let Some(c) = e.kind.copy() {
            all_copies.insert(c.to_string());
        }
        match &e.kind {
            Kind::Same { copy, with, by, score, .. } => {
                all_copies.insert(with.clone());
                let p = pairs.entry(key(copy, with)).or_default();
                let slot = if *by == By::User { &mut p.user } else { &mut p.auto };
                if slot.as_ref().is_none_or(|o| o.stamp < *stamp) {
                    *slot = Some(PairEv { stamp: stamp.clone(), same: true, score: *score });
                }
            }
            Kind::NotSame { copy, with, by } => {
                all_copies.insert(with.clone());
                let p = pairs.entry(key(copy, with)).or_default();
                let slot = if *by == By::User { &mut p.user } else { &mut p.auto };
                if slot.as_ref().is_none_or(|o| o.stamp < *stamp) {
                    *slot = Some(PairEv { stamp: stamp.clone(), same: false, score: None });
                }
            }
            Kind::Assign { copy, div, seq } => {
                let m = max_seq.entry(div.as_str()).or_insert(0);
                *m = (*m).max(*seq);
                claims.entry((div.as_str(), *seq)).or_default().insert((e.at, copy.as_str()));
                assigns.entry(copy.as_str()).or_default().push((stamp, div.as_str(), *seq));
            }
            Kind::Retire { copy, div, seq } => {
                let m = max_seq.entry(div.as_str()).or_insert(0);
                *m = (*m).max(*seq);
                r.retired.entry(div.clone()).or_default().insert(*seq);
                retires.insert((copy.as_str(), div.as_str(), *seq));
            }
            Kind::Folder { folder_id, label, mode } => {
                let k = (e.dev.as_str(), folder_id.as_str());
                if folder_events.get(&k).is_none_or(|(s, _)| *s < stamp) {
                    folder_events.insert(k, (stamp, FolderState { dev: e.dev.clone(), folder_id: folder_id.clone(), label: label.clone(), mode: *mode }));
                }
            }
            Kind::Locate { copy, folder_id, relpath, version, source_blake3 } => {
                let k = (e.dev.as_str(), folder_id.as_str(), copy.as_str(), relpath.as_str());
                if location_events.get(&k).is_none_or(|(s, _)| *s < stamp) {
                    let loc = Location { dev: e.dev.clone(), folder_id: folder_id.clone(), relpath: relpath.clone(), version: *version, source_blake3: source_blake3.clone() };
                    location_events.insert(k, (stamp, Some(loc)));
                }
            }
            Kind::Unlocate { copy, folder_id, relpath } => {
                let k = (e.dev.as_str(), folder_id.as_str(), copy.as_str(), relpath.as_str());
                if location_events.get(&k).is_none_or(|(s, _)| *s < stamp) {
                    location_events.insert(k, (stamp, None));
                }
            }
            Kind::Place { .. } | Kind::Unsort { .. } | Kind::Title { .. } | Kind::Remove { .. } | Kind::Restore { .. } | Kind::Prefer { .. } | Kind::Facts { .. } => {}
        }
    }
    for (div, m) in &max_seq {
        r.next.insert((*div).to_string(), m + 1);
    }
    r.folders = folder_events.into_values().map(|(_, f)| f).collect();
    let mut locations: BTreeMap<&str, Vec<Location>> = BTreeMap::new();
    for ((_, _, copy, _), (_, loc)) in location_events {
        if let Some(l) = loc {
            locations.entry(copy).or_default().push(l);
        }
    }

    // ---- groups
    let mut adj: Adj = BTreeMap::new();
    let mut edges: BTreeMap<(String, String), Edge> = BTreeMap::new();
    let mut apart: Vec<(String, String)> = Vec::new();
    for (k, p) in &pairs {
        // a person's word outranks the detector's for the same pair
        let Some(ev) = p.user.as_ref().or(p.auto.as_ref()) else { continue };
        if ev.same {
            let by = if p.user.is_some() { By::User } else { By::Auto };
            edges.insert(k.clone(), Edge { score: ev.score.unwrap_or(1.0), by });
            adj.entry(k.0.clone()).or_default().insert(k.1.clone());
            adj.entry(k.1.clone()).or_default().insert(k.0.clone());
        } else {
            apart.push(k.clone());
        }
    }
    for (x, y) in &apart {
        while let Some(p) = path(&adj, x, y) {
            let weakest = p
                .windows(2)
                .map(|w| key(&w[0], &w[1]))
                .min_by(|a, b| {
                    let (ea, eb) = (&edges[a], &edges[b]);
                    ea.score.total_cmp(&eb.score).then(ea.by.cmp(&eb.by)).then(a.cmp(b))
                })
                .expect("a path between two copies has an edge");
            edges.remove(&weakest);
            if let Some(s) = adj.get_mut(&weakest.0) {
                s.remove(&weakest.1);
            }
            if let Some(s) = adj.get_mut(&weakest.1) {
                s.remove(&weakest.0);
            }
        }
    }
    let mut book_of: BTreeMap<&str, usize> = BTreeMap::new();
    let mut groups: Vec<Vec<&str>> = Vec::new();
    for c in &all_copies {
        if book_of.contains_key(c.as_str()) {
            continue;
        }
        let idx = groups.len();
        let mut members: Vec<&str> = Vec::new();
        let mut q: VecDeque<&str> = VecDeque::from([c.as_str()]);
        book_of.insert(c.as_str(), idx);
        while let Some(n) = q.pop_front() {
            members.push(n);
            for m in adj.get(n).into_iter().flatten() {
                if !book_of.contains_key(m.as_str()) {
                    book_of.insert(m.as_str(), idx);
                    q.push_back(m.as_str());
                }
            }
        }
        members.sort_unstable();
        groups.push(members);
    }

    // ---- what the events say about each book
    let mut agg: Vec<Agg> = groups.iter().map(|_| Agg::default()).collect();
    for (e, stamp) in events.iter().zip(&stamps) {
        let Some(copy) = e.kind.copy() else { continue };
        let Some(&b) = book_of.get(copy) else { continue };
        let a = &mut agg[b];
        match &e.kind {
            Kind::Place { div, by, .. } if newer(a.shelf.as_ref(), stamp) => a.shelf = Some((stamp.clone(), (Some(div.clone()), *by))),
            Kind::Unsort { by, .. } if newer(a.shelf.as_ref(), stamp) => a.shelf = Some((stamp.clone(), (None, *by))),
            Kind::Title { title, .. } if newer(a.title.as_ref(), stamp) => a.title = Some((stamp.clone(), title.clone())),
            Kind::Remove { .. } if newer(a.removed.as_ref(), stamp) => a.removed = Some((stamp.clone(), true)),
            Kind::Restore { .. } if newer(a.removed.as_ref(), stamp) => a.removed = Some((stamp.clone(), false)),
            Kind::Prefer { copy } if newer(a.prefer.as_ref(), stamp) => a.prefer = Some((stamp.clone(), copy.clone())),
            Kind::Facts { fields, .. } => {
                if let Some(x) = fields.author.as_ref().filter(|_| newer(a.author.as_ref(), stamp)) {
                    a.author = Some((stamp.clone(), x.clone()));
                }
                if let Some(x) = fields.edition.as_ref().filter(|_| newer(a.edition.as_ref(), stamp)) {
                    a.edition = Some((stamp.clone(), x.clone()));
                }
                if let Some(x) = fields.year.filter(|_| newer(a.year.as_ref(), stamp)) {
                    a.year = Some((stamp.clone(), x));
                }
            }
            _ => {}
        }
    }

    // a copy's own held number: its latest assign that no retire of the same copy, division and number cancels
    let held = |copy: &str| -> Option<(&Stamp, &str, u32)> {
        assigns.get(copy)?.iter().filter(|(_, d, s)| !retires.contains(&(copy, *d, *s))).max_by(|a, b| a.0.cmp(b.0)).map(|(st, d, s)| (*st, *d, *s))
    };
    // the clash rank: the copy's place among the distinct copies that claimed (div, seq), ordered by each copy's first claim
    // (`at`, `copy`); a copy that claimed the same number twice is one claim
    let call_of = |copy: &str, _at: u64, div: &str, seq: u32| -> Call {
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut suffix = 0;
        for (_, who) in claims.get(&(div, seq)).into_iter().flatten() {
            if *who == copy {
                suffix = seen.len() as u32;
                break;
            }
            seen.insert(who);
        }
        Call { div: div.to_string(), seq, suffix, text: call_text(div, seq, suffix) }
    };

    for (members, a) in groups.iter().zip(&agg) {
        let avail: Vec<&str> = members.iter().copied().filter(|c| data.contains_key(*c)).collect();
        if avail.is_empty() {
            continue;
        }
        let reading = a
            .prefer
            .as_ref()
            .map(|(_, c)| c.as_str())
            .filter(|c| avail.contains(c))
            .or_else(|| avail.iter().copied().max_by(|x, y| cmp_quality((*x, data[*x].quality.as_ref()), (*y, data[*y].quality.as_ref()))))
            .expect("a book with a copy has a reading copy");
        let (shelved, shelf, by) = match &a.shelf {
            Some((_, (div, by))) => (true, div.clone(), Some(*by)),
            None => (false, None, None),
        };
        let call = shelf.as_deref().and_then(|d| {
            members
                .iter()
                .filter_map(|c| held(c).filter(|(_, hd, _)| *hd == d).map(|(st, _, seq)| (st.0, *c, st.1.as_str(), st.2, seq)))
                .min()
                .map(|(at, c, _, _, seq)| call_of(c, at, d, seq))
        });
        let rd = &data[reading];
        let (title, title_from) = match (&a.title, &rd.seed_title) {
            (Some((_, t)), _) => (t.clone(), TitleFrom::Log),
            (None, Some(t)) => (t.clone(), TitleFrom::Seed),
            (None, None) => (rd.title.clone(), TitleFrom::Pack),
        };
        let aka: BTreeSet<String> = avail.iter().filter(|c| **c != reading).map(|c| data[*c].title.clone()).filter(|t| *t != title && !t.is_empty()).collect();
        let suggested = std::iter::once(reading).chain(avail.iter().copied().filter(|c| *c != reading)).find_map(|c| {
            let d = &data[c];
            d.seed_place
                .as_ref()
                .map(|div| Suggest { div: div.clone(), label: None, from: "seed" })
                .or_else(|| d.suggested.as_ref().map(|s| Suggest { div: s.div.clone(), label: Some(s.label.clone()).filter(|l| !l.is_empty()), from: "pack" }))
        });
        let copies = members
            .iter()
            .map(|c| {
                let d = data.get(*c);
                CopyView {
                    copy: (*c).to_string(),
                    locs: d.map(|d| d.locs.iter().cloned().collect()).unwrap_or_default(),
                    title: d.map(|d| d.title.clone()),
                    own_call: held(c).map(|(st, d, seq)| call_of(c, st.0, d, seq)),
                    locations: locations.get(c).cloned().unwrap_or_default(),
                }
            })
            .collect();
        r.books.push(Book {
            id: members[0].to_string(),
            copies,
            reading: reading.to_string(),
            shelf,
            shelved,
            by,
            call,
            title,
            title_from,
            aka: aka.into_iter().collect(),
            removed: a.removed.as_ref().is_some_and(|(_, x)| *x),
            suggested,
            author: a.author.as_ref().map(|(_, x)| x.clone()).or_else(|| rd.seed_fields.author.clone()).or_else(|| rd.fields.author.clone()),
            edition: a.edition.as_ref().map(|(_, x)| x.clone()).or_else(|| rd.seed_fields.edition.clone()).or_else(|| rd.fields.edition.clone()),
            year: a.year.as_ref().map(|(_, x)| *x).or(rd.seed_fields.year).or(rd.fields.year),
        });
    }
    r
}
