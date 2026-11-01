import 'dart:io';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/screens/crisis_card.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

class _Help implements CrisisHelp {
  final List<String> launched = [];

  @override
  Future<bool> canPlaceCalls() async => true;
  @override
  Future<bool?> hasSignal() async => true;
  @override
  Future<bool> launch(Uri uri) async {
    launched.add('$uri');
    return true;
  }

  @override
  Future<NearestEr> nearestEr() async => const NearestEr(ErState.noMap);
  @override
  Future<bool> guidesInstalled() async => true;
  @override
  void openGuides(BuildContext context) {}
  @override
  void getGuides(BuildContext context) {}
  @override
  void getMap(BuildContext context) {}
  @override
  Future<void> turnOnLocation() async {}
  @override
  void directions(BuildContext context, MapPlace place) {}
}

/// The screen-reader node with exactly [label] can be activated (it has the tap action), and activating it does what a tap does.
void expectActivatable(WidgetTester tester, String label) {
  final node = tester.getSemantics(find.bySemanticsLabel(label));
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: '"$label" can be activated by a screen reader');
  node.owner!.performAction(node.id, SemanticsAction.tap);
}

void main() {
  testWidgets('the safety card: Call 988, Text 988 and Call 911 read their numbers and can be activated', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final help = _Help();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: SingleChildScrollView(child: CrisisCard(help: help, announce: false)))));
    await tester.pumpAndSettle();
    for (final label in ['Call nine eight eight', 'Text nine eight eight', 'Call nine one one']) {
      expectActivatable(tester, label);
      await tester.pumpAndSettle();
    }
    expect(help.launched, ['tel:988', 'sms:988', 'tel:911']);
    handle.dispose();
  });

  testWidgets('"Need help now?" can be activated and opens the sheet', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(appBar: AppBar(actions: [NeedHelpLink(help: _Help())]))));
    expectActivatable(tester, 'Need help now? Opens support options');
    await tester.pumpAndSettle();
    expect(find.text(kCrisisTitle), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the reader\'s "Close <library>" arrow can be activated and leaves the reader', (tester) async {
    final handle = tester.ensureSemantics();
    final dir = Directory.systemTemp.createTempSync('sem-reader');
    final sources = FakeSources(dir);
    final zim = ZimFile(path: '${dir.path}/php_manual.zim', size: 1 << 20);
    sources
      ..zims = [zim]
      ..titles[zim.path] = 'PHP Manual';
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ZimReaderScreen(sources: sources, zim: zim, debugHasHistory: true))),
            child: const Text('Library'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expectActivatable(tester, 'Close PHP Manual');
    await tester.pumpAndSettle();
    expect(find.byType(ZimReaderScreen), findsNothing);
    handle.dispose();
  });
}
