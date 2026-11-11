# The `own` marker: who can write it

`"own": true` in a library's `cache-library.json` means the person made the library on a device (Add PDF's My books, or another
library of their own). It is the one fact the core uses to let that library's keyword snapshot grow by generations (the highest
generation is picked, `idxsnap::appendable_library`), and the one fact Add PDF uses to offer a library as a target
(`addPdfTargets`, `LibrariesState.ownLibraries`). Every other library, and every ZIM, keeps the earliest-wins pick unchanged.
`copies.jsonl` is NOT the marker: catalogue libraries, builder libraries made on a person's own server and on-device libraries all
ship it.

## Every writer of `cache-library.json` (exhaustive: a search of Dart, Rust, Python and the server crates)

| Writer | Where | Can it set `own`? |
|---|---|---|
| The app makes a library on the device | `app/lib/sources/libraries_state.dart` `makeBlankLibrary` (writes the file at its end), its only caller `_makeOwn`, with `ownLibrarySettings` | Yes, on purpose: the only writer of `own: true` (`ownLibrarySettings`) |
| The app adds a library from an archive or a chosen file | `libraries_state.dart` `addFile` writes `settings` (the archive's own settings file, or the file the person picked) through `settingsForImport` | It PRESERVES `own` from the person's chosen file or archive: restoring or moving an exported own library must leave it theirs to write to (a deliberate act, and prior behaviour). `own_default` is dropped when the device already has another own library, and kept when it has none (tests: `libraries_test.dart`) |
| The core unpacks an archive | `packages/cache_search/native/cache_search/src/libadd.rs` `unpack`: reads the archive's settings file and removes it from the folder; it writes none | No |
| The core's blank-library template | `libadd.rs` `template_settings` (written into the template tar) | No (test: `the_template_settings_never_say_own`) |
| The core's other settings code | `library.rs`, `ingest.rs`, `idxsnap.rs`, `cs_*` calls: read the file or take settings JSON from the caller; none writes the file | No |
| The library builder (catalogue and own server) | `server/builder/src/library.rs` `library_settings` (from the template plus id, title and version), `incremental.rs` `library_settings_json`; the server writes it at `server/src/libbuild/mod.rs` (`write_bytes_atomic`) | No (test: `the_builders_library_settings_never_say_own`) |
| The guide library's packaging | `tools/guide/package.py` (the template settings plus the version) | No |
| Sync | `cache_sync` copies files by hash and never reads or rewrites them | Only copies bytes: an `own` library from the person's other device is `own` here, and nothing becomes `own` by syncing (test: `a_librarys_settings_file_arrives_unchanged`) |
| The command line and the server helper | `packages/cache_search/cli`, `server/helper/bin/core_open.dart`: read the file | No |

A library that arrives by sync from the person's other device with `own: true` is read by the core from the synced file like any
other (`appendable_library` reads `cache-library.json` from the library folder or the shard's parent), so it takes the
highest-generation rule too (test: `the_highest_generation_is_picked_only_for_an_own_library_whatever_copies_jsonl_says`).
