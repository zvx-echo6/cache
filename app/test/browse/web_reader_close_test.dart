import 'dart:io';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeSources sources;
  late ZimFile zim;
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reader-close');
    sources = FakeSources(dir);
    zim = ZimFile(path: '${dir.path}/urban-prepper_en_all_2026-08.zim', size: 1 << 30);
    sources.zims = [zim];
    sources.titles[zim.path] = 'Urban Prepper';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // A desktop window: the Library list beside the reader, which a browser opens with the list slid away.
  Future<GlobalKey<TwoPaneState>> open(WidgetTester tester, {required bool web}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<TwoPaneState>();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: TwoPane(
        key: key,
        list: const Scaffold(body: Text('Library list')),
        listName: 'Library',
        initialKey: 'zim',
        initial: (_) => ZimReaderScreen(
          sources: sources,
          zim: zim,
          debugWeb: web,
          frameBuilder: ({key, required initialUrl, required onCreated, required onPage, required onExternal}) => const SizedBox.expand(),
        ),
        desktopInitial: (_) => const Scaffold(body: Text('Add to Library page')),
      ),
    ));
    await tester.pumpAndSettle();
    key.currentState!.setListHidden(true);
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('web, desktop width: the reader has the close arrow, and it closes the reader and shows the Library list', (tester) async {
    await open(tester, web: true);
    expect(find.byKey(const ValueKey('reader-close')), findsOneWidget);
    expect(find.byTooltip('Close Urban Prepper'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-show')), findsOneWidget, reason: 'the >> list toggle stays');
    expect(find.text('Library list').hitTestable(), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reader-close')));
    await tester.pumpAndSettle();
    expect(find.byType(ZimReaderScreen), findsNothing);
    expect(find.text('Library list').hitTestable(), findsOneWidget);
    expect(find.text('Add to Library page'), findsOneWidget);
  });

  testWidgets('web, desktop width: the >> toggle still shows the list beside the reader', (tester) async {
    await open(tester, web: true);
    await tester.tap(find.byKey(const ValueKey('pane-show')));
    await tester.pumpAndSettle();
    expect(find.byType(ZimReaderScreen), findsOneWidget);
    expect(find.text('Library list').hitTestable(), findsOneWidget);
  });

  testWidgets('not a browser: beside a list the reader has only the >> toggle, as before', (tester) async {
    await open(tester, web: false);
    expect(find.byKey(const ValueKey('reader-close')), findsNothing);
    expect(find.byKey(const ValueKey('pane-show')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pane-show')));
    await tester.pumpAndSettle();
    expect(find.byType(ZimReaderScreen), findsOneWidget);
    expect(find.text('Library list').hitTestable(), findsOneWidget);
  });
}
