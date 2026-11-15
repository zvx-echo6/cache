/// What the server does once a shared folder has settled after a sync (SharingHost.onShareChanged), kind by kind, with its own
/// machinery. The phone does the same in main.dart (`sharing.onShareChanged`): the Library reads its folders again.
///
/// - `library` (ZIMs): the core is given its sources again and the index driver looks for work ([ShareAction.rescanSources]).
///   `/api/library/items` lists the folder on every request, so the Library listing needs nothing more.
/// - `libraries` (the person's own libraries): the same, and the own-library run makes My books match their packs
///   ([ShareAction.ownLibraries]).
/// - `videos`: the index driver is kicked; it lists the saved videos again and indexes the captions of each new one
///   ([ShareAction.indexVideos]).
/// - `maps`, `regions`, `models`: nothing. The layer engine opens a tile store when a tile asks for it (a missing one is looked for
///   again within seconds), the region engine checks its tile files on disk when it plans, and the models route lists its folder on
///   each request.
/// - Anything else (notebooks, indexes, settings, the Bookshelves log): later slices.
enum ShareAction { rescanSources, ownLibraries, indexVideos }

/// The actions for the shares that changed, each once, always in the order of [ShareAction].
List<ShareAction> actionsFor(Set<String> shareIds) {
  final out = <ShareAction>{};
  if (shareIds.contains('library') || shareIds.contains('libraries')) out.add(ShareAction.rescanSources);
  if (shareIds.contains('libraries')) out.add(ShareAction.ownLibraries);
  if (shareIds.contains('videos')) out.add(ShareAction.indexVideos);
  return ShareAction.values.where(out.contains).toList();
}

/// Runs [actionsFor]'s actions with the helper's own pieces (given as functions, so a test needs none of them).
class ShareReactions {
  ShareReactions({required this.rescanSources, required this.ownLibraries, required this.indexVideos, this.log});

  final void Function() rescanSources;
  final void Function() ownLibraries;
  final void Function() indexVideos;
  final void Function(String message)? log;

  /// Wire to `SharingHost.onShareChanged`. An action that fails is logged; the others still run.
  void onChanged(Set<String> shareIds) {
    for (final a in actionsFor(shareIds)) {
      try {
        switch (a) {
          case ShareAction.rescanSources:
            rescanSources();
          case ShareAction.ownLibraries:
            ownLibraries();
          case ShareAction.indexVideos:
            indexVideos();
        }
      } catch (e) {
        log?.call('after a sync, ${a.name} failed: $e');
      }
    }
  }
}
