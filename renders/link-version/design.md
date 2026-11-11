# Link version gate: design (nothing built)

Paths are in `packages/cache_search/native/cache_sync/src/lib.rs` on rel-1.1 unless noted.

## Where peers exchange data today
- ALPNs: `PAIR_ALPN` (l.54, needs the one-time code) and `SYNC_ALPN` (l.56); file bytes go over `iroh_blobs::ALPN` (accepted l.1703).
- Client: `round_with` (l.1140) calls `fetch_index` (l.1230), which sends the bytes `index`, reads a `RemoteIndex` (l.280), then runs `adopt_link` (the Match/Send link), `fetch_secrets` (l.1088) and `apply` (deletes and fetches).
- Server: `SyncProto::accept` (l.1564) answers `secrets` or, for anything else, `our_index_for` (l.1041). `Gate` (l.366) only checks "is this key linked".
- UI: `status()` peers JSON (l.2146) from `PeerState` (l.329).

## What 1.0.30 does (v1.0.30 code, read)
- Its `SyncProto::accept` ignores the request bytes (`_ask`) and serves its whole index to anyone linked. So a 1.1 device can always read a 1.0 index, and can learn nothing else from it: `RemoteIndex` there is only `name` and `shares`, with no version.
- Its `fetch_index` parses our reply as `RemoteIndex` (serde is lenient, unknown fields are ignored). Any failure (connect refused, bad JSON) sets `PeerState.error`; that peer is skipped for the round and `providers()` skips it too. Nothing is deleted or marked, no peer state is persisted, and it retries every 30 s round. Its UI shows "Not reachable". The failure path is safe.
- If we answer with a valid index with `"shares": []`, it parses, applies nothing (`apply` only runs per listed share) and replaces any older index it held, so it can never fetch from us. It shows "Connected, just now", with nothing to get.
- Recommended reply to a 1.0 asker: `{"name": <ours>, "shares": []}`, so no error churn and no deletes. An error instead would show "Not reachable". Decision 3.

## Version fields
Add to `RemoteIndex` (serde defaults, so 1.0 ignores them): `proto: u32`, `min_proto: u32`, `app_version: String`. In 1.1: `proto = 2`, `min_proto = 2`. Absent means 1. Constants `SYNC_PROTO` and `SYNC_MIN_PROTO` live beside `SYNC_ALPN` in lib.rs. The app version cannot come from the crate (Cargo says 0.1.0); the app passes `app_version` in `Config`, next to `name`, from the same place as the device name (`sharing_state.dart:138`).

## Compatible
Recommend a range, not strict equality: compatible when `their.proto >= our.min_proto` and `our.proto >= their.min_proto`. For 1.1 it equals "both 2". A later release can then declare it still talks to 1.1 without another break. Peer older: `their.proto < our.min`. Peer newer: `our.proto < their.min`.

## Where the gate sits
1. Our fetch: in `round_with` after `fetch_index`. Mismatch: keep only name, proto and version in `PeerState`; set `index = None`; skip `adopt_link`, `fetch_secrets`, `apply`. This also removes the peer from `providers()` and from the pending and offers counts in `status()`.
2. Their connect, `SyncProto::accept`: the request carries our proto as `index/2/2` and `secrets/2/2` (under the 64-byte read cap). A bare `index` is a 1.0 device. Incompatible: serve the empty index (or `{}` for secrets), never `our_index_for`. Compatible: record the peer's key in a shared compatible-set.
3. Files and everything on blobs: `Gate::after_handshake` (l.370) also receives that set and rejects `iroh_blobs::ALPN` from any key not in it (403). Unknown is gated. The set is in memory; it refills from the first index request in either direction, which always precedes a blob fetch.
4. Local rescans continue; only the exchange stops. Deletes happen only in `apply`, so none cross.

## Unknown
A peer not heard since this version started is "unknown": gated, shown as "Checking…" (existing `peerStatus` text) until it answers.

## Auto-resume and settings
Every round re-fetches each peer's index, even a mismatched one, so the next round after the other device updates flips `compat` to `ok` and proceeds in the same round; no re-pairing and nothing persisted. A mismatched peer is retried at most every 10 min, since a 1.0 peer sends its whole index; Sync now overrides. Settings: `link` (Match/Send) and `secrets` ride the same two paths and are gated with them. `set_link` still writes locally while gapped; on resume `adopt_link` takes the later `t`, so whichever side chose last wins. A 1.0 device has no links, so after it updates the usual "Sync Cache settings?" question is asked. The device page hides the settings section and disables Sync now while mismatched (rendered).

## Linux
`server/Cargo.toml:27` uses cache_sync only for `identity::load_or_create`; the server never runs a `SyncEngine`, so it needs nothing. Linux sync is the desktop app (same FFI core) and `src/bin/cache_sync.rs`; both pick up the constants from lib.rs. They need: a rebuild from the gate commit, and the app passing `app_version` (the CLI falls back to the crate version, or gets `--app-version`). Any 1.1 build before the gate counts as proto 1, test devices included.

## Status JSON, per peer (additive)
`compat`: `"ok" | "peer_older" | "peer_newer" | "unknown"`; `peer_version`: string or null; `our_version`: string; plus `peer_proto`. A 1.0 peer never sends its version, so we can show only "1.0 or earlier" for it, not "1.0.30"; the renders use 1.0.30 as in the request. `peerStatus` falls back to "an older version".

## Decided and built (owner)
1. Range `SYNC_MIN_PROTO..SYNC_PROTO` (lib.rs, with a how-to-bump comment); 1.1 is 2..2.
2. A mismatched peer is checked once when the app opens and on the device page's Check again (`check_version`), not on a schedule. If the other device itself asks with a matching version, it is re-checked at once.
3. A 1.0 asker gets the connection closed with an error (409, "version mismatch: update Cache") instead of an empty index, and the blobs ALPN is refused. At v1.0.30 an error sets `st.error` and skips that peer (round, `providers`), deletes nothing. The text is not visible on 1.0: `read_to_end` errors format as "read error: connection lost", and 1.0 shows only "Not reachable".
4. A 1.0 peer shows as "1.0 or earlier". A warning icon starts the mismatch line.
