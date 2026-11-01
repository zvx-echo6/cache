import 'dart:io';

import 'package:cache/browse/reader_screen.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

/// The screen-reader node with exactly [label] can be activated (it has the tap action), and activating it does what a tap does.
void expectActivatable(WidgetTester tester, String label) {
  final node = tester.getSemantics(find.bySemanticsLabel(label));
  expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: '"$label" can be activated by a screen reader');
  node.owner!.performAction(node.id, SemanticsAction.tap);
}

void main() {
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
