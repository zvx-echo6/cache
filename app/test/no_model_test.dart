// No-model mode (1.0.30): models are never required. With no chat model on this device Cache is search only: Ask leaves the bar
// and the rails, is greyed in Modules (its page explains and keeps the saved chats readable), and Home's box is search only. A model
// installed later brings Ask back; deleting the last one returns to search only; a model that is installed but did not load is
// not no-model mode, and Ask shows its fix.

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/guide/app_links.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/layout/modules_screen.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_off.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

const _file = 'gemma-4-E2B-it-Q4_K_M.gguf';

void main() {
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;

  void size(WidgetTester tester, Size s) {
    tester.view.physicalSize = s * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> setUpRig(WidgetTester tester) async {
    r = await SettingsRig.create(tester);
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
  }

  Future<void> tearDownRig(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await tearDownRig(tester);
  }

  /// A chat model arrives in the models folder (downloaded, copied in or synced).
  Future<void> addModel(WidgetTester tester) => tester.runAsync(() async {
    File('${r.modelsDir.path}/$_file').writeAsBytesSync(List.filled(16, 0));
    await r.app.refreshModels();
  });

  Future<void> shell(WidgetTester tester, Size s) async {
    size(tester, s);
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: Directory('${r.dir.path}/layout'))),
    ));
    await settle(tester);
  }

  List<String> barLabels(WidgetTester tester) => [for (final d in tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations) (d as NavigationDestination).label];
  List<String> railLabels(WidgetTester tester) => [
    for (final d in tester.widget<NavigationRail>(find.byKey(const ValueKey('nav-rail'))).destinations) (d.label as Text).data!,
  ];

  Future<void> tapBar(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await settle(tester);
  }

  test('a load error from the native layer names its fix', () {
    expect(loadFailureOf('cannot create context (out of memory?)'), LoadFailure.tooBig);
    expect(loadFailureOf('cannot load model: /models/x.gguf'), LoadFailure.damaged);
    expect(loadFailureOf('model has no usable chat template'), LoadFailure.other);
  });

  group('no model on this device', () {
    testWidgets('the bar has four items, Home, Maps, Library, Modules; the Ask pin is kept', (tester) async {
      await setUpRig(tester);
      expect(r.app.started, isTrue);
      expect(r.app.models, isEmpty);
      expect(r.app.askAvailable, isFalse);
      await shell(tester, const Size(430, 932));
      expect(barLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
      expect(layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.library], reason: 'hidden, not forgotten');
      await tearDownRig(tester);
    });

    testWidgets('tablet held sideways: the rail has the same four items', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(1180, 820));
      expect(railLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
      await tearDownRig(tester);
    });

    testWidgets('desktop: the rail has the same four items', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(1920, 1080));
      expect(railLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
      await tearDownRig(tester);
    });

    testWidgets('a tablet held upright: the bottom bar has four items', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(820, 1180));
      expect(barLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
      await tearDownRig(tester);
    });

    testWidgets('Home: "Search Cache", no Ask row; nothing found says so and offers Choose a model', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(430, 932));
      final box = tester.widget<TextField>(find.byKey(const ValueKey('home-search')));
      expect(box.decoration!.hintText, 'Search Cache');
      expect(box.textInputAction, TextInputAction.search);
      await tester.enterText(find.byKey(const ValueKey('home-search')), 'zzqx');
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.byKey(const ValueKey('search-ask')), findsNothing, reason: 'no answer slot with no model');
      expect(find.text('Nothing found on this device.'), findsOneWidget);
      expect(find.text('For an answer in words, choose a model.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-choose-model')));
      await settle(tester);
      expect(find.byType(ModelsScreen), findsOneWidget);
      await tearDownRig(tester);
    });

    testWidgets('a shortcut to the Ask module is not drawn; a chat shortcut stays', (tester) async {
      await setUpRig(tester);
      final c = r.store.create(title: 'Treating burns');
      layout
        ..addShortcut(Shortcut.module(ModuleId.ask))
        ..addShortcut(Shortcut.chat(id: c.id, title: 'Treating burns'));
      await shell(tester, const Size(430, 932));
      expect(find.byKey(const ValueKey('shortcut-module:ask')), findsNothing);
      expect(find.byKey(ValueKey('shortcut-chat:${c.id}')), findsOneWidget);
      await tearDownRig(tester);
    });

    testWidgets('Modules: Ask greyed with "Needs a model"; a tap opens its page with the note and Choose a model', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(430, 932));
      await tapBar(tester, 'Modules');
      expect(find.byKey(const ValueKey('module-ask-detail')), findsOneWidget);
      expect(find.text('Needs a model'), findsOneWidget);
      expect(find.bySemanticsLabel('Ask, Needs a model'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('module-ask')));
      await settle(tester);
      expect(find.text('Ask needs a model on this device.'), findsOneWidget);
      expect(find.text('Saved chats'.toUpperCase()), findsNothing, reason: 'no saved chats, no list');
      await tester.tap(find.byKey(const ValueKey('ask-off-choose')));
      await settle(tester);
      expect(find.byType(ModelsScreen), findsOneWidget);
      await tearDownRig(tester);
    });

    testWidgets('saved chats stay readable: listed on the Ask page, opened read-only, back to the list', (tester) async {
      await setUpRig(tester);
      final c = r.store.create(title: 'Treating burns');
      r.store.addMessage(c.id, role: 'user', content: 'How do I treat a burn?', message: {'role': 'user', 'content': 'How do I treat a burn?'});
      r.store.addMessage(c.id, role: 'assistant', content: 'Cool it under running water.', message: {'role': 'assistant', 'content': 'Cool it under running water.'});
      await shell(tester, const Size(430, 932));
      await tapBar(tester, 'Modules');
      await tester.tap(find.byKey(const ValueKey('module-ask')));
      await settle(tester);
      expect(find.text('SAVED CHATS'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('saved-chat-${c.id}')));
      await settle(tester);
      expect(find.text('How do I treat a burn?'), findsOneWidget);
      expect(find.byKey(const ValueKey('ask-off-composer')), findsOneWidget);
      expect(find.text('Ask is off. Choose a model to carry on.'), findsOneWidget);
      expect(find.byTooltip('New chat'), findsNothing);
      expect(find.byType(TextField), findsNothing, reason: 'no composer to type into');
      await tester.tap(find.byKey(const ValueKey('ask-read-back')));
      await settle(tester);
      expect(find.byKey(ValueKey('saved-chat-${c.id}')), findsOneWidget, reason: 'back on the list');
      await tearDownRig(tester);
    });

    testWidgets('a cache:// link to Ask opens the note with Choose a model and Close', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(430, 932));
      final page = appPlaceScreen!(AppPlace.ask)!;
      tester.state<NavigatorState>(find.byType(Navigator).first).push(AppPlaceRoute(child: page));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Ask needs a model on this device.'), findsOneWidget);
      expect(find.byKey(const ValueKey('ask-off-choose')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ask-off-close')));
      await tester.pumpAndSettle();
      expect(find.text('Ask needs a model on this device.'), findsNothing);
      await tearDownRig(tester);
    });

    testWidgets('the guide offers no "Ask Cache instead"', (tester) async {
      await setUpRig(tester);
      await shell(tester, const Size(430, 932));
      expect(askCacheInstead, isNull);
      await addModel(tester);
      await settle(tester);
      expect(askCacheInstead, isNotNull);
      await tearDownRig(tester);
    });
  });

  testWidgets('a model installed later: Ask returns in its old slot, "Ask is on." with Open, Home asks again', (tester) async {
    await setUpRig(tester);
    await shell(tester, const Size(430, 932));
    expect(barLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
    await addModel(tester);
    await settle(tester);
    expect(barLabels(tester), ['Home', 'Ask', 'Maps', 'Library', 'Modules']);
    expect(find.text('Ask is on.'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Open'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('home-search'))).decoration!.hintText, 'Search Cache or ask anything');
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0, reason: 'nothing moves by itself');
    await tearDownRig(tester);
  });

  testWidgets('a model installed later: the rail gets Ask back too', (tester) async {
    await setUpRig(tester);
    await shell(tester, const Size(1920, 1080));
    expect(railLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
    await addModel(tester);
    await settle(tester);
    expect(railLabels(tester), ['Home', 'Ask', 'Maps', 'Library', 'Modules']);
    await tearDownRig(tester);
  });

  testWidgets('the last model deleted: the open chat stays read-only, the bar loses Ask, back goes Home', (tester) async {
    await setUpRig(tester);
    await addModel(tester);
    final c = r.store.create(title: 'Treating burns');
    r.store.addMessage(c.id, role: 'user', content: 'How do I treat a burn?', message: {'role': 'user', 'content': 'How do I treat a burn?'});
    await shell(tester, const Size(430, 932));
    expect(barLabels(tester), ['Home', 'Ask', 'Maps', 'Library', 'Modules']);
    expect(find.text('Ask is on.'), findsNothing, reason: 'a model that was there at the start is not news');
    r.chat.openConversation(c.id);
    await tapBar(tester, 'Ask');
    expect(find.text('How do I treat a burn?'), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-off-composer')), findsNothing);
    await tester.runAsync(() => r.app.deleteModel(r.app.models.single));
    await settle(tester);
    expect(r.app.askAvailable, isFalse);
    expect(barLabels(tester), ['Home', 'Maps', 'Library', 'Modules']);
    expect(find.text('How do I treat a burn?'), findsOneWidget, reason: 'the screen stays, never yanked');
    expect(find.text('Ask is off. Choose a model to carry on.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ask-read-back')));
    await settle(tester);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0, reason: 'Home');
    expect(r.store.get(c.id), isNotNull, reason: 'saved chats are never deleted with the model');
    await tearDownRig(tester);
  });

  testWidgets('deleting the last model says Ask will turn off; one of two does not', (tester) async {
    await setUpRig(tester);
    await addModel(tester);
    await r.show(tester, ModelsScreen(app: r.app, memory: 8 << 30));
    await tester.tap(find.byKey(const ValueKey('delete-model-$_file')));
    await tester.pumpAndSettle();
    expect(find.text('Ask will turn off. Saved chats stay readable.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      File('${r.modelsDir.path}/qwen3-4b-Q4_K_M.gguf').writeAsBytesSync(List.filled(16, 0));
      await r.app.refreshModels();
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-model-$_file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-delete')), findsOneWidget);
    expect(find.text('Ask will turn off. Saved chats stay readable.'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tearDownRig(tester);
  });

  group('installed but not loading is not no-model mode', () {
    Future<void> ask(WidgetTester tester) async {
      await r.show(tester, AskScreen(app: r.app, chat: r.chat), theme: CacheThemeId.light);
      await tester.pump();
    }

    testWidgets('too big: the fix is a smaller model', (tester) async {
      await setUpRig(tester);
      await addModel(tester);
      r.app
        ..failed = r.app.models.single
        ..failure = LoadFailure.tooBig;
      await ask(tester);
      expect(find.text('gemma-4-E2B-it-Q4_K_M did not load. It is too big for this device.'), findsOneWidget);
      expect(find.text('Choose a smaller model'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ask-fix-button')));
      await tester.pumpAndSettle();
      expect(find.byType(ModelsScreen), findsOneWidget);
      await tearDownRig(tester);
    });

    testWidgets('a damaged file: Delete and download again', (tester) async {
      await setUpRig(tester);
      await addModel(tester);
      r.app
        ..failed = r.app.models.single
        ..failure = LoadFailure.damaged;
      await ask(tester);
      expect(find.text('gemma-4-E2B-it-Q4_K_M did not load. The file may be damaged.'), findsOneWidget);
      expect(find.text('Delete and download again'), findsOneWidget);
      await tearDownRig(tester);
    });

    testWidgets('nothing loaded: Load the model; and the bar keeps Ask', (tester) async {
      await setUpRig(tester);
      await addModel(tester);
      await ask(tester);
      expect(find.text('No model is loaded.'), findsOneWidget);
      expect(find.text('Load gemma-4-E2B-it-Q4_K_M'), findsOneWidget);
      await shell(tester, const Size(430, 932));
      expect(barLabels(tester), ['Home', 'Ask', 'Maps', 'Library', 'Modules']);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('home-search'))).decoration!.hintText, 'Search Cache or ask anything');
      await tearDownRig(tester);
    });

    testWidgets('no model at all shows no fix line', (tester) async {
      await setUpRig(tester);
      await ask(tester);
      expect(find.byKey(const ValueKey('ask-fix')), findsNothing, reason: 'no model at all is not situation B');
      await tearDownRig(tester);
    });
  });

  testWidgets('a model downloading: Modules says how far, the note says Ask turns on when it is ready', (tester) async {
    await setUpRig(tester);
    final downloads = ModelDownloads(app: r.app)
      ..current = const HfFile(repo: 'unsloth/gemma-4-E2B-it-GGUF', path: _file, size: 100)
      ..done = 40
      ..total = 100;
    await r.show(tester, ModulesScreen(layout: layout, app: r.app, onOpen: (_) {}, downloads: downloads), theme: CacheThemeId.light);
    expect(find.text('Model downloading 40%'), findsOneWidget);
    await r.show(tester, AskOffPage(app: r.app, chat: r.chat, downloads: downloads, onChooseModel: () {}), theme: CacheThemeId.light);
    expect(find.text('A model is downloading. Ask turns on when it is ready.'), findsOneWidget);
    expect(find.text('See download'), findsOneWidget);
    await tearDownRig(tester);
  });
}
