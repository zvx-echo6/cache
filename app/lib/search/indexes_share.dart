import 'package:cache_search/cache_search.dart' show RejectedSnapshot, SourceStatus;

import 'indexes_fetch.dart';

// kIndexesDirName lives in indexes_dir.dart: the Cache Server helper (plain Dart, no Flutter packages) reads core_config.dart too.
export 'indexes_dir.dart' show kIndexesDirName;
export 'indexes_fetch.dart' show kIndexKindsOfSource, kIndexKindsAlways, encodeSourceId, indexesFetchOnlyOf, indexesNeverFetchOf;
export '../sharing/share_rules.dart' show kIndexesShareId, kIndexesNotShared, kIndexesHidden, kIndexesLocalDeletes, kIndexesLast;

/// The device's syncable search indexes (the core's `indexes_dir`): one folder, `<kind>/<source id>/`, each with its working
/// `.build/` and its sealed snapshots `snap/<build-id>/` (manifest.json written last). It is shared with every linked device
/// once sharing is set up, whatever kinds are ticked, so an index reaches any device that has the same source, even when the
/// source itself does not sync (two phones with the same ZIM, each downloaded on its own).

/// What this device fetches of the indexes folder: the regions' tile indexes ([kIndexKindsAlways]), the captions of the videos
/// saved here ([savedVideos], their `<instance>/<uuid>`), and the index folders of the sources the core has open (their
/// `source_id` in cs_status), every kind each of them has. A source the core could not open (no source id) fetches nothing.
List<String> indexesFetchOnly(Iterable<SourceStatus> sources, {Iterable<String> savedVideos = const []}) =>
    indexesFetchOnlyOf([for (final s in sources) (kind: s.kind, sourceId: s.sourceId)], savedVideos: savedVideos);

/// What this device never fetches of the indexes folder: the snapshots its core found unusable and removed. Sync already keeps
/// a snapshot this device deleted from coming back (the delete stays here); this holds even when that record is gone.
/// The core's own "path" when it gives one (the folder name exactly as it wrote it), else built the same way.
List<String> indexesNeverFetch(Iterable<RejectedSnapshot> rejected) =>
    indexesNeverFetchOf([for (final r in rejected) (kind: r.kind, sourceId: r.sourceId, buildId: r.buildId, path: r.path)]);
