//! Speed classes (design 2b): how a link's round trip time, first-hop bitrate and measured rate decide Fast, Medium or Slow,
//! and how a device keeps the judgments for its linked devices.

use std::time::Duration;

use cache_rns::speed::{classify, Speed, Speeds};
use iroh::SecretKey;

#[test]
fn the_thresholds_are_the_designs() {
    // Fast: RTT under 300 ms (and a rate over 1 MB/s once there is one).
    assert_eq!(classify(Some(20), None, None), Speed::Fast);
    assert_eq!(classify(Some(299), None, None), Speed::Fast);
    assert_eq!(classify(Some(300), None, None), Speed::Medium);
    assert_eq!(classify(Some(1499), None, None), Speed::Medium);
    assert_eq!(classify(Some(1500), None, None), Speed::Slow);
    assert_eq!(classify(Some(20), Some(2_000_000.0), None), Speed::Fast);
    assert_eq!(classify(Some(20), Some(1_000_001.0), None), Speed::Fast);
    // Medium: a rate over 20 KB/s; Slow: under it.
    assert_eq!(classify(Some(20), Some(900_000.0), None), Speed::Medium);
    assert_eq!(classify(Some(20), Some(20_000.0), None), Speed::Medium);
    assert_eq!(classify(Some(20), Some(19_999.0), None), Speed::Slow);
    // A first hop under 100 kbit/s is Slow whatever else says; the slower guess wins.
    assert_eq!(classify(Some(20), None, Some(99_999)), Speed::Slow);
    assert_eq!(classify(Some(20), None, Some(100_000)), Speed::Fast);
    assert_eq!(classify(Some(20), None, Some(10_000_000)), Speed::Fast);
    assert_eq!(classify(Some(1000), Some(5_000_000.0), Some(10_000_000)), Speed::Medium);
    // Nothing known: the class of a path nothing is known against (iroh counts as fast).
    assert_eq!(classify(None, None, None), Speed::Fast);
    assert_eq!(Speed::Slow.as_str(), "slow");
    assert_eq!(Speed::Medium.as_str(), "medium");
    assert_eq!(Speed::Fast.as_str(), "fast");
    assert!(Speed::Slow < Speed::Medium && Speed::Medium < Speed::Fast);
}

#[test]
fn a_device_judges_each_linked_device_from_what_it_has_seen() {
    let t = Speeds::new();
    let (a, b) = (SecretKey::generate().public(), SecretKey::generate().public());
    assert_eq!(t.ask_speed(&a), Speed::Fast, "nothing known yet");
    // The link this device opened to A has a long round trip; B is untouched.
    t.set_opened_rtt(&a, 2000);
    assert_eq!(t.ask_speed(&a), Speed::Slow);
    assert_eq!(t.ask_speed(&b), Speed::Fast);
    // What this device answers is judged by the link the other device opened, not by the one this device opened.
    assert_eq!(t.serve_speed(&a), Speed::Slow, "with no link of A's own, the one it opened says");
    t.set_accepted_rtt(&a, 400);
    assert_eq!(t.serve_speed(&a), Speed::Medium);
    assert_eq!(t.ask_speed(&a), Speed::Slow);
    // A later small request's time is the newer measurement (the path changed under an idle link).
    t.note_probe(&a, 20);
    assert_eq!(t.ask_speed(&a), Speed::Fast);
    t.note_probe(&a, 1800);
    assert_eq!(t.ask_speed(&a), Speed::Slow);
}

#[test]
fn the_first_hop_and_the_measured_rate_lower_a_class() {
    let t = Speeds::new();
    let a = SecretKey::generate().public();
    t.set_opened_rtt(&a, 20);
    assert_eq!(t.ask_speed(&a), Speed::Fast);
    // A transfer of 4 MiB in 10 s is about 420 KB/s: Medium.
    t.note_transfer(&a, 4 * 1024 * 1024, Duration::from_secs(10));
    assert_eq!(t.ask_speed(&a), Speed::Medium);
    // Small transfers say nothing about a rate (a 5 KB page is quick or slow by its round trip).
    let b = SecretKey::generate().public();
    t.set_opened_rtt(&b, 20);
    t.note_transfer(&b, 5 * 1024, Duration::from_secs(1));
    assert_eq!(t.ask_speed(&b), Speed::Fast);
    // 1 MiB in 100 s is about 10 KB/s: Slow.
    let c = SecretKey::generate().public();
    t.set_opened_rtt(&c, 20);
    t.note_transfer(&c, 1024 * 1024, Duration::from_secs(100));
    assert_eq!(t.ask_speed(&c), Speed::Slow);
    // A first hop under 100 kbit/s: Slow before any measurement; it applies to what is answered too.
    let d = SecretKey::generate().public();
    t.set_opened_rtt(&d, 20);
    t.set_accepted_rtt(&d, 20);
    t.set_first_hop(&d, Some(1200));
    assert_eq!(t.ask_speed(&d), Speed::Slow);
    assert_eq!(t.serve_speed(&d), Speed::Slow);
    t.set_first_hop(&d, None);
    assert_eq!(t.ask_speed(&d), Speed::Fast);
}

#[test]
fn what_the_other_device_refused_as_too_slow_holds_until_this_device_measures_again() {
    let t = Speeds::new();
    let a = SecretKey::generate().public();
    t.set_opened_rtt(&a, 20);
    assert_eq!(t.ask_speed(&a), Speed::Fast);
    // The slower of the two judgments wins: the other device said Slow.
    t.note_refused(&a);
    assert_eq!(t.ask_speed(&a), Speed::Slow);
    // A new link, or a fresh measurement, clears it.
    t.note_probe(&a, 20);
    assert_eq!(t.ask_speed(&a), Speed::Fast);
    t.note_refused(&a);
    t.set_opened_rtt(&a, 20);
    assert_eq!(t.ask_speed(&a), Speed::Fast);
}
