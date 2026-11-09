// The sharing rules that are plain data: share ids, folder names, link modes and the sync patterns of what each device builds for
// itself. No Flutter, no other imports: the Cache Server helper (server/helper, plain Dart) reads this file, and the app's own files
// re-export what they used to declare, so nothing on the phone changes.

/// What a library folder holds that never syncs with the libraries folder (see DataKind.notShared): its old keyword index
/// ([LibraryItem.indexPath]). Library indexes now build into the indexes folder and sync from there as snapshots
/// (search/indexes_share.dart); this version only reads an old index/ until the core seals it into a snapshot and empties it,
/// and only Cache 1.0.29 and earlier still write here, so it stays out (a file the core moved away would otherwise go out as a
/// delete and remove an older device's own index).
const List<String> kLibraryNotShared = ['*/index'];

/// What the region engine's folder (the `regions` shared folder) holds that each device makes for itself, as sync patterns (see
/// DataKind.notShared), so it never syncs. The downloaded parts all sync: regions.sqlite (the region records, tile lists and
/// meta) with its -wal, `tiles/<build>/` (routing tiles, streamed ones among them: they share the folder), `places/<build>.sqlite`
/// (the merged places, the only copy of the places tiles: each is merged in and its download deleted), `places/<build>/common.sqlite`,
/// places/CURRENT and offroad/. Left out:
/// - `index`, `places/index`: where the tile indexes were kept before. They now live, and sync, in the indexes folder as
///   snapshots (`region-index/<build>/`, `places-index/<build>/`; search/indexes_share.dart): this version moves what it finds
///   here into it, and only Cache 1.0.29 and earlier still write here, so these stay out of the regions share (a file a newer
///   device moved away would otherwise go out as a delete and remove an older device's copy).
/// - `**/*-shm`: SQLite's shared-memory index of a WAL file, which also holds the locks of the connections on this device; SQLite
///   rebuilds it from the -wal when it opens the database.
/// - `**/*-journal`: a rollback journal, this device's alone (a copied one would be played back into another device's database).
const List<String> kRegionsNotShared = ['index', 'places/index', '**/*-shm', '**/*-journal'];

/// What the layer engine's folder (the `maps` shared folder) holds that each device makes for itself, as sync patterns. The
/// downloaded map layers sync: `store/<layer>.sqlite` (every tile downloaded for offline use, and the areas) with its -wal,
/// catalogue.json and latest.json (the layer definitions those tiles belong to), user-defs/. Left out:
/// - `tiles.sqlite*`: the cache of tiles viewed online (size-capped, least recently used first), with its -wal and -shm.
/// - `tilejson`: TileJSON documents as fetched from each source, kept a day.
/// - `**/*-shm`, `**/*-journal`: as for [kRegionsNotShared].
const List<String> kMapLayersNotShared = ['tiles.sqlite*', 'tilejson', '**/*-shm', '**/*-journal'];

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
