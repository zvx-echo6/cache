// When the search model (about 635 MB) is loaded ahead of use: not because Cache was opened, but when the person opens Ask or
// puts the cursor in a search box. The model itself is not loaded here (a counting stand-in).

import 'dart:io';

import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

/// An embedder that counts the loads the app asks of it.
class _Fake extends CacheEmbedder {
  _Fake(String path) : super(modelPath: path);
  int warms = 0;

  @override
  Future<void> warm() async {
    warms++;
  }

  @override
  Future<List<double>> embed(String text) async => [0.25, 0.5, 0.75];

  @override
  void free() {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;
  late SearchModel sm;
  late List<_Fake> made;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The shell on a phone, Home in front, with a chat model and the search model in the models folder.
  Future<void> open(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    await tester.runAsync(() async {
      File('${r.modelsDir.path}/gemma-4-E2B-it-Q4_K_M.gguf').writeAsBytesSync(List.filled(16, 0));
      File('${r.modelsDir.path}/${kSearchModel.fileName}').writeAsBytesSync(List.filled(16, 1));
      await r.app.refreshModels();
    });
    made = [];
    sm = SearchModel(
      app: r.app,
      modelsDir: () async => r.modelsDir,
      make: (p) {
        final f = _Fake(p);
        made.add(f);
        return f;
      },
      remote: false,
      readMemoryNow: () async => MemoryReading(avail: 4096 << 20, total: 8192 << 20),
      readCounters: () => const {},
    );
    SearchModel.shared = sm;
    addTearDown(() => SearchModel.shared = null);
    tester.view.physicalSize = const Size(430, 932) * 2;
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: Directory('${r.dir.path}/layout'))),
    ));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    SearchModel.shared = null;
    sm.dispose();
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  }

  testWidgets('Cache open with Home in front loads nothing; Ask shown loads the search model', (tester) async {
    await open(tester);
    expect(r.app.searchModel, isNotNull);
    expect(made, isEmpty, reason: 'opening Cache does not load the search model');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ask')));
    await settle(tester);
    expect(made, hasLength(1), reason: 'Ask is on the screen');
    expect(made.single.warms, 1);
    expect(sm.isWarm, isTrue);
    await close(tester);
  });

  testWidgets('the cursor in Home\'s search box loads the search model', (tester) async {
    await open(tester);
    expect(made, isEmpty);
    // The search box takes the focus, as a tap on it gives (the keyboard opens).
    await tester.showKeyboard(find.byKey(const ValueKey('home-search')));
    await settle(tester);
    expect(made, hasLength(1));
    expect(made.single.warms, 1);
    expect(sm.isWarm, isTrue);
    await close(tester);
  });
}
