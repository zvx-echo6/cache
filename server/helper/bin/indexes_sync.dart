import 'dart:async';

import '../../../app/lib/search/indexes_fetch.dart';
import '../../../app/lib/sharing/share_rules.dart' show kIndexesShareId;
import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/models.dart' show RejectedSnapshot, SourceStatus;
import 'sharing_host.dart';

/// Keeps the sharing host's `indexes` share lists in step with the core, as the phone's `_syncIndexesOnly` (app/lib/main.dart) does:
/// what this device fetches of the indexes folder ([indexesFetchOnlyOf]: the regions' tile indexes, the index folders of the sources
/// the core has open, and the captions of the saved videos) and what it never fetches ([indexesNeverFetchOf]: the snapshots its core
/// found unusable). The rules are the phone's (app/lib/search/indexes_fetch.dart, which indexes_share.dart wraps); nothing here repeats them.
///
/// [update] runs after the core opens, after every `sources.rescan`, after the own-library run, and when a video is saved or
/// removed. The host keeps the lists for its next open too, and sends a list to the engine only when it changed.
class IndexesSync {
  IndexesSync({required this.host, required this.dispatcher, this.savedVideos, this.log});

  final SharingHost host;
  final CoreDispatcher dispatcher;

  /// The saved videos as cs_video_downloads lists them (`VideoOps.savedVideos`); null: none.
  final List<Map<String, dynamic>> Function()? savedVideos;
  final void Function(String message)? log;

  /// Reads the core's sources and rejected snapshots and the saved videos, and tells the host. A core that is not open yet leaves
  /// the lists as they are.
  Future<void> update() async {
    final List<SourceStatus> statuses;
    final List<RejectedSnapshot> rejected;
    try {
      statuses = [for (final s in (dispatcher.handle('status', const {}) as List)) SourceStatus.fromJson((s as Map).cast<String, dynamic>())];
      rejected = [for (final r in (dispatcher.handle('rejected', const {}) as List)) RejectedSnapshot.fromJson((r as Map).cast<String, dynamic>())];
    } catch (e) {
      log?.call('indexes share: the core\'s sources could not be read: $e');
      return;
    }
    var videos = const <String>[];
    try {
      videos = [for (final v in savedVideos?.call() ?? const <Map<String, dynamic>>[]) _captionsSourceId(v)];
    } catch (e) {
      log?.call('indexes share: the saved videos could not be read: $e');
    }
    try {
      await host.setOnly(kIndexesShareId, indexesFetchOnlyOf([for (final s in statuses) (kind: s.kind, sourceId: s.sourceId)], savedVideos: videos));
      await host.setNeverFetch(kIndexesShareId, indexesNeverFetchOf([for (final r in rejected) (kind: r.kind, sourceId: r.sourceId, buildId: r.buildId, path: r.path)]));
    } catch (e) {
      log?.call('indexes share: the lists could not be sent: $e');
    }
  }

  /// A saved video's captions source id: the core's own (`captions_index.source_id`), else `<instance>/<uuid>` (the phone's rule).
  static String _captionsSourceId(Map<String, dynamic> v) {
    final c = v['captions_index'];
    final id = c is Map ? c['source_id'] : null;
    return id is String && id.isNotEmpty ? id : '${v['instance']}/${v['uuid']}';
  }
}

/// What the helper does once a sync changed the `indexes` share (the indexes branch of the phone's `sharing.onShareChanged`): a
/// snapshot that came by sync is attached when the core is given its sources again, and the index driver is kicked
/// (`sources.refresh()` and `indexing.kick()`). Any other share changing does nothing here.
class IndexesShareReaction {
  IndexesShareReaction({required this.refreshSources, required this.kick, this.log});

  /// Gives the core its sources again (the same as `sources.rescan`).
  final void Function() refreshSources;

  /// Looks for index work now (`IndexDriver.kick`).
  final void Function() kick;
  final void Function(String message)? log;

  void call(Set<String> shareIds) {
    if (!shareIds.contains(kIndexesShareId)) return;
    try {
      refreshSources();
    } catch (e) {
      log?.call('indexes share: the core could not be given its sources again: $e');
    }
    kick();
  }
}
