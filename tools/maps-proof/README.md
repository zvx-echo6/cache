# Maps two-writer proof

A host-run check that two linked devices sharing Maps each keep their own region and also list and draw the other's. Each device is a
separate OS process (`flutter test`) running the app's real SharingState over the real cache_sync SyncCore (iroh on localhost; relay,
dht, mdns and lookup off), the Regions kind's `maps` and `regions` shares with the not-shared patterns of the build under test, the real
core's layer engine (CoreLayerEngine and MapsState: a region's map area downloads into the merged tile store, the tile server reads it
back), and the app's RegionsState over the real region engine. Stand-ins: a wifi probe, and a tile host on 127.0.0.1 in the device's
process that answers every tile with bytes naming the device (so the proof can tell whose copy drew a tile). Regions are downloaded with
their map part only: routing and places need the data server, and their sharing is tested in cache_regions (tests/share.rs),
cache_places (tests/share.rs) and cache_sync (tests/maps_two_writers.rs).

## Files

- `device.dart`: one device. It takes commands as `<PROOF_DIR>/cmd/NNNN.json` and answers in `<PROOF_DIR>/res/NNNN.json`. It uses
  only API that rel-1.1 before the fix and after it share (the patterns of both are copied into it, selected by `PROOF_FIXED`).
- `run.py`: the runner. It starts the devices, runs a scenario and writes the evidence.

## Setup (Linux build box)

Under `~/proof/mapsproof` (the `P` in run.py): `new/` is a checkout of rel-1.1 before the fix, `fix/` the build under test;
`lib-new/` and `lib-fix/` hold the `libcache_search.so` built from each (`cargo build --locked -p cache_search` with `LIBZIM_DIR` from
`zimx/fetch-libzim-linux.sh`). In each checkout `flutter pub get` is run in `app/` and `device.dart` is copied to
`app/test/mapsproof/device.dart`. Run with `CPUS=<cpu list> python3 -I run.py <scenario> [...]`; each device runs under
`taskset -c $CPUS nice -n 10`, and the runner waits for 2 GB of free memory and 5 GB of free disk before it starts a device.

## Scenarios

`before-collide` (the bug, on `new/`), `fix-union`, `fix-delete` (a delete on A removes it on B; a later download wins),
`fix-recover` (the old build collides, then both devices update: the conflict copies are taken back in), `fix-mixed` (an old build
beside a fixed one: its live databases are neither fetched nor deleted).
