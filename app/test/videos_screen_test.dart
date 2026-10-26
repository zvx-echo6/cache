import 'dart:io';

import 'package:cache/screens/browse_screen.dart';
import 'package:cache/screens/videos/video_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/token_store.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_fake.dart';

/// Lets the background isolate answer and the screen rebuild; spinners never settle, so pumpAndSettle is not used.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Browse > Videos: add an instance, open a video, pick a download size', timeout: const Timeout(Duration(seconds: 60)), (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('video-ui')))!;
    final v = VideoState(dirOverride: dir, nativeFactory: fakeVideoNative, tokens: MemoryTokenStore());
    await tester.runAsync(v.init);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: BrowseScreen(video: v)));
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('Connect a PeerTube site'), findsOneWidget);

    await tester.tap(find.text('Videos'));
    await tester.pumpAndSettle();
    expect(find.text('Saved on this phone'), findsOneWidget);
    expect(find.textContaining('No instances yet'), findsOneWidget);

    await tester.tap(find.text('Add an instance'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'tube.example.org');
    await tester.tap(find.text('Add'));
    await settle(tester);
    // the new instance is opened: its search field and the two tabs
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    await settle(tester);
    expect(find.text('Merry Christmas'), findsOneWidget);

    await tester.tap(find.text('Merry Christmas'));
    await settle(tester);
    expect(find.text('Play'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await settle(tester);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('8.6 MB'), findsOneWidget);
    expect(find.text('Audio only'), findsOneWidget);
    expect(find.text('Download 360p · 2.9 MB'), findsOneWidget, reason: 'the smallest video size is picked first');

    v.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
    expect(VideoScreen, isNotNull);
  });
}
