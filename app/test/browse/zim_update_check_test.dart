import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'web_fakes.dart';

// "Check for update" on a ZIM must always end in something the person can read, in a browser (the device's Library) as on a phone.
void main() {
  late Directory tmp;
  late FakeSources sources;
  late DeviceLibrary device;
  late BrowseState browse;
  const zimName = 'wikivoyage_en_europe_maxi_2026-03.zim';

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  /// The catalogue answers the lists at once; the update check's own question (it has a name) goes to [onEntries].
  Future<String> Function(Uri) split(Future<String> Function(Uri) onEntries) =>
      (u) => u.queryParameters.containsKey('name') ? onEntries(u) : recorded(u);

  Future<void> open(WidgetTester tester, Future<String> Function(Uri) fetch) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    File('${sources.zimsDir!.path}/$zimName').writeAsBytesSync(List.filled(2048, 0));
    await sources.refresh();
    sources.titles[sources.zims.single.path] = 'Wikivoyage Europe';
    device = DeviceLibrary(api: FakeDeviceApi(), fs: MemoryAppFs(), uploader: FakeUploader(), leaveWarning: (_) {});
    browse = BrowseState(
      sources: sources,
      catalog: catalogWith(fetch),
      settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
      phoneLanguage: 'en',
      device: device,
    );
    await tester.runAsync(() async {
      await browse.init();
      await device.refresh();
    });
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: BrowseScreen(browse: browse, active: true)));
    await tester.pump(const Duration(seconds: 1));
    if (find.byKey(const ValueKey('library-zims')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('library-zims')));
      await tester.pumpAndSettle();
    }
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.longPress(find.text('Wikivoyage Europe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for update'));
    await tester.pump();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zimupdate');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
  });
  tearDown(() {
    browse.dispose();
    device.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('a check that finds a newer release says so', (tester) async {
    await open(tester, recorded);
    await choose(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.textContaining('Update ready'), findsWidgets);
  });

  testWidgets('a catalogue that fails in an unexpected way still ends in a plain message', (tester) async {
    await open(tester, split((_) async => throw StateError('boom')));
    browse.updates.clear();
    await choose(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('The library could not be checked. Try again.'), findsOneWidget);
    expect(browse.checkingUpdates, isFalse);
  });

  testWidgets('a catalogue that never answers ends in a plain message', (tester) async {
    await open(tester, split((_) => Completer<String>().future));
    browse.updates.clear();
    await choose(tester);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(find.text('The Kiwix library took too long to answer.'), findsOneWidget);
    expect(browse.checkingUpdates, isFalse);
  });
}
