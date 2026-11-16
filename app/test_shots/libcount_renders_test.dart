// (renders) The Library's "N search indexes" is the number of rows Catalog lists (one list, one count), in every state the core's status can
// be in; and every way into the Library (its tab, Settings > Storage > Library) builds it the same way, with Sharing and Regions.
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'shot_kit.dart';
import 'package:cache_search/cache_search.dart' show SourceStatus, ZimSubIndex;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart';
import '../test/support/settings_rig.dart';
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart';

/// One ZIM whose core status is whatever the test says.
class _Sources extends FakeSources {
  _Sources(super.dir);
  SourceStatus? status;

  @override
  SourceStatus? statusAt(String path) => path.endsWith('gutenberg.zim') ? status : super.statusAt(path);
}

/// One region on the phone, its routing in the state the test says.
class _Regions extends RegionsState {
  _Regions({required super.policy, required super.supportDir, required super.catalogue, required super.maps});
  String routing = 'ready';

  @override
  List<LocalRegion> get local => [LocalRegion(id: 'idaho-falls', name: 'Idaho Falls', routing: {'state': routing})];
}

SourceStatus _zim({ZimSubIndex? epub, ZimSubIndex? captions}) => SourceStatus(
  id: 'gid', kind: 'zim', path: 'gutenberg.zim', title: 'Gutenberg', indexed: true, building: false, stale: false, opening: false, updating: false, docs: 1,
  sourceId: 'gid', epubIndex: epub, captionsIndex: captions,
);

void main() {
  setUpAll(loadShotFonts);

  late Directory tmp;
  late _Sources sources;
  late _Regions regions;
  late SettingsRig rig;
  late BrowseState browse;
  late CdsShelfSource shelves;
  late LibrariesState libs;

  Future<SettingsHub> world(WidgetTester tester) async {
    tmp = Directory.systemTemp.createTempSync('library-count-shot');
    rig = await SettingsRig.create(tester);
    phone(tester, size: const Size(390, 844), ratio: 2);
    await tester.runAsync(() async {
      sources = _Sources(Directory('${tmp.path}/zims')..createSync(recursive: true));
      File('${sources.zimsDir!.path}/gutenberg.zim').writeAsBytesSync(List.filled(16, 0));
      await sources.refresh();
      sources.ready.add(sources.zims.single.path);
      sources.ids[sources.zims.single.path] = 'gid';
      libs = await librariesAt(Directory('${tmp.path}/libraries')..createSync(recursive: true), sources);
      final dir = writeShelves(Directory('${tmp.path}/bookshelves'), placed: const [], checked: const []);
      shelves = CdsShelfSource(libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => dir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
      await shelves.whenRead();
      browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    });
    regions = _Regions(policy: rig.policy, supportDir: () async => tmp, catalogue: RegionCatalogue(dir: () async => tmp), maps: rig.maps);
    addTearDown(() {
      shelves.dispose();
      browse.dispose();
      libs.dispose();
      sources.dispose();
    });
    final h = rig.hub;
    return SettingsHub(settings: h.settings, policy: h.policy, webSearch: h.webSearch, storage: h.storage, weather: h.weather, sharing: h.sharing, regions: regions);
  }

  Future<void> shots(WidgetTester tester, Widget Function() screen, String name) async {
    await tester.pumpWidget(shotApp(screen(), theme: CacheThemeId.light));
    await tester.pump();
    await snap(tester, 'libcount', '$name-1-library');
    await tester.tap(find.byKey(const ValueKey('library-catalog')));
    await tester.pumpAndSettle();
    await snap(tester, 'libcount', '$name-2-catalog');
  }

  testWidgets('Library from the tab and from Storage (after), and Storage as it was (before)', (tester) async {
    final hub = await world(tester);
    sources.status = _zim(epub: const ZimSubIndex(state: 'ready', kind: 'zim-epub', sourceId: 'gid', needsBuild: false, entries: 3));
    await shots(tester, () => BrowseScreen.inHub(browse: browse, active: true, hub: hub), 'after-tab');
    await shots(tester, () => BrowseScreen.inHub(browse: browse, active: true, hub: hub), 'after-storage');
    // before: Storage built the screen by hand, with no regions and no sharing
    await shots(tester, () => BrowseScreen(browse: browse, active: true), 'before-storage');
    // the EPUB index while the core is still opening it: before this fix its row (and one in the count) was missing
    sources.status = _zim(epub: const ZimSubIndex(state: 'opening', kind: 'zim-epub', sourceId: 'gid'));
    await shots(tester, () => BrowseScreen.inHub(browse: browse, active: true, hub: hub), 'after-opening');
    tmp.deleteSync(recursive: true);
  });
}
