import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/theme.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'build_fakes.dart';
import 'fakes.dart';
import 'web_fakes.dart';

Widget screen(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: child);

void main() {
  late Directory tmp;
  late FakeSources sources;
  late FakeDeviceApi api;
  late FakeBuildApi buildApi;
  late MemoryAppFs fs;
  late DeviceLibrary device;
  late BuildController build;
  late BrowseState browse;

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('webdesk');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
    api = FakeDeviceApi();
    buildApi = FakeBuildApi();
    fs = MemoryAppFs();
    build = BuildController(api: buildApi, uploader: FakeRawUploader(), fs: fs, poll: false, leaveWarning: (_) {});
    device = DeviceLibrary(api: api, fs: fs, uploader: FakeUploader(), leaveWarning: (_) {}, build: build);
    browse = BrowseState(sources: sources, catalog: catalogWith(recorded), settingsDirOverride: Directory('${tmp.path}/s')..createSync(), phoneLanguage: 'en', device: device);
  });
  tearDown(() {
    browse.dispose();
    device.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, {double width = 1920, double height = 1080}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await browse.init();
      await device.refresh();
      await build.refresh();
    });
    await tester.pumpWidget(screen(BrowseScreen(browse: browse, active: true)));
    await tester.pumpAndSettle();
  }

  group('the desktop layout', () {
    testWidgets('from 1280: a list of 380 beside a detail that starts on Add to Library, with the building rows in it', (tester) async {
      await show(tester);
      expect(widthClassOf(tester.element(find.byType(BrowseScreen))), WidthClass.desktop);
      expect(find.text('Choose an item'), findsNothing);
      expect(find.text('Add to Library'), findsOneWidget, reason: 'one control: the page beside the list, not also a button in it');
      expect(find.byKey(const ValueKey('add-to-library')), findsNothing);
      expect(find.text('Build from your PDFs'), findsOneWidget);
      expect(find.text('Make a searchable library from PDF files on this computer.'), findsOneWidget);
      expect(find.text('Drop folder'), findsOneWidget);
      final divider = tester.getTopLeft(find.byType(VerticalDivider).first);
      expect(divider.dx, kDesktopListWidth, reason: 'the list is 380 wide at the left of the page (the rail is outside this screen)');
    });

    testWidgets('below 1280 the tablet layout stays as it was', (tester) async {
      await show(tester, width: 1100);
      expect(find.text('Choose an item'), findsOneWidget);
    });

    testWidgets('Build from your PDFs opens beside the list, and the list stays', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('add-build-pdfs')));
      await tester.pumpAndSettle();
      expect(find.text('Drop PDFs or a folder here'), findsOneWidget);
      expect(find.text('Device storage'), findsOneWidget);
      // the back arrow goes back to Add to Library inside the detail
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-build-pdfs')), findsOneWidget);
    });

    testWidgets('a library being built is a row with a badge and a card with the books done and the time left; both open the library', (tester) async {
      buildApi.libs = [BuildLibrary(id: 'lib1', title: 'Hunting and field guides', books: 18, passages: 8740, createdAt: DateTime(2026, 8, 14))];
      buildApi.bookMap['lib1'] = [book('a', 'Field Manual 21-76 Survival')];
      buildApi.q = queueOf([
        for (var i = 0; i < 18; i++) qitem('d$i', 'lib1', 'done'),
        qitem('b1', 'lib1', 'building', title: 'Wilderness Medicine Handbook, 7th ed', pieces: 212, total: 480),
        for (var i = 0; i < 195; i++) qitem('w$i', 'lib1', 'queued', position: i + 1),
      ], low: 9 * 3600, high: 13 * 3600);
      api.itemList = [item('lib1', kind: 'library', bytes: 1900 << 20)];
      await show(tester);
      expect(find.text('Building 8%'), findsOneWidget);
      expect(find.text('Building Hunting and field guides'), findsOneWidget);
      expect(find.text('18 of 214 books · roughly 9 to 13 h left'), findsOneWidget);
      expect(find.text('Building keeps going if you close this tab.'), findsOneWidget);
      expect(find.textContaining('Built from your PDFs · 18 books · 1.9 GB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('built-lib1')));
      await tester.pumpAndSettle();
      expect(find.text('FINISHED BOOKS · 1'), findsOneWidget);
      expect(find.text('195 more waiting'), findsOneWidget);
      expect(find.text('Device storage'), findsOneWidget, reason: 'the list is still there');
      await tester.tap(find.byKey(const ValueKey('list-pause-lib1')));
      await tester.pumpAndSettle();
      expect(buildApi.calls, ['pause']);
      expect(find.text('Paused'), findsWidgets);
    });

    testWidgets('the row says what deleting the library frees, the same figure as the card and the menu, not the search folder alone', (tester) async {
      buildApi.libs = [BuildLibrary(id: 'lib1', title: 'Garden', books: 38, bytes: 70 << 20)];
      api.itemList = [item('lib1', kind: 'library', bytes: 66 << 20)];
      await show(tester);
      expect(find.textContaining('Built from your PDFs · 38 books · 70.0 MB'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('built-lib1')), matching: find.textContaining('66.0 MB')), findsNothing);
    });

    testWidgets('a library that is done is a plain row; one with failures says how many', (tester) async {
      buildApi.libs = [BuildLibrary(id: 'lib1', title: 'Garden', books: 38), BuildLibrary(id: 'lib2', title: 'Trapping', books: 3)];
      buildApi.q = queueOf([qitem('f1', 'lib2', 'failed', error: 'x'), qitem('f2', 'lib2', 'failed', error: 'x'), qitem('d', 'lib2', 'done')]);
      await show(tester);
      expect(find.text('Garden'), findsOneWidget);
      expect(find.text('2 failed'), findsOneWidget);
      expect(find.text('Building 0%'), findsNothing);
    });
  });
}
