# Local patch to zim 0.5.0

Source: crates.io zim 0.5.0, already used by Cache (crate SHA-256: 63cffa116b0aaebeb94142acd0ad39c63ee9f6180a5729e5c02036b73b4b082e). Original licence files are retained.

iOS uses reference-counted mapping windows instead of reserving virtual address space for the entire ZIM. Other platforms retain their existing full mapping and fall back to windows when that reservation fails. Two windows of at most 2 MiB each are cached per archive part; live views retain their mapping until their caller releases them. Large payloads are mapped only for the requested range and are not cached.

Uncompressed blob lengths are read from two offset-table entries, without mapping the whole payload. Checksum verification streams bounded views and propagates I/O failures.

The windowed-mmap Cargo feature exercises the iOS path on desktop for regression checks.

Upstream unit tests are retained. The one testdir-only temporary directory uses std instead, so no extra test package is needed. Fixture-driven tests and the fixture-only testdir dependency are omitted from this local package; Cache has its own synthetic and real-archive regression tests.
