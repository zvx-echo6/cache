// The sharing rules that are plain data: share ids, folder names, link modes and the sync patterns of what each device builds for
// itself. No Flutter, no other imports: the Cache Server helper (server/helper, plain Dart) reads this file, and the app's own files
// re-export what they used to declare, so nothing on the phone changes.

/// What a library folder holds that never syncs with the libraries folder (see DataKind.notShared): its old keyword index
/// ([LibraryItem.indexPath]). Library indexes now build into the indexes folder and sync from there as snapshots
/// (search/indexes_share.dart); this version only reads an old index/ until the core seals it into a snapshot and empties it,
/// and only Cache 1.0.29 and earlier still write here, so it stays out (a file the core moved away would otherwise go out as a
/// delete and remove an older device's own index).
///
/// A person's own libraries (My books: the folders named [kOwnLibraryPrefix]...) also keep what is made from their packs to each
/// device: the shard (and its staged copies during a write), `copies.jsonl`, `documents.tsv` and `SHA256SUMS`. Every device of
/// the person adds books to the same own library, so when those synced, two devices that each added a book while apart both
/// rewrote them and the sync kept one side per file: a book lost its search and its list row, or the shard was put together from
/// both devices' files (tools/books-proof). Now only the packs (written once by the device that built the book), the PDFs (named
/// by their content) and the settings sync, and each device builds its shard and lists from the packs itself (the core's
/// `own_library_sync` job, LibrariesState.syncOwnLibraries). Cache 1.1 builds 47 to 51 still sync them; a device on this version
/// leaves theirs out and they no longer get the search of books added on it (accepted: testers update).
const List<String> kLibraryNotShared = [
  '*/index',
  '*/index-snapshots',
  '$kOwnLibraryPrefix*/shard*',
  '$kOwnLibraryPrefix*/copies.jsonl',
  '$kOwnLibraryPrefix*/documents.tsv',
  '$kOwnLibraryPrefix*/SHA256SUMS',
];

/// The folder-name prefix of a person's own libraries: My books is `my-books` (`my-books-2`, ... when the name is taken), an own
/// library restored from an export is named by its id (`my-books-<time>`). No other library is given a folder name starting so
/// (LibrariesState and the Linux server's library ids avoid it), so the share can tell them apart by name before the settings
/// arrive. The core also checks `"own": true` in the settings before it changes anything (ownlib.rs).
const String kOwnLibraryPrefix = 'my-books';

/// Whether a folder name in the libraries folder is one an own library has ([kOwnLibraryPrefix]).
bool isOwnLibraryFolderName(String name) => name.startsWith(kOwnLibraryPrefix);

/// What a ZIM's folder holds that never syncs (see DataKind.notShared): the picture read from the ZIM itself, which each device makes
/// for itself (the saved `.icon.png` does sync, with its ZIM).
const List<String> kZimNotShared = ['*.illustration.png'];

/// What the region engine's folder (the `regions` shared folder) holds that each device makes for itself, as sync patterns (see
/// DataKind.notShared), so it never syncs. A database has one writer, so each device's live databases never travel (see
/// [kMapLayersNotShared], and test/maps_two_writers.rs in cache_sync): when they did, two devices that each downloaded a region
/// replaced each other's database, kept their own as "(conflict, ...)" copies, and one lost its region. What syncs from this folder:
/// `tiles/<build>/` (routing tiles, immutable, named by path), `offroad/`, and what each device shares of itself under its own
/// name: `regions-share/<device>.json` (its regions) and `regions-share/<device>.deletes.json` (the regions it deleted), and
/// `places-share/<build>/<device>.sqlite` (a snapshot of its merged places). Every device reads its own and the others', read-only.
/// Left out:
/// - `regions.sqlite*`: the region records, tile lists and meta, with its -wal.
/// - `places/*.sqlite*`, `places/*/common.sqlite*`, `places/CURRENT`: the merged places database of each build (the device's own
///   copy of the places tiles), the build's common file and the name of the build the device reads.
/// - `index`, `places/index`: where the tile indexes were kept before. They now live, and sync, in the indexes folder as
///   snapshots (`region-index/<build>/`, `places-index/<build>/`; search/indexes_share.dart): this version moves what it finds
///   here into it, and only Cache 1.0.29 and earlier still write here, so these stay out of the regions share (a file a newer
///   device moved away would otherwise go out as a delete and remove an older device's copy).
/// - `**/*-shm`: SQLite's shared-memory index of a WAL file, which also holds the locks of the connections on this device; SQLite
///   rebuilds it from the -wal when it opens the database.
/// - `**/*-journal`: a rollback journal, this device's alone (a copied one would be played back into another device's database).
///
/// Cache builds before this one still send and expect those files. This one never fetches, sends or deletes them (their conflict
/// copies are never read as data), so a pair with one old build does not see each other's regions; the union holds between
/// builds with this rule (accepted: testers update).
const List<String> kRegionsNotShared = [
  'index',
  'places/index',
  '**/*-shm',
  '**/*-journal',
  'regions.sqlite*',
  'places/*.sqlite*',
  'places/*/common.sqlite*',
  'places/CURRENT',
];

/// What the layer engine's folder (the `maps` shared folder) holds that each device makes for itself, as sync patterns. The
/// live tile stores (`store/<layer>.sqlite`, the base map among them, with their -wal) are written by their device only and never
/// travel; each device shares a snapshot of its own under its own name instead, `store-share/<layer>/<device>.sqlite`, and a
/// record of the areas it deleted, `store-share/<device>.deletes.json`, and reads its own store and every peer's snapshot (the
/// layer engine, cache_layers/src/share.rs). What syncs: that, catalogue.json and latest.json (the layer definitions those tiles
/// belong to), user-defs/. Left out:
/// - `store/*.sqlite*`: the live stores, with their -wal.
/// - `tiles.sqlite*`: the cache of tiles viewed online (size-capped, least recently used first), with its -wal and -shm.
/// - `tilejson`: TileJSON documents as fetched from each source, kept a day.
/// - `**/*-shm`, `**/*-journal`: as for [kRegionsNotShared].
const List<String> kMapLayersNotShared = ['tiles.sqlite*', 'tilejson', '**/*-shm', '**/*-journal', 'store/*.sqlite*'];

/// The always-on share of the indexes folder.
const String kIndexesShareId = 'indexes';

/// What never syncs from it: each index's build (which also holds a publish in progress, renamed into `snap/` in one step), the
/// core's own notes about this device (`.local/`, such as the snapshots it rejected), and SQLite's working files, which belong to
/// the device that opened the database.
const List<String> kIndexesNotShared = ['*/*/.build', '.local', '**/*-shm', '**/*-wal', '**/*-journal'];

/// Hidden files that do sync from it (a name starting with "." otherwise never does): Tantivy's `.managed.json`, which every
/// Tantivy snapshot's manifest lists (without it the snapshot is incomplete on the other device and not used), and the empty
/// `.tantivy-meta.lock` the core puts beside it so that opening a snapshot never writes into it.
const List<String> kIndexesHidden = ['*/*/snap/*/.managed.json', '*/*/snap/*/.tantivy-meta.lock'];

/// Where a delete stays on the device that made it: each device clears out the snapshots it no longer uses on its own, and
/// never fetches back one it deleted.
const List<String> kIndexesLocalDeletes = ['*/*/snap'];

/// What comes after the rest of a snapshot: its manifest, whose arrival says the snapshot is whole.
const List<String> kIndexesLast = ['*/*/snap/*/manifest.json'];

/// The settings log's share: one folder linked devices keep the same, kept only with the devices settings go to or come from
/// (Match and Send mine), never listed under Sharing and sync; this device's page governs it.
const String kSettingsShareId = 'settings';

const String kSettingsShareDir = 'settings-sync';

/// The person's Bookshelves log (packages/cache_shelves): kept only with Match devices, never listed under Sharing and sync.
const String kBookshelvesShareId = 'bookshelves';

const String kBookshelvesDir = 'bookshelves';

/// The link kinds each of those folders is kept with (cache_sync's `with`).
const List<String> kSettingsShareModes = ['match', 'send'];

const List<String> kBookshelvesShareModes = ['match'];

/// Notebook sync's folder in the app's support folder (a sharing kind, "Notebooks").
const String kNotebookShareDir = 'notebook-share';
