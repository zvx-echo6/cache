//! Three real Prns nodes in one process over loopback TCP: A listens; B (linked both ways) and C (unlinked) connect.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::{
    check_vouch, identity_secret_for, vouch, Asker, BoxFut, Config, Handler, Iface, RnsNode,
};
use iroh::{PublicKey, SecretKey};

const BIG: usize = 8 * 1024 * 1024;

#[derive(Default)]
struct Rec {
    notes: Mutex<Vec<(PublicKey, Vec<u8>)>>,
}

impl Handler for Rec {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        let path = path.to_string();
        Box::pin(async move {
            if path == "/cache/big" {
                return Ok((0..BIG).map(|i| (i % 251) as u8).collect());
            }
            let who = match asker {
                Asker::Linked(p) => format!("linked:{}", p.fmt_short()),
                Asker::Unlinked => "unlinked".to_string(),
            };
            Ok(format!("{path} {who} {}", body.len()).into_bytes())
        })
    }
    fn notify(&self, from: PublicKey, body: Vec<u8>) {
        self.notes.lock().unwrap().push((from, body));
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn cfg(device: &SecretKey, iface: Iface, peers: Vec<PublicKey>) -> Config {
    Config {
        device: device.clone(),
        interfaces: vec![iface],
        peers,
        paths: vec![
            "/cache/index".into(),
            "/cache/pair".into(),
            "/cache/big".into(),
        ],
        open_paths: vec!["/cache/pair".into()],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
    }
}

async fn until(
    what: &str,
    secs: u64,
    mut f: impl FnMut() -> bool,
    mut kick: impl FnMut() -> BoxFut<()>,
) {
    let end = Instant::now() + Duration::from_secs(secs);
    while !f() {
        assert!(Instant::now() < end, "{what} within {secs} s");
        kick().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

#[test]
fn identity_is_derived_and_vouched() {
    let a = SecretKey::generate();
    let b = SecretKey::generate();
    assert_eq!(
        identity_secret_for(&a),
        identity_secret_for(&a),
        "same device key, same identity"
    );
    assert_ne!(identity_secret_for(&a), identity_secret_for(&b));
    let dest = personal_rns::prelude::DestinationHash::new([7u8; 16]);
    let other = personal_rns::prelude::DestinationHash::new([8u8; 16]);
    let v = vouch(&a, &dest);
    assert!(check_vouch(&a.public(), &dest, &v));
    assert!(
        !check_vouch(&b.public(), &dest, &v),
        "another device's key does not accept it"
    );
    assert!(
        !check_vouch(&a.public(), &other, &v),
        "a vouch for another destination is refused"
    );
    assert!(!check_vouch(&a.public(), &dest, &v[..63]));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn linked_unlinked_notify_and_big() {
    let (ka, kb, kc) = (
        SecretKey::generate(),
        SecretKey::generate(),
        SecretKey::generate(),
    );
    let port = free_port();
    let ra = Arc::new(Rec::default());
    let a = Arc::new(
        RnsNode::start(
            cfg(
                &ka,
                Iface::TcpListen(format!("127.0.0.1:{port}")),
                vec![kb.public()],
            ),
            ra.clone(),
        )
        .await
        .unwrap(),
    );
    let b = Arc::new(
        RnsNode::start(
            cfg(
                &kb,
                Iface::TcpConnect(format!("127.0.0.1:{port}")),
                vec![ka.public()],
            ),
            Arc::new(Rec::default()),
        )
        .await
        .unwrap(),
    );
    // C believes A is linked; A does not list C.
    let c = Arc::new(
        RnsNode::start(
            cfg(
                &kc,
                Iface::TcpConnect(format!("127.0.0.1:{port}")),
                vec![ka.public()],
            ),
            Arc::new(Rec::default()),
        )
        .await
        .unwrap(),
    );

    let (a2, b2, c2) = (a.clone(), b.clone(), c.clone());
    until(
        "B and C hear A, A hears B",
        20,
        || b.knows(&ka.public()) && c.knows(&ka.public()) && a.knows(&kb.public()),
        move || {
            let (a2, b2, c2) = (a2.clone(), b2.clone(), c2.clone());
            Box::pin(async move {
                let _ = a2.announce().await;
                let _ = b2.announce().await;
                let _ = c2.announce().await;
            })
        },
    )
    .await;
    assert!(
        !a.knows(&kc.public()),
        "A ignores C's announce: C is not linked"
    );

    // A linked device is answered, and as itself.
    let t = Instant::now();
    let r = b
        .request(
            &ka.public(),
            "/cache/index",
            b"hello",
            Duration::from_secs(10),
        )
        .await
        .unwrap();
    let r = String::from_utf8(r).unwrap();
    assert_eq!(
        r,
        format!("/cache/index linked:{} 5", kb.public().fmt_short())
    );
    println!("linked request answered in {} ms", t.elapsed().as_millis());

    // An unlinked device gets no answer on a closed path.
    let r = c
        .request(
            &ka.public(),
            "/cache/index",
            b"hello",
            Duration::from_secs(5),
        )
        .await;
    assert!(
        r.is_err(),
        "C must not be answered on /cache/index, got {r:?}"
    );

    // ... but is answered, as unlinked, on the open pairing path.
    let r = c
        .request_unlinked(
            a.destination(),
            "/cache/pair",
            b"code",
            Duration::from_secs(10),
        )
        .await
        .unwrap();
    assert_eq!(String::from_utf8(r).unwrap(), "/cache/pair unlinked 4");

    // Notify arrives, from B.
    b.notify(&ka.public(), b"changed").await.unwrap();
    until(
        "A gets the notify",
        10,
        || !ra.notes.lock().unwrap().is_empty(),
        || Box::pin(async {}),
    )
    .await;
    let n = ra.notes.lock().unwrap()[0].clone();
    assert_eq!(n, (kb.public(), b"changed".to_vec()));

    // A large answer (the index can be big) comes back whole.
    let t = Instant::now();
    let r = b
        .request(&ka.public(), "/cache/big", b"", Duration::from_secs(60))
        .await
        .unwrap();
    assert_eq!(r.len(), BIG);
    assert!(r.iter().enumerate().all(|(i, x)| *x == (i % 251) as u8));
    println!("8 MiB answer in {} ms", t.elapsed().as_millis());

    // Unlinking B on A: B is no longer answered.
    a.set_peers(&[]);
    let r = b
        .request(
            &ka.public(),
            "/cache/index",
            b"again",
            Duration::from_secs(5),
        )
        .await;
    assert!(r.is_err(), "B was unlinked on A, got {r:?}");
}
