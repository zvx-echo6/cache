import 'dart:convert';

/// The indexes share's fetch rules with no Flutter and no other package, so the Cache Server helper (plain Dart) applies the very
/// same rules as the phone: search/indexes_share.dart wraps them for the core's own status types.

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

/// What this device fetches of the indexes folder, from plain facts: [sources] are the core's sources by `kind` and `source_id` (null
/// or empty: the core could not open it and it fetches nothing), [savedVideos] the captions source ids of the saved videos. See
/// `indexesFetchOnly` in search/indexes_share.dart.
List<String> indexesFetchOnlyOf(Iterable<({String kind, String? sourceId})> sources, {Iterable<String> savedVideos = const []}) => {
  ...kIndexKindsAlways,
  // Each saved video's captions ("<instance>/<video uuid>"), on whichever device indexed them.
  for (final v in savedVideos)
    if (v.isNotEmpty) 'captions/${encodeSourceId(v)}',
  for (final s in sources)
    if (s.sourceId != null && s.sourceId!.isNotEmpty)
      for (final kind in kIndexKindsOfSource[s.kind] ?? const <String>[]) '$kind/${encodeSourceId(s.sourceId!)}',
}.toList()..sort();

/// What this device never fetches of the indexes folder, from plain facts: each rejected snapshot's `kind`, `source_id`, `build_id`
/// and the core's own `path` when it gives one. See `indexesNeverFetch` in search/indexes_share.dart.
List<String> indexesNeverFetchOf(Iterable<({String kind, String sourceId, String buildId, String? path})> rejected) => {
  for (final r in rejected)
    if (r.path != null && r.path!.isNotEmpty)
      r.path!
    else if (r.kind.isNotEmpty && r.sourceId.isNotEmpty && r.buildId.isNotEmpty)
      '${r.kind}/${encodeSourceId(r.sourceId)}/snap/${r.buildId}',
}.toList()..sort();
