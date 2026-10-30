import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

void main() {
  testWidgets('the Library keeps Kiwix and no longer shows Videos', (tester) async {
    final dir = Directory.systemTemp.createTempSync('library-screen');
    final sources = FakeSources(Directory('${dir.path}/zims')..createSync());
    final browse = BrowseState(
      sources: sources,
      policy: testPolicy(),
      settingsDirOverride: dir,
      phoneLanguage: 'en',
    );
    await tester.runAsync(browse.init);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: BrowseScreen(browse: browse, active: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Videos'), findsNothing);
    expect(find.textContaining('PeerTube'), findsNothing);
    expect(find.text('Add to Library'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-empty')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    browse.dispose();
    sources.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
