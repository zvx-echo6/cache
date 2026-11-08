// The Bookshelves log's screens for review, drawn by the app itself with sample data (no personal data): a division whose first-aid
// book has two spare copies, that book's page (Spare copies, Also known as, Read this copy instead, Not the same book, Rename,
// Hide from Bookshelves), the Rename sheet and the Same book as… picker, on a phone (390 x 844) and a desktop window (1440 x 900), light and dark. The books come from two sample
// libraries as cache-build writes them; which files are one book is decided by a stand-in for the core (test/library/fake_shelves.dart).
// flutter test test_shots/bookshelves_renders_test.dart --update-goldens  (pictures in test_shots/bookshelves/)

import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources, testPolicy;
import '../test/library/fake_shelves.dart';
import '../test/library/library_fixtures.dart' show SampleBook, testDeps, writeBookLibrary;
import 'shot_kit.dart';

const _out = 'bookshelves';

const Map<String, Size> kSizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

const List<SampleBook> _field = [
  ('aid', 'Wilderness first aid handbook', '210', null),
  ('aid2', 'Wilderness First Aid, 2nd printing', '210', null),
  ('surgery', 'Emergency war surgery', '210', null),
  ('nodoctor', 'Where there is no doctor', '210', null),
  ('trauma', 'Field guide to trauma care', '210', null),
  ('burns', 'Burns and wound care', '210', null),
  ('cpr', 'CPR and choking, illustrated', '210', null),
  ('water', 'The water purification handbook', '530', null),
];

const List<SampleBook> _home = [
  ('wfa-scan', 'WFA handbook (scan)', '210', null),
  ('hives', 'Beekeeping basics', '350', null),
];

Future<void> _loadLibraryFonts() async {
  for (final (family, asset) in [('Roboto Mono', 'assets/fonts/RobotoMono-Bold.ttf'), ('Libre Baskerville', 'assets/fonts/LibreBaskerville-Variable.ttf')]) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.view(File(asset).readAsBytesSync().buffer)));
    await loader.load();
  }
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    await _loadLibraryFonts();
  });

  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;

  Future<void> make() async {
    tmp = Directory.systemTemp.createTempSync('bookshelves-renders');
    final root = Directory('${tmp.path}/libraries');
    const compression = {'original_size': 58 << 20, 'stored_size': 41 << 20, 'level': 'smaller_scans', 'preset': 'balanced', 'kept_original': false};
    const same = {'minhash': [1, 2, 3]};
    writeBookLibrary(root, 'field', _field, compression: compression, pdfs: {for (final b in _field) b.$1},
        samebook: {'aid': same, 'aid2': same}, extra: {'aid': {'author': 'Paul S. Auerbach', 'edition': '7th edition', 'year': 2017}});
    writeBookLibrary(root, 'home', _home, samebook: {'wfa-scan': same});
    File('${root.path}/home/cache-library.json').writeAsStringSync('{"format":1,"library_id":"home","title":"Home library","version":"1"}');
    // a library made before libraries carried copies.jsonl, downloaded without its packs: Bookshelves says so
    writeBookLibrary(root, 'old', const [('stove', 'Rocket stoves', '590', null), ('soap', 'Soap making', '680', null)]);
    Directory('${root.path}/old/packs').deleteSync(recursive: true);
    File('${root.path}/old/cache-library.json').writeAsStringSync('{"format":1,"library_id":"old","title":"Homestead library","version":"1"}');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = LibrariesState(sources: sources, dirOverride: root, pollInterval: const Duration(milliseconds: 1));
    libs.dir = root;
    await libs.rescan();
    shelves = CdsShelfSource(libs, calls: FakeShelvesCalls(), bookshelvesDir: () async => Directory('${tmp.path}/bookshelves'), deviceId: () async => 'render-device', ownIds: () async => const []);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
  }

  Future<void> shoot(WidgetTester tester, String size, String name, List<String> path, CacheThemeId theme, {String? search, double scroll = 0}) async {
    phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
    final d = testDeps(browse: browse, shelves: shelves);
    await tester.pumpWidget(shotApp(
      LibraryPanes(root: (_) => LibraryRootPage(deps: d), prefs: PanePrefs(dirOverride: tmp)),
      theme: theme,
      insets: size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero,
    ));
    await _settle(tester);
    for (final k in path) {
      final f = find.byKey(ValueKey(k));
      if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).last);
      await tester.ensureVisible(f.first);
      await _settle(tester, 2);
      await tester.tap(f.first);
      await _settle(tester);
    }
    if (search != null) {
      await tester.enterText(find.byKey(const ValueKey('same-search')), search);
      await _settle(tester);
    }
    if (scroll > 0) {
      await tester.drag(find.byType(Scrollable).last, Offset(0, -scroll));
      await _settle(tester);
    }
    await snap(tester, _out, '$size-$name-${theme == CacheThemeId.dark ? 'dark' : 'light'}');
  }

  const division = ['library-bookshelves', 'shelf-200', 'shelf-210'];
  const book = [...division, 'book-aid'];
  const picker = [...division, 'book-surgery', 'book-same-as'];

  for (final size in kSizes.keys) {
    testWidgets('Bookshelves log screens at $size', (tester) async {
      await tester.runAsync(make);
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await shoot(tester, size, 'bookshelves-not-shelved', const ['library-bookshelves'], theme);
        await shoot(tester, size, 'division', division, theme);
        await shoot(tester, size, 'book-spares', book, theme);
        await shoot(tester, size, 'same-book-as', picker, theme);
        await shoot(tester, size, 'same-book-as-search', picker, theme, search: 'first aid');
        await shoot(tester, size, 'rename', [...book, 'book-rename'], theme);
      }
      if (size == '390') {
        // the spares lower down the page on a phone
        for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
          await shoot(tester, size, 'book-spares-scrolled', book, theme, scroll: 520);
          await shoot(tester, size, 'book-rename-hide', book, theme, scroll: 1400);
        }
      }
      await tester.pumpWidget(const SizedBox());
      shelves.dispose();
      browse.dispose();
      libs.dispose();
      sources.dispose();
      await tester.runAsync(() async => tmp.deleteSync(recursive: true));
    });
  }
}
