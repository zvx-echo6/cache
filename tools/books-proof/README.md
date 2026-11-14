# My books two-writer proof

A host-run check that two linked devices sharing My books keep every book each of them adds. Each device is a separate OS
process (`flutter test`) running the app's real SharingState over the real cache_sync SyncCore (iroh on localhost; relay, dht,
mdns and lookup off), the Library kind's `libraries` share with main.dart's not-shared patterns, the Bookshelves link share
(Match), My books made as the app makes it (`makeBlankLibrary` + `ownLibrarySettings`), and Add PDF through the app's
`AddPdfState` on the real core ingest (PDFium, bge-m3, the shipped sorter). The only stand-ins are a network probe the runner
switches between wifi and none, and a fake OCR engine (the PDFs have text layers).

First run, 2026-11-14, rel-1.1 30b1eedf and build-1.1.0-51: the bug was confirmed in every scenario (see "Result").

## Files

- `device.dart`: one device. It takes commands as `<PROOF_DIR>/cmd/NNNN.json` and answers in `<PROOF_DIR>/res/NNNN.json`. It uses
  only API that build-1.1.0-51 and rel-1.1 share.
- `run.py`: the runner. It starts the devices, runs a scenario and writes the evidence.

## Setup (Linux build box)

Under `~/proof/booksbug` (the `P` in run.py):
- `new/` is a checkout of the build under test, and `b51/` a checkout of `build-1.1.0-51` (with submodules).
- In each checkout, `packages/cache_search/native/target/debug/libcache_search.so` is built (`cargo build --locked -p cache_search`,
  with `LIBZIM_DIR` from `zimx/fetch-libzim-linux.sh`), `flutter pub get` is run in `app/`, and
  `.github/scripts/seed-native-assets.sh <pinned> . linux-x64` gives the app PDFium and SQLite.
- `device.dart` is copied to `app/test/booksproof/device.dart` in each checkout (it imports `../support/pdfium_for_tests.dart`).
- `libzim.env` holds the `LIBZIM_DIR=...` line.
- `~/cache/llama-linux/libcache_llama.so` and `~/cache/models/bge-m3-Q8_0.gguf` must exist (as `tests.sh` makes them).

Run with `CPUS=<cpu list> python3 -I run.py <scenario> [...]`. Each device runs under `taskset -c $CPUS nice -n 10`, and the runner
waits for 2 GB of free memory and 10 GB of free disk before it starts a device.

## Scenarios

Every scenario starts the same way. A and B link; both set the link to Match; A makes My books; both share the Library; and
there are three sync rounds. A then adds "Campfire safety guide", and after more rounds My books is on both devices with one
book (stage `1-one-book-synced`). Then:

- `apart`: both devices lose the network (the probe says none, so sync pauses). A adds "Water purification manual" and B adds
  "Field radio handbook" (stage `2-apart-before-sync`). The network comes back, and there are six sync rounds each (stage
  `3-after-sync`).
- `midflight`: both devices add at the same time while sync rounds are being asked for, then sync (stage `3-after-sync`).
- `b51`: as `apart`, with B on build-1.1.0-51 (the old peer).

## Evidence

The evidence goes to `evidence/<scenario>/<stage>/`:
- `A.json` and `B.json`: each device's dump. It lists every file in the libraries folder with its size, the conflict and beside
  copies, the `copies.jsonl` rows, `documents.tsv`, the packs, the bookshelf PDFs, the Bookshelves view, the shard's point count
  (`shard_points`), and for each phrase the titles a vector search and a keyword search return.
- `A-libraries/` and `B-libraries/`: copies of the libraries folders.
- `checks.json`: the checks, described below.

Logs: `logs/run.log`, and each device's process log and `log.txt`.

## What each check means (checks.json)

Per device and book:
- `copies_line`: the book has a row in My books' `copies.jsonl` (which also puts it on the Bookshelves).
- `on_bookshelves`: the resolved Bookshelves view lists it.
- `pdf`: its `bookshelf/<BLAKE3>.pdf` is there.
- `vector_hit`: a search by meaning for a phrase from it finds it (the query is embedded with bge-m3, as the Library does).
- `keyword_hit`: a keyword search for a word from it finds it. This harness does not share the indexes folder, so a device whose
  My books arrived by sync has no keyword index and is expected to be false there. It does not bear on the two-writer result.

Per device:
- `shard_points` against `expected_points`: the shard's points against the sum of the pieces added.
- `copies_lines` and `packs`: the number of rows and packs.
- `conflict_files`: any `(conflict, ...)` or `(from ...)` copies in the libraries folder.
- `library_error` and `search_error`: the library could not be opened or searched.

A pass is every book with `copies_line`, `on_bookshelves`, `pdf` and `vector_hit` on both devices, points equal to the expected
count, and no conflict files.

## Result (2026-11-14)

- `apart` (run twice) and `b51`: after sync, both devices have 2 points out of 3 and 2 rows out of 3. A's own book is gone from
  the shard, `copies.jsonl` and `documents.tsv` on both devices, while its pack and PDF remain. Conflict copies of `copies.jsonl`,
  `documents.tsv` and the shard's segment files are in the folder and synced.
- `midflight`: both devices have 3 points and 3 rows, but the shard mixes the two devices' segment files. Hits come back with empty
  titles on A, and every search on B returns nothing.

Mechanism: My books is one synced library with a writer on every device. An add rewrites the shard's segment files in place,
and `copies.jsonl` and `documents.tsv` too. cache_sync keeps the newer version of each file and keeps the other as a conflict
copy, so one add is lost, or a shard is put together from both devices' files.
