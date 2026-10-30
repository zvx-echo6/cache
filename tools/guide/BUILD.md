# Building the guide library

Turns the chapters in `docs/guide/` into `cache-guide-YYYY-MM-DD.cache-library`, a gzip-compressed Cache library (format:
`docs/LIBRARY-FORMAT.md`). The shipped copy is `app/assets/guide/cache-guide.cache-library`.

## Version and name

The version is the build date, `YYYY-MM-DD` (add a letter, `2026-10-30b`, for a second build on the same day). It goes in
`cache-library.json` as `version` and in the file name: `cache-guide-<version>.cache-library`. The `library_id` is always
`cache-guide`, so a newer version replaces the old one on the phone. Never overwrite an earlier build's files.

## What you need

- Python 3 (`-I` is used below so no stray module is loaded).
- A Windows machine with a Cache command-line build folder (`BIN`): `cs.exe`, `cache_llama.dll` and a working config
  (`BASE_CONFIG`, for example `config-none.json`), and the model `bge-m3-Q8_0.gguf` (`MODEL`, sha256
  `c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb`).
- Rust, to build the snapshot writer. It is a cargo example in the core crate, not a script here, because it needs the
  crate's own `libadd::pack_snapshot` and the pinned Qdrant `edge` dependency:
  `packages/cache_search/native/cache_search/examples/build_guide.rs`.
- Embedding and the cargo build are heavy. Check free memory first; do not run them at the same time.

## Steps

Set `W` to an empty work folder and `OUT` to where the library is kept.

1. Split the chapters into a manifest (112 sections at the time of writing; exits 1 on a duplicate title):

       python3 -I tools/guide/split.py --out W/manifest.json

2. Embed each section (writes `text_vec` and `title_text_vec` for every section):

       python -I tools/guide/embed_guide.py --bin-dir BIN --model MODEL W/manifest.json W/vectors.json

3. Make the points. The library uses the `title_text_vec` embedding, the embedding of "title, blank line, text":

       python3 -I tools/guide/assemble.py W/manifest.json W/vectors.json title_text_vec W/points.json

4. Write the shard and pack the snapshot (`--no-default-features` skips the libzim build, which this does not need):

       cargo build --manifest-path packages/cache_search/native/Cargo.toml -p cache_search --no-default-features --example build_guide
       target/debug/examples/build_guide W/points.json W/shard W/guide.snapshot

5. Package it. This writes `cache-library.json`, the uncompressed `.cache-library.tar`, and the compressed
   `cache-guide-<version>.cache-library` (the same as `tar -rf` then `gzip -9 -n`), and prints sizes and sha256:

       python3 -I tools/guide/package.py --snapshot W/guide.snapshot --version YYYY-MM-DD --out-dir W/pkg

   Record the sha256 of the compressed file. Publish or ship that file.

6. Unpack, index and make a config to check it with `cs` (the unpack takes the uncompressed tar):

       BIN/cs.exe unpack-library --snapshot W/pkg/cache-guide-<version>.cache-library.tar --dir OUT/library/cache-guide-<version>
       BIN/cs.exe index-library --library OUT/library/cache-guide-<version> --index-dir OUT/index-<version> --settings OUT/library/cache-guide-<version>/cache-library.json
       python3 -I tools/guide/gen_config.py --base-config BASE_CONFIG --library-dir OUT/library/cache-guide-<version> --index-dir OUT/index-<version> --out OUT/config-guide-only-<version>.json

## Ids

    doc_id   = slug(chapter heading without its number) + "--" + slug(section heading)
    point id = UUIDv5(c4b95b91-e641-5c16-91a0-13ba2f6f7970, "<doc_id>:1:0")

`slug` lowercases, drops apostrophes and turns every run of other characters into `-`. The namespace is
UUIDv5(URL namespace, "https://github.com/zvx-echo6/cache/library-point"). Because the id comes from the headings only,
it stays the same when a section's text changes and changes only when a heading is renamed.

## Verify

    python3 -I tools/guide/verify.py --cs BIN/cs.exe --config OUT/config-guide-only-<version>.json --manifest W/manifest.json \
        --embed-lib BIN/cache_llama.dll --embed-model MODEL --embed-sha256 <the model sha256 above>

It checks that the entry count equals the number of sections, that every section reads back byte-identical with its exact
title, and that questions (one per setup area, and a few natural ones) return the expected section in the top 3. It exits 1
on any failure. Also run `python3 tools/guide/check_labels.py . docs/guide/ch*.md` and `python3 tools/guide/guide_titles.py`.
Then copy the compressed file to `app/assets/guide/cache-guide.cache-library`.
