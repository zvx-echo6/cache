// The 1.1 Library for review, drawn by the app itself in the app's frame with sample data (no personal data): a phone (390 x
// 844), a tablet upright (820 x 1180, the bottom bar and two panes), sideways (1180 x 820, the rail and three panes) and a
// desktop window (1440 x 900), light and dark. Books are a sample library of books on this device (documents.tsv, packs and a seed
// log, as cache-build writes them); this device has no PDF copies yet, as a phone in 1.1.
// The app tests have no native library: Bookshelves gets a stand-in core (the app tests' FakeShelvesCalls behind the core's
// Bookshelves calls) and an app support folder in the rig's temp folder, so its view is made and the books are on their shelves.
// flutter test test_shots/library11_renders_test.dart --update-goldens  (pictures in test_shots/library11/)

import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/library/cds_shelf_source.dart' show libraryDeviceIdShared;
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart' show IndexDuty;
import 'package:cache/settings/space.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show SearchCore, SourceStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources, catalogWith, fixture, testPolicy;
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart' show SampleBook, writeBookLibrary, writeShelves;
import '../test/nav_fakes.dart';
import '../test/support/settings_rig.dart';
import 'beta_sizes.dart';
import 'shot_kit.dart';

const _out = 'library11';

/// The sizes drawn (the beta checklist's with BETA_SIZES, see beta_sizes.dart).
final Map<String, Size> kSizes = kBeta
    ? kBetaSizes
    : const {
        '390': Size(390, 844),
        '820': Size(820, 1180),
        '1180': Size(1180, 820),
        '1440': Size(1440, 900),
      };

/// The search core's word on the sample library: open and searchable.
class _Sources extends FakeSources {
  _Sources(super.dir);

  String? libraryShard;

  /// The core Bookshelves asks for (the Library builds its own shelf source over these sources).
  SearchCore? shelvesCore;

  @override
  Future<SearchCore?> whenCoreReady() async => shelvesCore;

  @override
  SourceStatus? statusAt(String path) => path == libraryShard
      ? SourceStatus(id: 'field', kind: 'library', path: path, title: 'Field library', indexed: true, building: false, stale: false, opening: false, updating: false, docs: 9412, sourceId: 'field')
      : super.statusAt(path);
}

/// A core that answers only the Bookshelves calls, through the app tests' stand-in for them.
class _ShelvesCore implements SearchCore {
  final FakeShelvesCalls _calls = FakeShelvesCalls();

  @override
  Future<List<Map<String, dynamic>>> shelvesDetect(Map<String, dynamic> args) => _calls.detect(args);
  @override
  Future<Map<String, dynamic>> shelvesAppend(Map<String, dynamic> args) => _calls.append(args);
  @override
  Future<Map<String, dynamic>> shelvesResolve(Map<String, dynamic> args) => _calls.resolve(args);
  @override
  Future<Map<String, dynamic>> shelvesImport(Map<String, dynamic> args) => _calls.import(args);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const MethodChannel _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

class _Run implements IndexRun {
  final Completer<bool> _done = Completer<bool>();
  @override
  void setDuty(IndexDuty duty) {}
  @override
  Future<bool> get finished => _done.future;
  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    if (!_done.isCompleted) _done.complete(false);
  }
}

class _Work implements IndexWorkSource {
  @override
  Future<List<IndexTask>> pending() async => [
    IndexTask(key: 'zim/m1', title: 'Medical encyclopedia', progress: () => (340, 5768), start: () async => _Run()),
    IndexTask(key: 'zim/c1', title: 'Cooking', start: () async => _Run()),
  ];
}

const List<SampleBook> _books = [
  ('aid', 'Wilderness first aid handbook', '210', '220'),
  ('surgery', 'Emergency war surgery', '210', null),
  ('nodoctor', 'Where there is no doctor', '210', '230'),
  ('trauma', 'Field guide to trauma care', '210', null),
  ('burns', 'Burns and wound care', '210', null),
  ('cpr', 'CPR and choking, illustrated', '210', null),
  ('disaster', 'Disaster medicine basics', '210', null),
  ('anatomy', 'Anatomy for first responders', '220', null),
  ('diseases', 'Common diseases and their treatment', '230', null),
  ('herbal', 'Herbal remedies of the mountain west', '250', null),
  ('garden', 'Square foot gardening', '310', null),
  ('hives', 'Beekeeping basics', '350', null),
  ('camp', 'Camp cooking', '410', null),
  ('canning', 'The complete book of home canning', '440', null),
  ('water', 'The water purification handbook', '530', null),
  ('solar', 'Off-grid solar power', '560', null),
  ('carpentry', 'Basic carpentry', '610', null),
  ('ham', 'Ham radio operating guide', '720', null),
  ('bushcraft', 'Bushcraft 101', '810', null),
  ('compass', 'Map and compass', '870', null),
  ('safety', 'Firearm safety', '910', null),
];

const List<SampleBook> _unsorted = [
  ('engines', 'Small engine repair', '670', '690'),
  ('bees', 'Keeping bees in cold climates', '350', '190'),
  ('radio', 'Field radio handbook', '720', '710'),
  ('cellar', 'Root cellar plans', '470', '610'),
];

String _seed() {
  final b = StringBuffer();
  final seq = <String, int>{};
  for (final x in _books) {
    final n = (seq[x.$3!] ?? 0) + 1;
    seq[x.$3!] = n;
    b
      ..writeln('{"v":1,"at":1793491200000,"dev":"builder-field","ev":"place","doc":"${x.$1}","div":"${x.$3}","by":"auto"}')
      ..writeln('{"v":1,"at":1793491200000,"dev":"builder-field","ev":"assign","doc":"${x.$1}","div":"${x.$3}","seq":$n}');
  }
  return b.toString();
}

String _feed() =>
    '<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/"><id>sample</id><title>Entries</title>'
    '<totalResults>1</totalResults><startIndex>0</startIndex><itemsPerPage>1</itemsPerPage>'
    '<entry><id>urn:uuid:00000000-0000-4000-8000-000000000001</id><title>WikiMed</title><updated>2026-10-01T00:00:00Z</updated><summary>Medical encyclopedia</summary>'
    '<language>eng</language><name>wikimed_en</name><flavour>maxi</flavour><category>other</category><tags>_category:other</tags><articleCount>1000</articleCount>'
    '<dc:issued>2026-10-01T00:00:00Z</dc:issued><link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://example.invalid/wikimed.zim" length="2306867200"/></entry></feed>';

Future<String> _catalogue(Uri u) async {
  if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
  if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
  return _feed();
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// The Library's own faces, bundled with the app (assets/fonts): Roboto Mono for numbers, Libre Baskerville for the catalogue card.
Future<void> _loadLibraryFonts() async {
  for (final (family, asset) in [('Roboto Mono', 'assets/fonts/RobotoMono-Bold.ttf'), ('Libre Baskerville', 'assets/fonts/LibreBaskerville-Variable.ttf')]) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.view(File(asset).readAsBytesSync().buffer)));
    await loader.load();
  }
}

class _Rig {
  late SettingsRig r;
  late _Sources sources;
  late LibrariesState libs;
  late BrowseState browse;
  late LayoutState layout;
  late NavState nav;
  IndexScheduler? scheduler;
  late Directory support;

  Future<void> make(WidgetTester tester, {required bool full}) async {
    r = await SettingsRig.create(tester);
    layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final libsDir = Directory('${r.dir.path}/libraries')..createSync();
    sources = _Sources(Directory('${r.dir.path}/zims11')..createSync())..shelvesCore = _ShelvesCore();
    // the app support folder (Bookshelves keeps its log in bookshelves/ there)
    support = Directory('${r.dir.path}/support11')..createSync();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathProvider, (call) async => support.path);
    if (full) {
      writeBookLibrary(
        libsDir,
        'field',
        [..._books, ..._unsorted],
        log: _seed(),
        compression: {'original_size': 58 << 20, 'stored_size': 41 << 20, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false},
        // most books' PDFs are on this device; "Where there is no doctor" is not
        pdfs: {for (final b in [..._books, ..._unsorted]) if (b.$1 != 'nodoctor') b.$1},
        // a later pack revision's author and edition, to show the card's lines (revision 4 packs carry neither)
        extra: {
          'surgery': {'author': 'Borden Institute', 'edition': '5th edition', 'year': 2018},
        },
      );
      // the unsorted books were seen before and left unsorted; the others are new here, so Bookshelves shelves each in its
      // suggested division with the next free number, as on a phone
      writeShelves(Directory('${support.path}/bookshelves'), checked: [for (final b in _unsorted) b.$1], dev: 'render-device');
    }
    sources.libraryShard = '${libsDir.path}/field/shard';
    libs = LibrariesState(sources: sources, dirOverride: libsDir);
    await tester.runAsync(() async {
      libs.dir = libsDir;
      await libs.rescan();
    });
    browse = BrowseState(sources: sources, catalog: catalogWith(_catalogue), policy: testPolicy(), libraries: libs, settingsDirOverride: r.dir, iconFetch: (_) async => null, phoneLanguage: 'en');
    await tester.runAsync(browse.init);
    if (full) {
      final z = sources.zimsDir!.path;
      sources.zims = [
        ZimFile(path: '$z/wikipedia_en_all_maxi_2026-02.zim', size: 118 << 30),
        ZimFile(path: '$z/wikimed_en_all_maxi_2026-01.zim', size: 940 << 20),
        ZimFile(path: '$z/field_manuals_2026-03.zim', size: 7700 << 20),
        ZimFile(path: '$z/cooking.stackexchange.com_en_all_2026-02.zim', size: 29 << 20),
      ];
      final names = ['Wikipedia', 'Medical encyclopedia', 'Field manuals', 'Cooking'];
      final ids = ['w1', 'm1', 'f1', 'c1'];
      for (var i = 0; i < 4; i++) {
        sources.titles[sources.zims[i].path] = names[i];
        sources.ids[sources.zims[i].path] = ids[i];
        if (i != 1 && i != 3) sources.ready.add(sources.zims[i].path);
      }
      final s = IndexScheduler(sources: [_Work()], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => const BatteryReading(percent: 90, charging: true), every: const Duration(hours: 1));
      scheduler = s;
      indexSchedulerShared = s;
      s.setOpen(true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  }

  Widget shell() => Shell(app: r.app, chat: r.chat, sources: sources, location: r.location, maps: r.maps, video: r.video, browse: browse, nav: nav, layout: layout, hub: r.hub);

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    scheduler?.dispose();
    indexSchedulerShared = null;
    nav.dispose();
    browse.dispose();
    libs.dispose();
    layout.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathProvider, null);
    await r.dispose(tester);
  }
}

/// Opens the Library in the app's frame at [size], then taps [path] (keys) in turn, and draws it as [name].
Future<void> _shoot(WidgetTester tester, _Rig rig, String size, String name, List<String> path, CacheThemeId theme) async {
  final s = kSizes[size]!;
  phone(tester, size: s, ratio: kBeta ? betaRatio(s) : (size == '390' ? 2 : 1));
  // each picture starts from the defaults: what a picture chose (the Bookshelves look, a hidden list) is kept in files in the
  // support folder, and only the Bookshelves log (bookshelves/) carries over
  for (final f in rig.support.listSync().whereType<File>()) {
    f.deleteSync();
  }
  await tester.pumpWidget(shotApp(rig.shell(), theme: theme, insets: kBeta ? betaInsets(s) : (size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero)));
  await _settle(tester);
  await tester.tap(find.text('Library').first);
  await _settle(tester);
  for (final k in path) {
    final f = find.byKey(ValueKey(k));
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).last);
    }
    await tester.tap(f.first);
    await _settle(tester);
  }
  await snap(tester, _out, '$size-$name-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });
  // Bookshelves writes placements in this device's log; the renders draw a device that can.
  libraryDeviceIdShared = () async => 'render-device';

  const shelves = ['library-bookshelves'];
  const division = [...shelves, 'shelf-200', 'shelf-210'];
  const book = [...division, 'book-aid'];
  const bookCard = [...division, 'book-surgery'];
  const bookNotHere = [...division, 'book-nodoctor'];
  const unsorted = [...shelves, 'shelves-unsorted'];

  const phoneScreens = <String, List<String>>{
    'root': [],
    'zims': ['library-zims'],
    'shelves-list': shelves,
    'shelves-drawers': [...shelves, 'look-drawers'],
    'shelves-spines': [...shelves, 'look-spines'],
    'class': [...shelves, 'shelf-200'],
    'division': division,
    'book': book,
    'book-card-lines': bookCard,
    'book-not-here': bookNotHere,
    'delete-book': [...book, 'book-delete'],
    'unsorted': unsorted,
    'place-it': [...unsorted, 'all-divisions-bees'],
    'place-it-all-divisions': [...unsorted, 'all-divisions-bees', 'place-all-divisions'],
    'catalog': ['library-catalog'],
    'docs': ['library-docs'],
  };

  const wideScreens = <String, List<String>>{
    'root': [],
    'zims': ['library-zims'],
    'shelves': shelves,
    'shelves-drawers': [...shelves, 'look-drawers'],
    'shelves-spines': [...shelves, 'look-spines'],
    'class': [...shelves, 'shelf-200'],
    'division': division,
    'division-book': book,
    'division-book-not-here': bookNotHere,
    'hide-list': [...book, 'library-hide-list'],
    'unsorted-place-it': [...unsorted, 'all-divisions-bees'],
    'catalog': ['library-catalog'],
    'docs': ['library-docs'],
  };

  for (final size in kSizes.keys) {
    testWidgets('Library 1.1 at $size', (tester) async {
      final rig = _Rig();
      await rig.make(tester, full: true);
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        for (final e in ((kBeta ? betaOnePane(kSizes[size]!) : size == '390') ? phoneScreens : wideScreens).entries) {
          await _shoot(tester, rig, size, e.key, e.value, theme);
        }
      }
      await rig.dispose(tester);
    });
  }

  testWidgets('Library 1.1, nothing yet', (tester) async {
    final rig = _Rig();
    await rig.make(tester, full: false);
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      for (final size in kBeta ? kBetaSizes.keys : const ['390', '1440']) {
        await _shoot(tester, rig, size, 'empty-root', const [], theme);
        await _shoot(tester, rig, size, 'empty-zims', const ['library-zims'], theme);
        await _shoot(tester, rig, size, 'empty-shelves', const ['library-bookshelves'], theme);
        await _shoot(tester, rig, size, 'empty-catalog', const ['library-catalog'], theme);
      }
    }
    await rig.dispose(tester);
  });
}
