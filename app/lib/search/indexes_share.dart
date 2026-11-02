import 'dart:convert';

import 'package:cache_search/cache_search.dart' show RejectedSnapshot, SourceStatus;

/// The device's syncable search indexes (the core's `indexes_dir`): one folder, `<kind>/<source id>/`, each with its working
/// `.build/` and its sealed snapshots `snap/<build-id>/` (manifest.json written last). It is shared with every linked device
/// once sharing is set up, whatever kinds are ticked, so an index reaches any device that has the same source, even when the
/// source itself does not sync (two phones with the same ZIM, each downloaded on its own).

/// The always-on share of the indexes folder.
const String kIndexesShareId = 'indexes';

/// The indexes folder, under the app's support folder.
const String kIndexesDirName = 'shared-indexes';

/// What never syncs from it: each index's build (which also holds a publish in progress, renamed into `snap/` in one step), the
/// core's own notes about this device (`.local/`, such as the snapshots it rejected), and SQLite's working files, which belong to
/// the device that opened the database.
const List<String> kIndexesNotShared = ['*/*/.build', '.local', '**/*-shm', '**/*-wal', '**/*-journal'];

/// Where a delete stays on the device that made it: each device clears out the snapshots it no longer uses on its own, and
/// never fetches back one it deleted.
const List<String> kIndexesLocalDeletes = ['*/*/snap'];

/// What comes after the rest of a snapshot: its manifest, whose arrival says the snapshot is whole.
const List<String> kIndexesLast = ['*/*/snap/*/manifest.json'];

/// The kinds of index folder each kind of source has (the core's kinds): a ZIM's keyword index, its PDFs', its captions' and
/// its EPUBs'; a library's.
const Map<String, List<String>> kIndexKindsOfSource = {
  'zim': ['zim', 'zim-pdf', 'zim-captions', 'zim-epub'],
  'library': ['library'],
};

/// Index kinds every device fetches whole, whatever sources it has: the regions' tile indexes (routing and places), one small
/// snapshot per server build. A device fetches them before it has any region: with a peer's copy it plans and adds regions
/// with no network, and a device with no network knows no build name to ask for (the core takes the newest snapshot here).
const List<String> kIndexKindsAlways = ['places-index', 'region-index'];

/// A source id as one folder name, as the core writes it (cache_search snapshot.rs `encode_source_id`): every byte except
/// letters, digits and `_@-`, and `.` after the first byte, is written `%XX`.
String encodeSourceId(String id) {
  final out = StringBuffer();
  final bytes = utf8.encode(id);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    final plain = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x5f || b == 0x40 || b == 0x2d || (b == 0x2e && i > 0);
    out.write(plain ? String.fromCharCode(b) : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
  }
  return out.toString();
}

/// What this device fetches of the indexes folder: the regions' tile indexes ([kIndexKindsAlways]), the captions of the videos
/// saved here ([savedVideos], their `<instance>/<uuid>`), and the index folders of the sources the core has open (their
/// `source_id` in cs_status), every kind each of them has. A source the core could not open (no source id) fetches nothing.
List<String> indexesFetchOnly(Iterable<SourceStatus> sources, {Iterable<String> savedVideos = const []}) => {
  ...kIndexKindsAlways,
  // Each saved video's captions ("<instance>/<video uuid>"), on whichever device indexed them.
  for (final v in savedVideos)
    if (v.isNotEmpty) 'captions/${encodeSourceId(v)}',
  for (final s in sources)
    if (s.sourceId != null && s.sourceId!.isNotEmpty)
      for (final kind in kIndexKindsOfSource[s.kind] ?? const <String>[]) '$kind/${encodeSourceId(s.sourceId!)}',
}.toList()..sort();

/// What this device never fetches of the indexes folder: the snapshots its core found unusable and removed. Sync already keeps
/// a snapshot this device deleted from coming back (the delete stays here); this holds even when that record is gone.
List<String> indexesNeverFetch(Iterable<RejectedSnapshot> rejected) => {
  for (final r in rejected)
    if (r.kind.isNotEmpty && r.sourceId.isNotEmpty && r.buildId.isNotEmpty) '${r.kind}/${encodeSourceId(r.sourceId)}/snap/${r.buildId}',
}.toList()..sort();
