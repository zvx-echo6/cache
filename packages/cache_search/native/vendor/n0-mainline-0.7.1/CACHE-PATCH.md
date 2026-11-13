# Local patch to n0-mainline 0.7.1

Source: crates.io n0-mainline 0.7.1 (crate SHA-256: b739fb0145326fa2287f704a5a3bceb5d21c5b6f1b09436403b504f85c2e6ded), MIT OR Apache-2.0; both licence files are retained. The crate's `Cargo.lock`, CI files and toolchain file are left out.

Why: after a UDP receive error other than WouldBlock, tokio keeps the socket "readable", so `KrpcSocket::recv_batch` (src/actor/socket.rs) returned an empty batch at once and the actor loop (src/actor.rs `run`) called it again with no wait: about 89% of a CPU, on a phone as well. Every change is marked `cache patch:`.

What: after such an error `recv_batch` waits before the next receive: 50 ms, doubling to 2 s, back to none after a receive that works. The deadline is kept in the socket, so the wait is cancel safe. `n0_mainline::recv_error_stats()` returns the number of receive errors and the OS error number of the latest, so Cache can report it in its sync activity. The test `recv_error_does_not_spin` (src/actor/socket.rs) fails without the patch.

Drop this when upstream stops the loop spinning (see the report text kept with the Cache sources), and remove the `[patch.crates-io]` line in packages/cache_search/native/Cargo.toml and the `n0-mainline` use in cache_sync.
