//! Tests for the transport-independent core of Nearby linking.

use cache_rns::pair_core::*;
use std::collections::HashSet;

fn ident(tag: u8, name: &str) -> Identity {
    Identity {
        device_key: [tag; 32],
        rns_dest: vec![tag; 16],
        rns_sig: vec![tag ^ 0x55; 64],
        name: name.to_string(),
    }
}

const KA: [u8; 32] = [0xA1; 32];
const KB: [u8; 32] = [0xB2; 32];

/// Run a full exchange; returns (initiator pending, responder pending).
fn run(init: Identity, resp: Identity, ik: [u8; 32], rk: [u8; 32]) -> (PendingLink, PendingLink) {
    let (mut i, commit) = Initiator::start_with_secret_bytes(init, 0, ik);
    let mut r = Responder::new_with_secret_bytes(resp, 0, rk);
    let offer = r.on_message(&commit, 1).unwrap().reply.unwrap();
    let reveal = i.on_message(&offer, 2).unwrap().reply.unwrap();
    let rs = r.on_message(&reveal, 3).unwrap();
    let ident = rs.reply.unwrap();
    let is = i.on_message(&ident, 4).unwrap();
    (is.pending.unwrap(), rs.pending.unwrap())
}

#[test]
fn word_list_is_2048_unique_lowercase_ascii() {
    let w = word_list();
    assert_eq!(w.len(), 2048);
    let set: HashSet<_> = w.iter().collect();
    assert_eq!(set.len(), 2048);
    assert!(w.iter().all(|x| !x.is_empty() && x.bytes().all(|b| b.is_ascii_lowercase())));
    assert_eq!(w[0], "abandon");
    assert_eq!(w[2047], "zoo");
}

#[test]
fn derivation_is_stable_with_fixed_vectors() {
    let d = derive(&[1; 32], &[2; 32], &[3; 32], &ident(4, "Pixel 8"), &ident(5, "Laptop"));
    assert_eq!(derive(&[1; 32], &[2; 32], &[3; 32], &ident(4, "Pixel 8"), &ident(5, "Laptop")), d);
    assert_eq!(d.indexes, VECTOR_INDEXES, "words changed: {:?}", words_of(d.indexes));
    assert_eq!(words_of(d.indexes), VECTOR_WORDS);
    // Order matters: initiator first.
    let swapped = derive(&[1; 32], &[2; 32], &[3; 32], &ident(5, "Laptop"), &ident(4, "Pixel 8"));
    assert_ne!(swapped, d);
}

const VECTOR_INDEXES: [u16; 3] = [1392, 682, 126];
const VECTOR_WORDS: [&str; 3] = ["puppy", "fetch", "average"];
const EXCHANGE_WORDS: [&str; 3] = ["have", "album", "stay"];

#[test]
fn honest_exchange_gives_the_same_words() {
    let (a, b) = run(ident(1, "A"), ident(2, "B"), KA, KB);
    assert_eq!(a.words(), b.words());
    // Fixed one-time keys and identities give fixed words.
    assert_eq!(a.words(), EXCHANGE_WORDS, "exchange words changed");
    assert_eq!(a.peer(), &ident(2, "B"));
    assert_eq!(b.peer(), &ident(1, "A"));
    assert_eq!(a.role(), Role::Initiator);
    assert_eq!(b.role(), Role::Responder);
}

#[test]
fn random_keys_also_agree() {
    let (mut i, commit) = Initiator::start(ident(1, "A"), 0);
    let mut r = Responder::new(ident(2, "B"), 0);
    let offer = r.on_message(&commit, 0).unwrap().reply.unwrap();
    let reveal = i.on_message(&offer, 0).unwrap().reply.unwrap();
    let rs = r.on_message(&reveal, 0).unwrap();
    let is = i.on_message(&rs.reply.unwrap(), 0).unwrap();
    assert_eq!(is.pending.unwrap().words(), rs.pending.unwrap().words());
}

#[test]
fn man_in_the_middle_gets_different_words() {
    // M runs one exchange as responder toward A and one as initiator toward B,
    // passing the real identities along but holding its own one-time keys.
    let a_id = ident(1, "A");
    let b_id = ident(2, "B");
    let (mut a, a_commit) = Initiator::start_with_secret_bytes(a_id.clone(), 0, KA);
    let mut m_resp = Responder::new_with_secret_bytes(ident(9, "M"), 0, [0x71; 32]);
    let (mut m_init, m_commit) = Initiator::start_with_secret_bytes(ident(9, "M"), 0, [0x72; 32]);
    let mut b = Responder::new_with_secret_bytes(b_id.clone(), 0, KB);

    let m_offer = m_resp.on_message(&a_commit, 1).unwrap().reply.unwrap();
    let b_offer = b.on_message(&m_commit, 1).unwrap().reply.unwrap();
    let a_reveal = a.on_message(&m_offer, 2).unwrap().reply.unwrap();
    let m_reveal = m_init.on_message(&b_offer, 2).unwrap().reply.unwrap();
    let m_resp_step = m_resp.on_message(&a_reveal, 3).unwrap();
    let b_step = b.on_message(&m_reveal, 3).unwrap();
    let a_pending = a.on_message(&m_resp_step.reply.unwrap(), 4).unwrap().pending.unwrap();
    let b_pending = b_step.pending.unwrap();
    let _ = m_init.on_message(&b_step.reply.unwrap(), 4).unwrap();
    assert_ne!(a_pending.words(), b_pending.words());

    // And the confirmations are refused: no link is kept on either side.
    let (mut a_pending, mut b_pending) = (a_pending, b_pending);
    let ca = a_pending.confirm(5).unwrap();
    let cb = b_pending.confirm(5).unwrap();
    assert_eq!(a_pending.on_message(&cb, 6), Err(PairError::WordsMismatch));
    assert_eq!(b_pending.on_message(&ca, 6), Err(PairError::WordsMismatch));
    assert!(a_pending.into_confirmed().is_err());
    assert!(b_pending.into_confirmed().is_err());
}

#[test]
fn wrong_reveal_aborts_on_the_responder() {
    let (_i, commit) = Initiator::start_with_secret_bytes(ident(1, "A"), 0, KA);
    let mut r = Responder::new(ident(2, "B"), 0);
    r.on_message(&commit, 1).unwrap();
    let forged = Message::Reveal { key: [0x33; 32], identity: ident(1, "A") }.encode();
    assert_eq!(r.on_message(&forged, 2).unwrap_err(), PairError::CommitmentMismatch);
    // The exchange is over; nothing more is accepted.
    assert_eq!(r.on_message(&forged, 3).unwrap_err(), PairError::Finished);
}

#[test]
fn all_zero_key_is_refused() {
    let key = [0u8; 32];
    let commit = Message::Commit { commit: commitment(&key) }.encode();
    let mut r = Responder::new(ident(2, "B"), 0);
    r.on_message(&commit, 0).unwrap();
    let reveal = Message::Reveal { key, identity: ident(1, "A") }.encode();
    assert_eq!(r.on_message(&reveal, 0).unwrap_err(), PairError::WeakKey);
}

#[test]
fn changing_any_bound_field_changes_the_words() {
    let base = |s: &[u8; 32], ik: &[u8; 32], rk: &[u8; 32], a: &Identity, b: &Identity| {
        derive(s, ik, rk, a, b).indexes
    };
    let (s, ik, rk, a, b) = ([1u8; 32], [2u8; 32], [3u8; 32], ident(4, "A"), ident(5, "B"));
    let want = base(&s, &ik, &rk, &a, &b);
    let mut seen = HashSet::new();
    seen.insert(want);

    let mut variants: Vec<[u16; 3]> = vec![
        base(&[9; 32], &ik, &rk, &a, &b),
        base(&s, &[9; 32], &rk, &a, &b),
        base(&s, &ik, &[9; 32], &a, &b),
    ];
    for who in 0..2 {
        let id = if who == 0 { &a } else { &b };
        let mut name = id.clone();
        name.name.push('x');
        let mut dest = id.clone();
        dest.rns_dest[0] ^= 1;
        let mut sig = id.clone();
        sig.rns_sig[0] ^= 1;
        let mut key = id.clone();
        key.device_key[0] ^= 1;
        for v in [name, dest, sig, key] {
            variants.push(if who == 0 { base(&s, &ik, &rk, &v, &b) } else { base(&s, &ik, &rk, &a, &v) });
        }
    }
    for v in &variants {
        assert_ne!(*v, want);
    }
    // Moving a byte between adjacent fields must not collide either.
    let mut x = a.clone();
    x.rns_dest.push(x.rns_sig.remove(0));
    assert_ne!(base(&s, &ik, &rk, &x, &b), want);
}

#[test]
fn timeout_drops_a_pending_exchange() {
    let (mut a, _b) = run(ident(1, "A"), ident(2, "B"), KA, KB); // words ready at t=4
    assert_eq!(a.poll(4 + TIMEOUT_MS - 1), LinkState::Waiting);
    assert_eq!(a.poll(4 + TIMEOUT_MS), LinkState::Dropped(PairError::Timeout));
    assert_eq!(a.confirm(4 + TIMEOUT_MS + 1), Err(PairError::Timeout));
    assert!(a.into_confirmed().is_err());

    // A handshake that stalls also ends.
    let (mut i, _commit) = Initiator::start(ident(1, "A"), 100);
    assert!(i.expired(100 + TIMEOUT_MS));
    let offer = Message::Offer { key: [7; 32] }.encode();
    assert_eq!(i.on_message(&offer, 100 + TIMEOUT_MS).unwrap_err(), PairError::Timeout);
    let mut r = Responder::new(ident(2, "B"), 0);
    let commit = Message::Commit { commit: [0; 32] }.encode();
    assert_eq!(r.on_message(&commit, TIMEOUT_MS).unwrap_err(), PairError::Timeout);
}

#[test]
fn three_strikes_block_for_a_minute_then_allow() {
    let mut g = RequestGuard::new();
    assert!(g.allow(0));
    g.record_strike(1_000);
    g.record_strike(2_000);
    assert!(g.allow(2_500));
    g.record_strike(3_000); // third
    assert!(!g.allow(3_001));
    assert!(!g.allow(3_000 + BLOCK_MS - 1));
    assert!(g.allow(3_000 + BLOCK_MS));
    assert_eq!(g.strikes(), 0);
    // A fresh run of strikes is needed to block again.
    g.record_strike(70_000);
    assert!(g.allow(70_001));
    // Success resets the count.
    g.record_success();
    assert_eq!(g.strikes(), 0);
}

#[test]
fn nothing_is_kept_before_both_confirm() {
    let (a, mut b) = run(ident(1, "A"), ident(2, "B"), KA, KB);
    // Nobody confirmed: nothing to keep.
    let a = match a.into_confirmed() {
        Ok(_) => panic!("kept before confirm"),
        Err(p) => *p,
    };
    let mut a = a;
    // Only A confirms.
    let ca = a.confirm(10).unwrap();
    assert_eq!(a.poll(10), LinkState::Waiting);
    let mut a = match a.into_confirmed() {
        Ok(_) => panic!("kept after one side"),
        Err(p) => *p,
    };
    // B receives A's confirmation but has not confirmed itself.
    assert_eq!(b.on_message(&ca, 11), Ok(LinkState::Waiting));
    let mut b = match b.into_confirmed() {
        Ok(_) => panic!("kept before own confirm"),
        Err(p) => *p,
    };
    let cb = b.confirm(12).unwrap();
    assert_eq!(b.poll(12), LinkState::Confirmed);
    assert_eq!(a.on_message(&cb, 13), Ok(LinkState::Confirmed));
    let kept_a = a.into_confirmed().unwrap();
    let kept_b = b.into_confirmed().unwrap();
    assert_eq!(kept_a.peer, ident(2, "B"));
    assert_eq!(kept_b.peer, ident(1, "A"));
}

#[test]
fn cancel_drops_both_sides() {
    let (mut a, mut b) = run(ident(1, "A"), ident(2, "B"), KA, KB);
    let c = a.cancel();
    assert_eq!(a.poll(5), LinkState::Dropped(PairError::Cancelled));
    assert_eq!(b.on_message(&c, 5), Err(PairError::Cancelled));
    assert!(b.confirm(6).is_err());
    assert!(a.into_confirmed().is_err());
    assert!(b.into_confirmed().is_err());
}

#[test]
fn wire_rules() {
    let m = Message::Offer { key: [1; 32] };
    let bytes = m.encode();
    assert_eq!(Message::decode(&bytes), Ok(m));
    // Version byte is first; another version is refused.
    let mut bad = bytes.clone();
    bad[0] = 2;
    assert_eq!(Message::decode(&bad), Err(PairError::UnsupportedVersion(2)));
    // Trailing bytes, garbage and oversize fields are refused.
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert_eq!(Message::decode(&trailing), Err(PairError::Malformed));
    assert_eq!(Message::decode(&[]), Err(PairError::Malformed));
    let mut big = ident(1, "A");
    big.name = "x".repeat(MAX_NAME_LEN + 1);
    let r = Message::Identity { identity: big }.encode();
    assert_eq!(Message::decode(&r), Err(PairError::Malformed));
    // Out-of-order messages are refused.
    let mut resp = Responder::new(ident(2, "B"), 0);
    assert_eq!(resp.on_message(&bytes, 0).unwrap_err(), PairError::Unexpected);
}
