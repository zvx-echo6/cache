// Cache on Linux, Library: a card that turns up while the page is open ("While this tab was closed", "Needs a look") never moves the
// rows that were already there, so a click aimed at a row (a delete among them) lands on it.
import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_library_page.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'build_fakes.dart';
import 'fakes.dart';
import 'web_fakes.dart';

/// The device's building service with the shelves (the Dewey classes) that a library page lists under its panel.
class FilingBuildApi extends FakeBuildApi implements BuildFilingApi {
  @override
  Future<List<BuildClass>> classes(String libraryId) async => const [
    BuildClass('300', 'Agriculture', [BuildDivision(number: '310', name: 'Gardening', classNumber: '300')]),
  ];

  @override
  Future<void> placeBook(String libraryId, String bookId, String division) async {}
}

Widget screen(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: child);

void main() {
  late Directory tmp;
  late FakeSources sources;
  late FakeDeviceApi api;
  late FilingBuildApi buildApi;
  late MemoryAppFs fs;
  late DeviceLibrary device;
  late BuildController build;
  late BrowseState browse;

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  void make() {
    build = BuildController(api: buildApi, uploader: FakeRawUploader(), fs: fs, poll: false, leaveWarning: (_) {});
    device = DeviceLibrary(api: api, fs: fs, uploader: FakeUploader(), leaveWarning: (_) {}, build: build);
    browse = BrowseState(sources: sources, catalog: catalogWith(recorded), settingsDirOverride: Directory('${tmp.path}/s')..createSync(recursive: true), phoneLanguage: 'en', device: device);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stablerows');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
    api = FakeDeviceApi();
    buildApi = FilingBuildApi();
    fs = MemoryAppFs();
    make();
  });
  tearDown(() {
    debugLinuxUi = null;
    browse.dispose();
    device.dispose();
    tmp.deleteSync(recursive: true);
  });

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('the Library list', () {
    /// A second visit: the transfers' last state is remembered, so on first sight something changed and the card is due.
    Future<double> openAndLetTheCardArrive(WidgetTester tester, {required bool linux}) async {
      debugLinuxUi = linux;
      api.jobList = [job('j1', 'running', bytes: 1, total: 9, name: 'WikiMed.zim')];
      await tester.runAsync(device.start);
      api.jobList = [job('j1', 'done', name: 'WikiMed.zim')];
      browse.dispose();
      device.dispose();
      make();
      buildApi.libs = [BuildLibrary(id: 'lib1', title: 'Garden', books: 38)];
      desktop(tester);
      await tester.runAsync(() async {
        await browse.init();
        await device.refresh();
        await build.refresh();
      });
      await tester.pumpWidget(screen(BrowseScreen(browse: browse, active: true, structured: true)));
      await tester.pumpAndSettle();
      expect(find.text('While this tab was closed'), findsNothing, reason: 'the page is up before the device has been asked');
      final before = tester.getTopLeft(find.text('Garden')).dy;
      await tester.runAsync(device.start);
      await tester.pumpAndSettle();
      expect(find.text('While this tab was closed'), findsOneWidget, reason: 'the card arrived');
      return tester.getTopLeft(find.text('Garden')).dy - before;
    }

    testWidgets('on the desktop the card turns up after the list and no row moves', (tester) async {
      final moved = await openAndLetTheCardArrive(tester, linux: true);
      expect(moved, 0);
      expect(tester.getTopLeft(find.text('While this tab was closed')).dy, greaterThan(tester.getTopLeft(find.text('Garden')).dy));
    });

    testWidgets('on the desktop Dismiss still clears it', (tester) async {
      await openAndLetTheCardArrive(tester, linux: true);
      await tester.ensureVisible(find.byKey(const ValueKey('dismiss-while-closed')));
      await tester.tap(find.byKey(const ValueKey('dismiss-while-closed')));
      await tester.pumpAndSettle();
      expect(find.text('While this tab was closed'), findsNothing);
    });

    testWidgets('off the desktop the card stays above the list, as it was (and it does push the rows)', (tester) async {
      final moved = await openAndLetTheCardArrive(tester, linux: false);
      expect(moved, greaterThan(0));
    });
  });

  group('a library page', () {
    final bookA = book('a', 'Field Manual 21-76 Survival');

    Future<double> openAndLetFailureArrive(WidgetTester tester, {required bool linux}) async {
      debugLinuxUi = linux;
      buildApi.libs = [BuildLibrary(id: 'lib1', title: 'Hunting and field guides', books: 1, passages: 10)];
      buildApi.bookMap['lib1'] = [bookA];
      buildApi.q = queueOf([qitem('d1', 'lib1', 'done')]);
      desktop(tester);
      await tester.runAsync(build.refresh);
      await tester.pumpWidget(screen(BuiltLibraryPage(build: build, libraryId: 'lib1')));
      await tester.pumpAndSettle();
      expect(find.text('Needs a look'), findsNothing);
      final shelves = find.text('Go to a number');
      expect(shelves, findsOneWidget);
      final before = tester.getTopLeft(shelves).dy;
      buildApi.q = queueOf([qitem('d1', 'lib1', 'done'), qitem('f1', 'lib1', 'failed', title: 'Trapping.pdf', error: 'This PDF is protected with a password.')]);
      await tester.runAsync(build.refresh);
      await tester.pumpAndSettle();
      expect(find.text('Needs a look'), findsOneWidget, reason: 'the panel arrived');
      return tester.getTopLeft(shelves).dy - before;
    }

    testWidgets('on the desktop "Needs a look" turns up after the shelves and nothing above it moves', (tester) async {
      final moved = await openAndLetFailureArrive(tester, linux: true);
      expect(moved, 0);
      expect(tester.getTopLeft(find.text('Needs a look')).dy, greaterThan(tester.getTopLeft(find.text('Go to a number')).dy));
    });

    testWidgets('off the desktop the panel stays above the shelves, as it was', (tester) async {
      final moved = await openAndLetFailureArrive(tester, linux: false);
      expect(moved, greaterThan(0));
      expect(tester.getTopLeft(find.text('Needs a look')).dy, lessThan(tester.getTopLeft(find.text('Go to a number')).dy));
    });
  });
}
