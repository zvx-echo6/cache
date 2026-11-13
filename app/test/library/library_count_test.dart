// The Library's "N search indexes" is the number of rows Catalog lists (one list, one count), in every state the core's status can
// be in; and every way into the Library (its tab, Settings > Storage > Library) builds it the same way, with Sharing and Regions.
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/library/catalog_page.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/library_panes.dart';
import 'package:cache/regions/region_catalogue.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/regions/regions_state.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show SourceStatus, ZimSubIndex;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import '../support/settings_rig.dart';
import 'fake_shelves.dart';
import 'library_fixtures.dart';

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
  late Directory tmp;
  late _Sources sources;
  late _Regions regions;
  late SettingsRig rig;
  late BrowseState browse;
  late CdsShelfSource shelves;
  late LibrariesState libs;

  setUp(() => tmp = Directory.systemTemp.createTempSync('library-count'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<LibraryDeps> world(WidgetTester tester) async {
    rig = await SettingsRig.create(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
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
    return testDeps(browse: browse, shelves: shelves, regions: regions, sharing: rig.sharing);
  }

  /// The count the Library row says, and the rows Catalog lists, for the same deps.
  Future<(int, int)> countAndRows(WidgetTester tester, LibraryDeps d) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: LibraryPanes(root: (_) => LibraryRootPage(deps: d), prefs: PanePrefs(dirOverride: tmp))));
    await tester.pump();
    final said = RegExp(r'^(\d+) search indexes?$');
    final line = find.byWidgetPredicate((w) => w is Text && said.hasMatch(w.data ?? ''));
    expect(line, findsOneWidget);
    final n = int.parse(said.firstMatch((tester.widget(line) as Text).data!)!.group(1)!);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: CatalogPage(deps: d)));
    await tester.pump();
    return (n, find.byType(CatalogRow).evaluate().length);
  }

  testWidgets('loading: an EPUB index the core is still opening is listed and counted, and the count stays when it is ready', (tester) async {
    final d = await world(tester);
    sources.status = _zim(epub: const ZimSubIndex(state: 'opening', kind: 'zim-epub', sourceId: 'gid'));
    final (n1, rows1) = await countAndRows(tester, d);
    expect(rows1, 3, reason: 'Gutenberg pages, its EPUBs (opening), Idaho Falls routing');
    expect(n1, rows1);
    expect(find.text('Getting ready'), findsWidgets);
    sources.status = _zim(epub: const ZimSubIndex(state: 'ready', kind: 'zim-epub', sourceId: 'gid', needsBuild: false, entries: 3));
    final (n2, rows2) = await countAndRows(tester, d);
    expect((n2, rows2), (n1, rows1), reason: 'opening to ready changes a row, not how many');
  });

  testWidgets('partial: one index ready, one waiting to be built, one region part still downloading', (tester) async {
    final d = await world(tester);
    regions.routing = 'downloading';
    sources.status = _zim(
      epub: const ZimSubIndex(state: 'ready', kind: 'zim-epub', sourceId: 'gid', needsBuild: false, entries: 3),
      captions: const ZimSubIndex(state: 'none', kind: 'zim-captions', sourceId: 'gid', needsBuild: true, entries: 9),
    );
    final (n, rows) = await countAndRows(tester, d);
    expect(rows, 4);
    expect(n, rows);
  });

  testWidgets('ready: everything ready, count equals rows', (tester) async {
    final d = await world(tester);
    sources.status = _zim(epub: const ZimSubIndex(state: 'ready', kind: 'zim-epub', sourceId: 'gid', needsBuild: false, entries: 3));
    final (n, rows) = await countAndRows(tester, d);
    expect((n, rows), (3, 3));
  });

  testWidgets('the Library opened from the hub (tab or Storage) lists Catalog with the sync lines and the routing row, and its count matches', (tester) async {
    await world(tester);
    sources.status = _zim(epub: const ZimSubIndex(state: 'ready', kind: 'zim-epub', sourceId: 'gid', needsBuild: false, entries: 3));
    final h = rig.hub;
    final hub = SettingsHub(settings: h.settings, policy: h.policy, webSearch: h.webSearch, storage: h.storage, weather: h.weather, sharing: h.sharing, regions: regions);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: BrowseScreen.inHub(browse: browse, active: true, hub: hub)));
    await tester.pump();
    expect(find.text('3 search indexes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-catalog')));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogRow), findsNWidgets(3));
    expect(find.text('Not synced: sharing is off'), findsNWidgets(3));
    expect(find.text('ROUTING'), findsOneWidget);
  });

  test('every way into the Library is built by BrowseScreen.inHub, so Storage cannot lose Regions or Sharing', () {
    final main = File('lib/main.dart').readAsStringSync();
    final shell = File('lib/screens/shell.dart').readAsStringSync();
    expect(main.contains('BrowseScreen('), isFalse, reason: 'Storage > Library built the screen by hand, without regions and sharing');
    expect(shell.contains('BrowseScreen('), isFalse);
    expect(main.contains('BrowseScreen.inHub('), isTrue);
    expect(shell.contains('BrowseScreen.inHub('), isTrue);
  });
}
