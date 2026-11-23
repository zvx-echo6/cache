import 'package:test/test.dart';

import '../bin/share_reactions.dart';

/// What the server does when a share's files have settled after a sync (bin/share_reactions.dart): the share id to action mapping,
/// and that each action runs once per change.
void main() {
  List<ShareAction> acts(Iterable<String> ids) => actionsFor(ids.toSet());

  test('each share id maps to what the phone does for it, with the server\'s own machinery', () {
    expect(acts(['library']), [ShareAction.rescanSources]);
    expect(acts(['libraries']), [ShareAction.rescanSources, ShareAction.ownLibraries]);
    expect(acts(['videos']), [ShareAction.indexVideos]);
  });

  test('maps, regions and models need nothing: the layer engine, the region engine and the models route read their folders on demand', () {
    expect(acts(['maps']), isEmpty);
    expect(acts(['regions']), isEmpty);
    expect(acts(['models']), isEmpty);
  });

  test('unknown and not-yet-handled ids do nothing', () {
    expect(acts(['notebooks', 'indexes', 'settings', 'bookshelves', 'nonsense', '']), isEmpty);
    expect(acts([]), isEmpty);
  });

  test('several ids in one change run each action once, in a fixed order', () {
    expect(acts(['videos', 'library', 'libraries', 'maps']), [ShareAction.rescanSources, ShareAction.ownLibraries, ShareAction.indexVideos]);
    expect(acts(['library', 'libraries']), [ShareAction.rescanSources, ShareAction.ownLibraries]);
  });

  test('the reactions call each action once, and only the ones asked for', () {
    final log = <String>[];
    final r = ShareReactions(
      rescanSources: () => log.add('rescan'),
      ownLibraries: () => log.add('own'),
      indexVideos: () => log.add('videos'),
    );
    r.onChanged({'library', 'libraries'});
    expect(log, ['rescan', 'own']);
    log.clear();
    r.onChanged({'videos'});
    expect(log, ['videos']);
    log.clear();
    r.onChanged({'maps', 'regions', 'models', 'what'});
    expect(log, isEmpty);
  });

  test('an action that throws is logged and does not stop the others', () {
    final log = <String>[];
    final msgs = <String>[];
    final r = ShareReactions(
      rescanSources: () => throw StateError('boom'),
      ownLibraries: () => log.add('own'),
      indexVideos: () => log.add('videos'),
      log: msgs.add,
    );
    r.onChanged({'libraries', 'videos'});
    expect(log, ['own', 'videos']);
    expect(msgs.single, contains('boom'));
  });
}
