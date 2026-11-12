//! The rules of the process's one PDFium lock (src/pdfium.rs): ownership per acquisition (a token), release when the owner is gone, and
//! the minutes-long backstop. The lock is process-wide, so these run in order in one test.

use cache_ingest::pdfium::lock_for_tests as lock;
use std::time::{Duration, Instant};

#[test]
fn the_lock_belongs_to_an_acquisition_is_let_go_when_its_owner_dies_and_has_a_backstop() {
    // an acquisition holds it; another owner waits (and gives up when asked to)
    let t1 = lock::acquire(10, 1000).expect("free at first");
    assert!(t1 > 0);
    assert!(lock::acquire(11, 150).is_none(), "another owner does not get it while it is held");
    assert_eq!(lock::status()["held"], true);
    assert_eq!(lock::status()["owner"], 10);

    // a token that is not the held one does nothing; nor does dropping an owner that does not hold it
    lock::release(t1 + 1000);
    lock::drop_owner(11);
    assert_eq!(lock::status()["held"], true, "still held by owner 10");

    // the owner is gone (its isolate was killed): the lock is free at once, and the dead owner's token does nothing later
    lock::drop_owner(10);
    assert_eq!(lock::status()["held"], false);
    let t2 = lock::acquire(11, 1000).expect("free after the owner's death");
    lock::release(t1);
    assert_eq!(lock::status()["held"], true, "the dead owner's old token did not release the new holder's hold");
    assert_eq!(lock::status()["owner"], 11);
    lock::release(t2);
    assert_eq!(lock::status()["held"], false);

    // per acquisition, not per thread: the same OS thread taking it again with another owner waits, it is not "the owner" by being the
    // thread that held it (a killed isolate's thread goes on to run other isolates)
    let ta = lock::acquire(20, 1000).unwrap();
    assert!(lock::acquire(21, 150).is_none(), "the same thread, another acquisition: it waits");
    lock::release(ta);

    // the backstop: a hold that lasts too long is taken away, loudly; its old token then does nothing
    lock::set_backstop_ms(300);
    let t_old = lock::acquire(30, 1000).unwrap();
    let began = Instant::now();
    let t_new = lock::acquire(31, 5000).expect("taken over by the backstop");
    assert!(began.elapsed() >= Duration::from_millis(250), "not before the backstop: {:?}", began.elapsed());
    assert!(began.elapsed() < Duration::from_millis(3000));
    let st = lock::status();
    assert_eq!(st["backstop_releases"], 1);
    assert!(st["last_backstop"].as_str().unwrap().contains("taken away"), "{st}");
    lock::release(t_old);
    assert_eq!(lock::status()["owner"], 31, "the old holder's token does not release the new one");
    lock::release(t_new);
    lock::set_backstop_ms(5 * 60 * 1000);
    assert_eq!(lock::status()["held"], false);
}
