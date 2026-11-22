# fake-indexeddb

An in-memory implementation of IndexedDB for JavaScript, version 6.2.8, Apache-2.0 (see LICENSE; a copy is at `app/assets/reader/fake-indexeddb-LICENSE` for the app's Open-source licenses page, and a test keeps the two equal).

- Source: npm `fake-indexeddb` 6.2.8, as bundled by jsDelivr: https://cdn.jsdelivr.net/npm/fake-indexeddb@6/+esm
- Bundle sha256: `1003f520a621b60bd6d3d6ca37227c28f1430593607113963e49ea6b72867f59`
- npm tarball sha256: `fa32bf22123fa975860ed79fdc794ce26be236d3aec4fda59173ed7dbf934dce`
- Wrapped by Cache as a classic script, together with a small localStorage/sessionStorage stand-in, in `app/assets/reader/zim_storage.js` (sha256 `0492a805db27a37d9dbeeabd09d48fcd9edba8055001b8cc34c25aee5eda8762`). That is the only copy in the repository.

Why: ZIM pages in Cache's readers have no storage of their own (the browser reader's frame is sandboxed with no origin; the phone readers serve pages without one), so pages that need IndexedDB or Web Storage, for example ones built on PouchDB, would stay on "Loading". The stand-in is always installed and nothing it holds is kept after the page closes.

Where it is used, by all three readers:
- Browser (Cache Server): the file is compiled into the server (`server/src/http.rs`), served at `/zim-storage.js`, and added as the first script in the head of every ZIM HTML page.
- Android and iPhone: the file is an app asset, and `withZimStorage` in `app/lib/browse/reader_resources.dart` puts it inline first in the head of every page.
