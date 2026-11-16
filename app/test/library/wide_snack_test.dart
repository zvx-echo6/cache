import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/layout/adaptive.dart' show PanePrefs;
import 'package:cache/library/catalog_page.dart';
import 'package:cache/library/cds_shelf_source.dart';
import 'package:cache/library/library_pages.dart';
import 'package:cache/library/library_panes.dart';
import 'package:cache/library/library_prefs.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart' show IndexDuty;
import 'package:cache/settings/space.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse/fakes.dart';
import 'fake_shelves.dart';
import 'library_fixtures.dart';

const _seed = '''
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"aid","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"aid","div":"210","seq":1}
{"v":1,"at":1000,"dev":"builder-field","ev":"place","doc":"surgery","div":"210","by":"auto"}
{"v":1,"at":1000,"dev":"builder-field","ev":"assign","doc":"surgery","div":"210","seq":2}
''';

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
  final List<String> keys = [];
  @override
  Future<List<IndexTask>> pending() async => [
    for (final k in keys) IndexTask(key: k, title: 'Medical encyclopedia', start: () async => _Run()),
  ];
}

void main() {
  late Directory tmp;
  late FakeSources sources;
  late LibrariesState libs;
  late CdsShelfSource shelves;
  late BrowseState browse;
  late FakeShelvesCalls calls;
  var made = false;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('wide-snack');
    writeBookLibrary(Directory('${tmp.path}/libraries'), 'field', const [
      ('aid', 'Wilderness first aid', '210', '220'),
      ('surgery', 'Emergency war surgery', '210', null),
      ('bees', 'Keeping bees in cold climates', '350', '190'),
      ('engines', 'Small engine repair', '670', '690'),
      ('stone', 'Stone', null, null),
    ], log: _seed);
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync(recursive: true));
    libs = await librariesAt(Directory('${tmp.path}/libraries'), sources);
    final shelvesDir = writeShelves(Directory('${tmp.path}/bookshelves'),
        placed: const [('aid', '210', 1), ('surgery', '210', 2)], checked: const ['aid', 'surgery', 'bees', 'engines', 'stone']);
    calls = FakeShelvesCalls();
    shelves = CdsShelfSource(libs, calls: calls, bookshelvesDir: () async => shelvesDir, deviceId: () async => 'phone-test', ownIds: () async => const [], clock: () => 5000);
    await shelves.whenRead();
    browse = BrowseState(sources: sources, libraries: libs, policy: testPolicy(), settingsDirOverride: tmp, phoneLanguage: 'en');
    made = true;
  });
  tearDown(() {
    if (made) {
      shelves.dispose();
      browse.dispose();
      libs.dispose();
      sources.dispose();
    }
    indexSchedulerShared = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // The browser build's frame: the desktop shell (no Scaffold of its own) with the Library's panes as its page.
  Widget app(LibraryDeps d) => MaterialApp(
    theme: buildTheme(CacheThemeId.light),
    home: DesktopShell(
      onHome: () {},
      onModule: (_) {},
      onModuleOptions: (c, m) {},
      child: LibraryPanes(root: (_) => LibraryRootPage(deps: d), prefs: PanePrefs(dirOverride: tmp)),
    ),
  );

  /// The snackbar a person can see and use: a copy of it whose words, if tapped, are hit by the snackbar itself (a pane too narrow for
  /// the desktop theme's snackbar gives it no width, or clips it, and it is in the tree but never seen).
  Finder seen(WidgetTester tester, String text) {
    for (final e in find.ancestor(of: find.text(text), matching: find.byType(SnackBar)).evaluate()) {
      final at = tester.getCenter(find.descendant(of: find.byElementPredicate((x) => x == e), matching: find.text(text)));
      final hit = HitTestResult();
      tester.binding.hitTestInView(hit, at, tester.view.viewId);
      for (final entry in hit.path) {
        final t = entry.target;
        for (RenderObject? o = t is RenderObject ? t : null; o != null; o = o.parent) {
          if (o == e.renderObject) return find.byElementPredicate((x) => x == e);
        }
      }
    }
    return find.byKey(const ValueKey('no-visible-snackbar'));
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)).first);
    await tester.pumpAndSettle();
  }

  for (final s in [const Size(1440, 900), const Size(1180, 820), const Size(1024, 800)]) {
    testWidgets('wide Library panes at $s: a snackbar raised from a pane shows on screen and its Undo works', (tester) async {
      debugLinuxUi = true;
      addTearDown(() => debugLinuxUi = null);
      tester.view.physicalSize = s;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final d = testDeps(browse: browse, shelves: shelves);
      await tester.pumpWidget(app(d));
      await tapKey(tester, 'library-bookshelves');
      await tapKey(tester, 'shelves-unsorted');
      // a message raised from the left-hand pane (a ZIM's "Check for update" says its result this way)
      final sections = tester.element(find.byKey(const ValueKey('shelves-unsorted')).first);
      ScaffoldMessenger.of(sections).showSnackBar(const SnackBar(content: Text('Wikipedia is up to date')));
      await tester.pumpAndSettle();
      expect(seen(tester, 'Wikipedia is up to date'), findsOneWidget, reason: 'a snackbar from the sections pane is on screen');
      ScaffoldMessenger.of(sections).hideCurrentSnackBar();
      await tester.pumpAndSettle();


      // one book, from its chip
      await tapKey(tester, 'chip-bees-350');
      expect(shelves.book('bees')!.shelf, '350');
      expect(seen(tester, 'Placed in CDS 350 · Beekeeping as CDS 350-001.'), findsOneWidget, reason: 'the snackbar is on screen');
      await tester.tap(find.descendant(of: seen(tester, 'Placed in CDS 350 · Beekeeping as CDS 350-001.'), matching: find.text('Undo')));
      await tester.pumpAndSettle();
      expect(shelves.book('bees')!.unsorted, isTrue, reason: 'Undo works');

      // all the best guesses
      await tapKey(tester, 'place-all');
      expect(seen(tester, 'Placed 2 books. Each has its new call number.'), findsOneWidget, reason: 'the snackbar is on screen');
      await tester.tap(find.descendant(of: seen(tester, 'Placed 2 books. Each has its new call number.'), matching: find.text('Undo')));
      await tester.pumpAndSettle();
      expect(shelves.unsorted, hasLength(3), reason: 'Undo reverses the whole batch');
    });
  }
}
