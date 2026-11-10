// The phone guard: the phone's screens drawn at 390 x 844 and 844 x 390, light and dark, compared pixel for pixel with the pictures
// kept in goldens/. They were drawn on rel-1.1, before the Linux desktop work; the desktop work sits behind isLinuxDesktop (Linux and a
// window 1024 wide or more), so a phone screen must come out identical. A failure here means a phone screen changed.
//
// The pictures are made by the Renders workflow (flutter test --update-goldens) on the same runner image the Tests job uses. They are
// compared on Linux only: another system draws text a little differently, so the tests are skipped elsewhere.
// Use only what rel-1.1 has: this file is copied unchanged to the desktop branch.

import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/library/cds_shelf_source.dart' show libraryDeviceIdShared;
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/hub.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart';
import 'package:cache/update/update_ui.dart';
import 'package:cache_search/cache_search.dart' show SearchCore, SourceStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_shots/shot_kit.dart';
import '../browse/fakes.dart' show FakeSources, catalogWith, fixture, testPolicy;
import '../library/fake_shelves.dart';
import '../library/library_fixtures.dart' show SampleBook, writeBookLibrary, writeShelves;
import '../nav_fakes.dart';
import '../support/settings_rig.dart';
import '../support/sync_fake.dart';

/// Where the pictures are (next to this file).
const String _dir = 'goldens/';

/// A phone upright and held sideways.
const Map<String, Size> _sizes = {'portrait': Size(390, 844), 'landscape': Size(844, 390)};

/// The pictures are drawn on Linux; text on another system differs by a pixel here and there, so the tests run on Linux only.
final bool _skip = !Platform.isLinux;

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

String _t(CacheThemeId theme) => theme == CacheThemeId.dark ? 'dark' : 'light';

/// Draws [page] in the app's frame on a phone of [size] (one pixel to a point), and settles.
Future<void> _show(WidgetTester tester, Widget page, String size, CacheThemeId theme) async {
  phone(tester, size: _sizes[size]!, ratio: 1);
  final insets = size == 'portrait' ? const EdgeInsets.only(top: 44, bottom: 30) : const EdgeInsets.only(left: 44, right: 44, bottom: 20);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: insets));
  await _settle(tester);
}

Future<void> _snap(WidgetTester tester, String name, String size, CacheThemeId theme) =>
    expectLater(find.byType(MaterialApp).first, matchesGoldenFile('$_dir$name-$size-${_t(theme)}.png'));

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first);
  await _settle(tester);
}

// ---- the sample library (the Library tests' rig, trimmed)

class _Sources extends FakeSources {
  _Sources(super.dir);

  String? libraryShard;
  SearchCore? shelvesCore;

  @override
  Future<SearchCore?> whenCoreReady() async => shelvesCore;

  @override
  SourceStatus? statusAt(String path) => path == libraryShard
      ? SourceStatus(id: 'field', kind: 'library', path: path, title: 'Field library', indexed: true, building: false, stale: false, opening: false, updating: false, docs: 9412, sourceId: 'field')
      : super.statusAt(path);
}

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

const List<SampleBook> _books = [
  ('aid', 'Wilderness first aid handbook', '210', '220'),
  ('surgery', 'Emergency war surgery', '210', null),
  ('nodoctor', 'Where there is no doctor', '210', '230'),
  ('trauma', 'Field guide to trauma care', '210', null),
  ('burns', 'Burns and wound care', '210', null),
  ('anatomy', 'Anatomy for first responders', '220', null),
  ('diseases', 'Common diseases and their treatment', '230', null),
  ('herbal', 'Herbal remedies of the mountain west', '250', null),
  ('garden', 'Square foot gardening', '310', null),
  ('water', 'The water purification handbook', '530', null),
];

const List<SampleBook> _unsorted = [
  ('engines', 'Small engine repair', '670', '690'),
  ('bees', 'Keeping bees in cold climates', '350', '190'),
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

/// The Library's own faces, bundled with the app (assets/fonts).
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
  late Directory support;

  Future<void> make(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
    final libsDir = Directory('${r.dir.path}/libraries')..createSync();
    sources = _Sources(Directory('${r.dir.path}/zims11')..createSync())..shelvesCore = _ShelvesCore();
    support = Directory('${r.dir.path}/support11')..createSync();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathProvider, (call) async => support.path);
    writeBookLibrary(
      libsDir,
      'field',
      [..._books, ..._unsorted],
      log: _seed(),
      compression: {'original_size': 58 << 20, 'stored_size': 41 << 20, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false},
      pdfs: {for (final b in [..._books, ..._unsorted]) if (b.$1 != 'nodoctor') b.$1},
      extra: {
        'surgery': {'author': 'Borden Institute', 'edition': '5th edition', 'year': 2018},
      },
    );
    writeShelves(Directory('${support.path}/bookshelves'), checked: [for (final b in _unsorted) b.$1], dev: 'render-device');
    sources.libraryShard = '${libsDir.path}/field/shard';
    libs = LibrariesState(sources: sources, dirOverride: libsDir);
    await tester.runAsync(() async {
      libs.dir = libsDir;
      await libs.rescan();
    });
    browse = BrowseState(sources: sources, catalog: catalogWith(_catalogue), policy: testPolicy(), libraries: libs, settingsDirOverride: r.dir, iconFetch: (_) async => null, phoneLanguage: 'en');
    await tester.runAsync(browse.init);
    final z = sources.zimsDir!.path;
    sources.zims = [
      ZimFile(path: '$z/wikipedia_en_all_maxi_2026-02.zim', size: 118 << 30),
      ZimFile(path: '$z/wikimed_en_all_maxi_2026-01.zim', size: 940 << 20),
      ZimFile(path: '$z/field_manuals_2026-03.zim', size: 7700 << 20),
    ];
    final names = ['Wikipedia', 'Medical encyclopedia', 'Field manuals'];
    final ids = ['w1', 'm1', 'f1'];
    for (var i = 0; i < 3; i++) {
      sources.titles[sources.zims[i].path] = names[i];
      sources.ids[sources.zims[i].path] = ids[i];
      if (i != 1) sources.ready.add(sources.zims[i].path);
    }
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  }

  Widget shell() => Shell(app: r.app, chat: r.chat, sources: sources, location: r.location, maps: r.maps, video: r.video, browse: browse, nav: nav, layout: layout, hub: r.hub);

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    browse.dispose();
    libs.dispose();
    layout.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathProvider, null);
    await r.dispose(tester);
  }
}

/// A new Shell at [size]; taps [path] (keys) in turn after [tab] (the bar's or rail's label, or null for Home).
Future<void> _shoot(WidgetTester tester, _Rig rig, String size, CacheThemeId theme, String name, {String? tab, List<String> path = const []}) async {
  // each picture starts from the defaults: what a picture chose is kept in files in the support folder
  for (final f in rig.support.listSync().whereType<File>()) {
    f.deleteSync();
  }
  await _show(tester, rig.shell(), size, theme);
  if (tab != null) {
    final label = find.text(tab).first;
    await tester.ensureVisible(label);
    await tester.pump();
    await tester.tap(label);
    await _settle(tester);
  }
  for (final k in path) {
    final f = find.byKey(ValueKey(k));
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).last);
    }
    await tester.tap(f.first);
    await _settle(tester);
  }
  await _snap(tester, name, size, theme);
}

class _Newer implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => const AppUpdate(version: '9.9.9', build: 999);
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });
  libraryDeviceIdShared = () async => 'render-device';

  testWidgets('phone guard: Home and Library in the app frame', (tester) async {
    final rig = _Rig();
    await rig.make(tester);
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _shoot(tester, rig, size, theme, 'shell-home');
        await _shoot(tester, rig, size, theme, 'library-root', tab: 'Library');
        await _shoot(tester, rig, size, theme, 'library-shelves', tab: 'Library', path: ['library-bookshelves']);
        await _shoot(tester, rig, size, theme, 'library-shelf', tab: 'Library', path: ['library-bookshelves', 'shelf-200', 'shelf-210']);
      }
    }
    await rig.dispose(tester);
  }, skip: _skip);

  testWidgets('phone guard: Settings and Storage', (tester) async {
    final r = await SettingsRig.create(tester);
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _show(tester, SettingsScreen(deps: r.deps), size, theme);
        await _snap(tester, 'settings-list', size, theme);
        await _tapKey(tester, 'settings-storage');
        // the folders are measured by now; the checksums follow, so wait for them too
        await _settle(tester, 20);
        await _snap(tester, 'settings-storage', size, theme);
      }
    }
    await _show(tester, const SizedBox(), 'portrait', CacheThemeId.light);
    await r.dispose(tester);
  }, skip: _skip);

  testWidgets('phone guard: Ask with a chat', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    await tester.runAsync(layout.init);
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
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _show(tester, AskScreen(app: r.app, chat: r.chat, location: r.location, layout: layout, onOpenSource: (_) {}, onOpenNavigation: (_) {}), size, theme);
        await _snap(tester, 'ask-chat', size, theme);
      }
    }
    await _show(tester, const SizedBox(), 'portrait', CacheThemeId.light);
    layout.dispose();
    await r.dispose(tester);
  }, skip: _skip);

  testWidgets('phone guard: the link-code dialog in Sharing and sync', (tester) async {
    final r = await SettingsRig.create(tester);
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: [DataKind(id: 'models', label: 'Models', icon: Icons.memory, shared: () => {'models': r.modelsDir})],
      deviceName: 'Test phone',
      opener: (_) async => FakeSync(),
    );
    await tester.runAsync(sharing.setUp);
    r.hub = SettingsHub(
      sharing: sharing,
      settings: r.settings,
      policy: r.policy,
      webSearch: r.webSearch,
      storage: r.storage,
      weather: r.weather,
      openUrl: (u) async => r.opened.add(u),
    );
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _show(tester, SettingsScreen(deps: r.deps), size, theme);
        await _tapKey(tester, 'settings-sharing');
        await _tapKey(tester, 'enter-code');
        expect(find.byType(AlertDialog), findsOneWidget);
        await _snap(tester, 'share-dialog', size, theme);
      }
    }
    await _show(tester, const SizedBox(), 'portrait', CacheThemeId.light);
    sharing.dispose();
    await r.dispose(tester);
  }, skip: _skip);

  testWidgets('phone guard: the update banner on Home', (tester) async {
    final dir = Directory.systemTemp.createTempSync('phone-guard-home');
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final updates = AppUpdates(source: _Newer(), openUrl: (_) async {}, android: true);
    await tester.runAsync(updates.check);
    expect(updates.bannerShown, isTrue);
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _show(tester, HomeScreen(layout: layout, updates: updates, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}), size, theme);
        expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);
        await _snap(tester, 'home-update-banner', size, theme);
      }
    }
    await _show(tester, const SizedBox(), 'portrait', CacheThemeId.light);
    layout.dispose();
    updates.dispose();
    dir.deleteSync(recursive: true);
  }, skip: _skip);
}
