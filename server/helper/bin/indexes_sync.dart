import 'dart:async';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import 'sharing_host.dart';

/// STUB (tests first): keeps the sharing host's `indexes` fetch list and never-fetch list in step with the core.
class IndexesSync {
  IndexesSync({required this.host, required this.dispatcher, this.savedVideos, this.log});

  final SharingHost host;
  final CoreDispatcher dispatcher;
  final List<Map<String, dynamic>> Function()? savedVideos;
  final void Function(String message)? log;

  Future<void> update() async {}
}

/// STUB (tests first): what the helper does once a sync changed the `indexes` share.
class IndexesShareReaction {
  IndexesShareReaction({required this.refreshSources, required this.kick, this.log});

  final void Function() refreshSources;
  final void Function() kick;
  final void Function(String message)? log;

  void call(Set<String> shareIds) {}
}
