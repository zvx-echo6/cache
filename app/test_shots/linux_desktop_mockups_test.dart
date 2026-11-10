// Mockups of Cache on Linux's desktop layout for the owner: the app's real frame (Shell, with the DesktopShell sidebar or rail at
// 1024 wide and up) around real screens with sample data, at 1440x900 and 1024x1366, light and dark, plus the same screens at
// 390x844 (the phone layout, unchanged). Screens: Home with the update banner, the Library (list, and a book open in the detail
// pane), Settings > Storage, and the share dialog over Ask. The Library's sample books and the Library rig are copied from
// library11_renders_test.dart, Ask's chat from desktop_renders_test.dart.
// The one stand-in: Shell wires the update check only on iOS and Android, so Home (with its banner) and Ask are drawn by their own
// screens inside DesktopShell, the frame the Shell builds on a Linux desktop window, instead of through Shell.
// flutter test test_shots/linux_desktop_mockups_test.dart --update-goldens  (pictures in test_shots/linux_desktop_mockups/)

import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/library/cds_shelf_source.dart' show libraryDeviceIdShared;
import 'package:cache/linux_ui.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart' show IndexDuty;
import 'package:cache/settings/space.dart';
import 'package:cache/share/share_fallback.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart';
import 'package:cache_search/cache_search.dart' show SearchCore, SourceStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources, catalogWith, fixture, testPolicy;
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart' show SampleBook, writeBookLibrary, writeShelves;
import '../test/nav_fakes.dart';
import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _out = 'linux_desktop_mockups';

const Map<String, Size> _sizes = {'1440x900': Size(1440, 900), '1024x1366': Size(1024, 1366), '390x844': Size(390, 844)};

class _Newer implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => AppUpdate(
    version: '1.1.1',
    build: 999,
    notes: 'Faster library search and a fix for the log.',
    link: Uri.parse('https://cached.info/linux'),
  );
}

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


void _file(Directory d, String name, int bytes) => File('${d.path}/$name').openSync(mode: FileMode.write)
  ..truncateSync(bytes)
  ..closeSync();

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });
  // Bookshelves writes placements in this device's log; the renders draw a device that can.
  libraryDeviceIdShared = () async => 'render-device';
  setUp(() => debugLinuxUi = true);
  tearDown(() => debugLinuxUi = null);

  for (final entry in _sizes.entries) {
    testWidgets('Linux desktop mockups at ${entry.key}', (tester) async {
      final size = entry.value;
      final phoneSize = size.width < 600;
      final inShell = size.width >= 1024;
      final rig = _Rig();
      await rig.make(tester, full: true);
      final r = rig.r;

      // Storage has something in each kind.
      _file(r.libraryDir, 'wikipedia_en_medicine.zim', 940 << 20);
      _file(r.libraryDir, 'wikivoyage_en_idaho.zim', 180 << 20);
      _file(r.mapsDir, 'tiles.sqlite', 410 << 20);
      _file(r.modelsDir, 'gemma-4-E2B-it-Q4_K_M.gguf', 1900 << 20);
      final leftovers = Directory('${r.dir.path}/leftovers')..createSync();
      _file(leftovers, 'x.part', 340 << 20);
      await tester.runAsync(r.app.refreshModels);

      final updates = AppUpdates(source: _Newer(), openUrl: (_) async {}, android: false, linux: true);
      await tester.runAsync(updates.check);

      // The conversation the share dialog is about (from desktop_renders_test.dart).
      r.chat.messages
        ..add(ChatMessage.user('How do I make water from a stream safe to drink?'))
        ..add(ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..text = 'Bring it to a rolling boil for one minute [1]. Above 6,500 feet, boil it for three minutes, because water boils at a '
              'lower temperature as you climb [2]. Let it cool before you drink it, and keep it covered in a clean container.'
          ..sources = const [
            NumberedResult(1, SourceResult(title: 'Water purification', snippet: 'Boiling kills germs: bring the water to a rolling boil for one minute.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Water_purification')),
            NumberedResult(2, SourceResult(title: 'Boiling at altitude', snippet: 'Water boils at a lower temperature as you climb.', address: 'zim:6ba7b810-9dad-11d1-80b4-00c04fd430c8/A/Boiling_point')),
          ]);

      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        final tn = theme == CacheThemeId.dark ? 'dark' : 'light';

        // A new app for each picture, from the defaults (what a picture chose is kept in files in the support folder).
        Future<void> show(Widget page) async {
          phone(tester, size: size, ratio: phoneSize ? 2 : 1);
          for (final f in rig.support.listSync().whereType<File>()) {
            f.deleteSync();
          }
          await tester.pumpWidget(
            shotApp(page, theme: theme, insets: phoneSize ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero, desktop: inShell),
          );
          await _settle(tester);
        }

        Future<void> shot(String id) async {
          final e = tester.takeException();
          final name = '${entry.key}-$id-$tn';
          // ignore: avoid_print
          print('MOCKUP-SHOT $name');
          if (e != null) {
            // ignore: avoid_print
            print('MOCKUP-EXC $name: ${e.toString().split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' | ')}');
          }
          await snap(tester, _out, name);
        }

        // A screen's own widget inside the frame the Shell builds on a desktop window (a phone shows it alone).
        Widget framed(Widget page, {ModuleId? module, bool home = false}) => inShell
            ? DesktopShell(atHome: home, module: module, onHome: () {}, onModule: (_) {}, onModuleOptions: (c, m) {}, child: page)
            : page;

        Future<void> openLibrary() async {
          await tester.tap(inShell ? find.byKey(const ValueKey('desktop-nav-library')) : find.text('Library').first);
          await _settle(tester);
        }

        // ---- a. Home with the update banner ----
        await show(framed(HomeScreen(layout: rig.layout, updates: updates, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}), home: true));
        await shot('home-update-banner');

        // ---- b. Library: the list, and a book open ----
        await show(rig.shell());
        await openLibrary();
        await shot('library-list');

        await show(rig.shell());
        await openLibrary();
        for (final k in ['library-bookshelves', 'shelf-200', 'shelf-210', 'book-aid']) {
          final f = find.byKey(ValueKey(k));
          if (f.evaluate().isEmpty) {
            await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).last);
          }
          await tester.tap(f.first);
          await _settle(tester);
        }
        await shot('library-book-open');

        // ---- c. Settings > Storage ----
        await show(rig.shell());
        if (inShell) {
          await tester.tap(find.byKey(const ValueKey('desktop-nav-settings')));
        } else {
          await tester.tap(find.text('Modules').first);
          await _settle(tester);
          await tester.tap(find.byKey(const ValueKey('module-settings')));
        }
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('settings-storage')));
        await _settle(tester);
        for (var i = 0; i < 40 && !r.storage.measured; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump();
        }
        await _settle(tester);
        await shot('settings-storage');

        // ---- d. The share dialog over Ask ----
        await show(framed(AskScreen(app: r.app, chat: r.chat, location: r.location, layout: rig.layout, onOpenSource: (_) {}, onOpenNavigation: (_) {}), module: ModuleId.ask));
        unawaited(
          showShareFallback(
            tester.element(find.byType(AskScreen)),
            title: 'Share chat',
            blurb: 'Choose how to take this conversation.',
            text: '# Water\n\n**You:** How do I make water from a stream safe to drink?\n\n**Cache:** Bring it to a rolling boil for one minute.',
            fileName: 'Water.md',
          ),
        );
        await _settle(tester);
        await shot('share-dialog');
      }

      await tester.pumpWidget(const SizedBox());
      updates.dispose();
      await rig.dispose(tester);
    });
  }
}
