import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/screens/browse_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'video_fake.dart';

void main() {
  testWidgets('combined Browse keeps Kiwix and opens PeerTube', (tester) async {
    final dir = Directory.systemTemp.createTempSync('combined-browse');
    final sources = FakeSources(Directory('${dir.path}/zims')..createSync());
    final browse = BrowseState(
      sources: sources,
      network: FakeNetwork(true),
      settingsDirOverride: dir,
      phoneLanguage: 'en',
    );
    final video = VideoState(
      dirOverride: Directory('${dir.path}/videos'),
      nativeFactory: fakeVideoNative,
      tokens: MemoryTokenStore(),
    );
    await tester.runAsync(() async {
      await browse.init();
      await video.init();
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: BrowseScreen(video: video, browse: browse, active: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('Get more from the Kiwix library'), findsOneWidget);
    expect(find.textContaining('No ZIMs on this phone yet'), findsOneWidget);

    await tester.tap(find.text('Videos'));
    await tester.pumpAndSettle();
    expect(find.text('Saved on this phone'), findsOneWidget);
    expect(find.text('Add an instance'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    video.dispose();
    browse.dispose();
    sources.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}