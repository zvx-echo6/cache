//! The entry-point list between devices (step 4): the merge per id, the hash two devices compare (`entries_v`), and how long a
//! removal is remembered. Pure functions of `cache_sync::entries`; no network.

use cache_sync::entries::{merge, version, Record, MAX_TOMBSTONES, TOMBSTONE_MS};

const NOW: u64 = 1_800_000_000_000;
const DAY: u64 = 24 * 60 * 60 * 1000;

fn e(id: &str, host: &str, t: u64, dev: &str) -> Record {
    Record::entry(id, host, 4965, t, dev)
}

fn find<'a>(list: &'a [Record], id: &str) -> &'a Record {
    list.iter().find(|r| r.id == id).unwrap_or_else(|| panic!("{id} is in the list"))
}

#[test]
fn the_newer_t_wins_whichever_way_round() {
    let old = e("aa", "old.example", NOW - 2000, "dev-a");
    let new = e("aa", "new.example", NOW - 1000, "dev-b");
    for (mine, theirs) in [(&old, &new), (&new, &old)] {
        let m = merge(std::slice::from_ref(mine), std::slice::from_ref(theirs), NOW);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].host, "new.example");
    }
}

#[test]
fn a_removal_beats_an_older_entry_and_a_newer_entry_beats_a_removal() {
    let entry = e("bb", "x.example", NOW - 2000, "dev-a");
    let gone = Record::tombstone("bb", NOW - 1000, "dev-b");
    for (mine, theirs) in [(&entry, &gone), (&gone, &entry)] {
        let m = merge(std::slice::from_ref(mine), std::slice::from_ref(theirs), NOW);
        assert_eq!(m.len(), 1);
        assert!(m[0].removed, "the removal is the newer");
        // Nothing of the entry is kept in a removal.
        assert!(m[0].host.is_empty() && m[0].passphrase.is_none());
    }
    // Added again later (an edit made after the removal reached this device): the entry is the newer.
    let back = e("bb", "x.example", NOW - 500, "dev-a");
    for (mine, theirs) in [(&gone, &back), (&back, &gone)] {
        let m = merge(std::slice::from_ref(mine), std::slice::from_ref(theirs), NOW);
        assert!(!m[0].removed);
    }
}

#[test]
fn on_the_same_t_the_greater_device_id_wins_and_both_agree() {
    let a = e("cc", "from-a.example", NOW - 1000, "dev-a");
    let b = e("cc", "from-b.example", NOW - 1000, "dev-b");
    let ab = merge(std::slice::from_ref(&a), std::slice::from_ref(&b), NOW);
    let ba = merge(std::slice::from_ref(&b), std::slice::from_ref(&a), NOW);
    assert_eq!(ab[0].host, "from-b.example");
    assert_eq!(ab, ba);
    // A removal and an entry at the same moment from one device pair: still one answer, the same both ways.
    let gone = Record::tombstone("cc", NOW - 1000, "dev-b");
    let x = merge(std::slice::from_ref(&a), std::slice::from_ref(&gone), NOW);
    let y = merge(std::slice::from_ref(&gone), std::slice::from_ref(&a), NOW);
    assert_eq!(x, y);
    assert!(x[0].removed, "dev-b is the greater");
    // The very same moment and device but different contents (a clock that stood still): still the same either way.
    let p = e("cc", "p.example", NOW - 1000, "dev-a");
    let q = e("cc", "q.example", NOW - 1000, "dev-a");
    assert_eq!(merge(std::slice::from_ref(&p), std::slice::from_ref(&q), NOW), merge(std::slice::from_ref(&q), std::slice::from_ref(&p), NOW));
}

#[test]
fn both_orders_reach_the_same_list() {
    let mine = vec![
        e("01", "one.example", NOW - 5000, "dev-a"),
        e("02", "two.example", NOW - 4000, "dev-a"),
        Record::tombstone("03", NOW - 3000, "dev-a"),
        e("05", "five.example", NOW - 100, "dev-a"),
    ];
    let theirs = vec![
        e("01", "one-edited.example", NOW - 4500, "dev-b"),
        Record::tombstone("02", NOW - 3500, "dev-b"),
        e("03", "three.example", NOW - 4000, "dev-b"),
        e("04", "four.example", NOW - 200, "dev-b"),
    ];
    let ab = merge(&mine, &theirs, NOW);
    let ba = merge(&theirs, &mine, NOW);
    assert_eq!(ab, ba);
    assert_eq!(find(&ab, "01").host, "one-edited.example");
    assert!(find(&ab, "02").removed);
    assert!(find(&ab, "03").removed);
    assert_eq!(ab.len(), 5);
    // Merging again changes nothing, and so does merging in a list already taken.
    assert_eq!(merge(&ab, &theirs, NOW), ab);
    assert_eq!(merge(&ab, &mine, NOW), ab);
    assert_eq!(version(&ab), version(&ba));
}

#[test]
fn the_version_is_the_same_for_equal_lists_built_in_any_order() {
    let list = vec![e("01", "one.example", NOW - 3, "d"), Record::tombstone("02", NOW - 2, "d"), e("03", "three.example", NOW - 1, "d")];
    let mut rev = list.clone();
    rev.reverse();
    let mut mixed = vec![list[1].clone(), list[2].clone(), list[0].clone()];
    assert_eq!(version(&list), version(&rev));
    assert_eq!(version(&list), version(&mixed));
    // Any change shows: an entry's switch, its passphrase, a removal.
    let base = version(&list);
    mixed[2].on = false;
    assert_ne!(version(&mixed), base);
    let mut p = list.clone();
    p[0].passphrase = Some("secret".into());
    assert_ne!(version(&p), base);
    let mut q = list.clone();
    q[2] = Record::tombstone("03", NOW, "d");
    assert_ne!(version(&q), base);
    // And an empty list has a version of its own that is not the same as a one-entry list's.
    assert_ne!(version(&[]), base);
    assert_eq!(version(&[]), version(&[]));
    // The version never shows what it was made of.
    assert!(!version(&p).contains("secret"));
}

#[test]
fn a_removal_is_remembered_for_60_days_and_at_most_500() {
    assert_eq!(TOMBSTONE_MS, 60 * DAY);
    assert_eq!(MAX_TOMBSTONES, 500);
    let old = Record::tombstone("aa", NOW - 61 * DAY, "d");
    let fresh = Record::tombstone("bb", NOW - 59 * DAY, "d");
    let live = e("cc", "kept.example", NOW - 200 * DAY, "d");
    let m = merge(&[old.clone(), fresh.clone()], std::slice::from_ref(&live), NOW);
    assert!(m.iter().all(|r| r.id != "aa"), "past 60 days it is forgotten");
    assert!(m.iter().any(|r| r.id == "bb"));
    assert!(m.iter().any(|r| r.id == "cc"), "an entry is never forgotten for being old");
    // A removal that is past its time and comes from the other device is not taken back either.
    let again = merge(&m, &[old], NOW);
    assert_eq!(again, m);
    // More than 500: the newest 500 stay.
    let many: Vec<Record> = (0..600u64).map(|i| Record::tombstone(&format!("{i:032x}"), NOW - 1000 - i, "d")).collect();
    let m = merge(&many, &[live], NOW);
    assert_eq!(m.iter().filter(|r| r.removed).count(), 500);
    assert!(m.iter().any(|r| r.id == format!("{:032x}", 0)), "the newest is kept");
    assert!(m.iter().all(|r| r.id != format!("{:032x}", 599)), "the oldest of them goes");
    assert!(m.iter().any(|r| !r.removed), "the entry stays beside them");
}

// --- The same host:port under two ids (step 4, part 3) ---
//
// Two devices that each enter the same address while apart make two ids for one rnsd. After the merge there is one live entry: the
// newer `t` wins, on the same `t` the greater device id, then the greater id. Every loser becomes a removal whose `t` and `dev` are
// the WINNER's, so the removal is the same record whichever device makes it (equal lists, equal `entries_v`, nothing to send back),
// and it is never older than the loser it replaces (the same `t` with the winner's greater device, or the same device and `t` with
// `removed` set), so it beats the loser on every device.

fn live(list: &[Record]) -> Vec<&Record> {
    list.iter().filter(|r| !r.removed).collect()
}

#[test]
fn the_same_host_and_port_under_two_ids_ends_as_one_entry_the_newer() {
    let a = e("a1", "Rt.Example.NET", NOW - 2000, "dev-a");
    let b = e("b1", "rt.example.net", NOW - 1000, "dev-b");
    for (mine, theirs) in [(&a, &b), (&b, &a)] {
        let m = merge(std::slice::from_ref(mine), std::slice::from_ref(theirs), NOW);
        assert_eq!(live(&m).len(), 1, "one live entry: {m:?}");
        assert_eq!(live(&m)[0].id, "b1", "the newer t wins");
        let lost = find(&m, "a1");
        assert!(lost.removed, "the loser is a removal");
        assert_eq!((lost.t, lost.dev.as_str()), (NOW - 1000, "dev-b"), "carrying the winner's t and device");
    }
    // The same address on another port is another entry.
    let c = Record::entry("c1", "rt.example.net", 4966, NOW, "dev-a");
    assert_eq!(live(&merge(std::slice::from_ref(&b), &[c], NOW)).len(), 2);
}

#[test]
fn on_the_same_t_the_greater_device_wins_and_the_removal_beats_the_loser_everywhere() {
    let a = e("a1", "rt.example.net", NOW - 1000, "dev-a");
    let b = e("b1", "rt.example.net", NOW - 1000, "dev-b");
    let ab = merge(std::slice::from_ref(&a), std::slice::from_ref(&b), NOW);
    let ba = merge(std::slice::from_ref(&b), std::slice::from_ref(&a), NOW);
    assert_eq!(ab, ba);
    assert_eq!(live(&ab)[0].id, "b1");
    // The same device and the same moment (a clock that stood still): the greater id.
    let p = e("p1", "x.example", NOW - 1000, "dev-a");
    let q = e("q1", "x.example", NOW - 1000, "dev-a");
    let pq = merge(std::slice::from_ref(&p), std::slice::from_ref(&q), NOW);
    assert_eq!(pq, merge(std::slice::from_ref(&q), std::slice::from_ref(&p), NOW));
    assert_eq!(live(&pq)[0].id, "q1");
    // Whatever a device still holds of a loser is replaced by the removal, and nothing comes back.
    assert_eq!(merge(&pq, std::slice::from_ref(&p), NOW), pq);
    assert_eq!(merge(&ab, std::slice::from_ref(&a), NOW), ab);
}

#[test]
fn the_dedupe_is_stable_and_gives_equal_versions() {
    let a = vec![e("a1", "rt.example.net", NOW - 3000, "dev-a"), e("a2", "other.example", NOW - 100, "dev-a")];
    let b = vec![e("b1", "RT.example.net", NOW - 2000, "dev-b")];
    let on_a = merge(&a, &b, NOW);
    let on_b = merge(&b, &a, NOW);
    assert_eq!(on_a, on_b);
    assert_eq!(version(&on_a), version(&on_b));
    assert_eq!(live(&on_a).len(), 2);
    // Round after round, in any direction, nothing moves.
    let mut x = on_a.clone();
    for _ in 0..3 {
        x = merge(&x, &on_b, NOW);
        assert_eq!(x, on_a);
        assert_eq!(version(&x), version(&on_a));
    }
    // A removal of the winner does not bring the loser back.
    let gone = Record::tombstone("b1", NOW, "dev-a");
    let m = merge(&on_a, std::slice::from_ref(&gone), NOW);
    assert_eq!(live(&m).len(), 1);
    assert!(find(&m, "a1").removed);
}
