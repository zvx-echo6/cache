// A place row in Ask with no places data on the phone says so, and offers "Download places", which opens the regions download
// (the Setup card's "Get your area" route).
import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart' show TurnPhase;
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

void main() {
  testWidgets('the not-on-this-device message has a Download places action that opens the regions route', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final nav = NavState(backend: FakeBackend(available: false), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    await tester.runAsync(() async {
      File('${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(16, 0));
      await r.app.refreshModels();
    });
    r.chat.messages.add(ChatMessage.assistant()
      ..phase = TurnPhase.done
      ..text = 'It is in Twin Falls.'
      ..sources = const [NumberedResult(1, SourceResult(title: 'Twin Falls', snippet: '', address: 'place:osm:w1'))]);
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: dir)),
    ));
    await settle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ask')));
    await settle();
    await tester.tap(find.text('1 source'));
    await settle();
    await tester.tap(find.textContaining('[1] Twin Falls'));
    await settle();
    expect(find.text('The map data for places is not on this device'), findsOneWidget);
    expect(find.text('Download places'), findsOneWidget);

    // The action goes to the regions route: this test's hub has no regions, which that route answers.
    await tester.tap(find.text('Download places'));
    await settle();
    // (the first message leaves, then the answer to the route comes in)
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Regions are not available on this device'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  });
}
