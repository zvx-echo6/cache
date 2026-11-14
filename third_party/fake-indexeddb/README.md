# fake-indexeddb

An in-memory implementation of IndexedDB for JavaScript, version 6.2.8, Apache-2.0 (see LICENSE).

- Source: npm `fake-indexeddb` 6.2.8, as bundled by jsDelivr: https://cdn.jsdelivr.net/npm/fake-indexeddb@6/+esm
- Bundle sha256: `1003f520a621b60bd6d3d6ca37227c28f1430593607113963e49ea6b72867f59`
- npm tarball sha256: `fa32bf22123fa975860ed79fdc794ce26be236d3aec4fda59173ed7dbf934dce`
- Wrapped by Cache as a classic script, together with a small localStorage/sessionStorage stand-in, in `server/src/zim_storage.js`.

Why: the reader shows ZIM pages in a sandboxed frame with no origin, where the browser denies IndexedDB and Web Storage. Pages that need them (for example ones built on PouchDB) would stay on "Loading". Cache Server serves the script at `/zim-storage.js` and adds it to the start of every ZIM HTML page. It installs only where the browser denies storage, and nothing is kept after the page closes.
