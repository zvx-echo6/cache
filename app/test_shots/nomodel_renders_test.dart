// No-model mode (1.0.30, UX-no-model-30) for the owner to review, drawn by the app itself with sample data (no personal data).
// flutter test test_shots/nomodel_renders_test.dart --update-goldens  (pictures in test_shots/nomodel/)

import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/guide/app_links.dart';
import 'package:cache/guide/guide_reader.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules_screen.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/screens/ask_off.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/download_confirm.dart' show openStorageForSpace;
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/setup_card.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/screens/weather_screen.dart';
import 'package:cache/sources/sources_state.dart' show ZimFile;
import 'package:cache/theme.dart';
import 'package:cache/weather/curated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/nav_fakes.dart';
import '../test/support/settings_rig.dart';
import 'owner_renders_test.dart' show ShotWeather;
import 'shot_kit.dart';

const _out = 'nomodel';
const _model = 'gemma-4-E4B-it-Q4_K_M.gguf';

const Map<String, (Size, double)> _sizes = {
  'phone': (Size(430, 932), 3),
  'ipad-portrait': (Size(820, 1180), 2),
  'ipad-landscape-rail': (Size(1180, 820), 2),
  'desktop-1440x900': (Size(1440, 900), 1),
};

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// The debug-only warning about a list tile on a coloured box (the app's Weather cards); the phone's release build does not make it.
void _ignoreDebugAsserts(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Kit {
  _Kit(this.r, this.layout, this.nav);

  final SettingsRig r;
  final LayoutState layout;
  final NavState nav;

  static Future<_Kit> boot(WidgetTester tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: Directory('${r.dir.path}/layout')..createSync());
    await tester.runAsync(layout.init);
    final nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    final zims = r.sources.zimsDir!.path;
    r.sources.zims = [
      ZimFile(path: '$zims/wikipedia_en_all_maxi_2026-02.zim', size: 105 << 30),
      ZimFile(path: '$zims/wikimed_en_all_maxi_2026-01.zim', size: 2200 << 20),
      ZimFile(path: '$zims/wikivoyage_en_all_maxi_2026-03.zim', size: 1200 << 20),
    ];
    r.sources.titles
      ..['$zims/wikipedia_en_all_maxi_2026-02.zim'] = 'Wikipedia (English)'
      ..['$zims/wikimed_en_all_maxi_2026-01.zim'] = 'WikiMed'
      ..['$zims/wikivoyage_en_all_maxi_2026-03.zim'] = 'Wikivoyage (English)';
    return _Kit(r, layout, nav);
  }

  Widget shell() => Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub);

  Future<void> addModel(WidgetTester tester, [String file = _model]) => tester.runAsync(() async {
    File('${r.modelsDir.path}/$file').writeAsBytesSync(List.filled(16, 0));
    await r.app.refreshModels();
  });

  /// A saved chat with a question and its answer.
  int savedChat(String title, String q, String a) {
    final c = r.store.create(title: title);
    r.store.addMessage(c.id, role: 'user', content: q, message: {'role': 'user', 'content': q});
    r.store.addMessage(c.id, role: 'assistant', content: a, message: {'role': 'assistant', 'content': a});
    return c.id;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  }
}

Future<void> _show(WidgetTester tester, Widget page, {String size = 'phone', CacheThemeId theme = CacheThemeId.light}) async {
  final (s, ratio) = _sizes[size]!;
  phone(tester, size: s, ratio: ratio);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: size == 'phone' ? null : const EdgeInsets.only(top: 24, bottom: 20)));
  await _settle(tester);
}

Future<void> _tapBar(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await _settle(tester);
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
    openStorageForSpace = (_) {};
  });

  testWidgets('1: Set up card, the model row with Not now; after it, ticked with the snackbar', (tester) async {
    final k = await _Kit.boot(tester);
    final weather = ShotWeather(k.r);
    final setup = SetupCache(
      app: k.r.app,
      weather: weather,
      sources: k.r.sources,
      browse: k.r.browse,
      modelDownloads: ModelDownloads(app: k.r.app),
      chooseModel: (_) {},
      getArea: (_) {},
      turnOnWeather: (_) {},
      addLibrary: (_) {},
    );
    Widget home() => HomeScreen(layout: k.layout, setup: setup, weather: weather, askOn: false, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {});
    await _show(tester, home());
    await snap(tester, _out, '1a-setup-model-not-now');
    await tester.tap(find.byKey(const ValueKey('setup-not-now')));
    await _settle(tester);
    await snap(tester, _out, '1b-setup-not-now-ticked-snackbar');
    await k.dispose(tester);
  });

  testWidgets('2: Home with the four-item bar: phone, iPad upright, the rail sideways, desktop; light and dark', (tester) async {
    final k = await _Kit.boot(tester);
    for (final size in _sizes.keys) {
      for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
        await _show(tester, k.shell(), size: size, theme: theme);
        await snap(tester, _out, '2-home-$size${theme == CacheThemeId.dark ? '-dark' : ''}');
      }
    }
    await k.dispose(tester);
  });

  testWidgets('3: Modules with Ask greyed (no model, downloading) and Ask\'s page, without and with saved chats', (tester) async {
    final k = await _Kit.boot(tester);
    await _show(tester, k.shell());
    await _tapBar(tester, 'Modules');
    await snap(tester, _out, '3a-modules-ask-greyed');
    await tester.tap(find.byKey(const ValueKey('module-ask')));
    await _settle(tester);
    await snap(tester, _out, '3b-ask-page-note');
    final downloads = ModelDownloads(app: k.r.app)
      ..current = const HfFile(repo: 'unsloth/gemma-4-E4B-it-GGUF', path: _model, size: 100)
      ..done = 40
      ..total = 100;
    await _show(tester, ModulesScreen(layout: k.layout, app: k.r.app, onOpen: (_) {}, downloads: downloads));
    await snap(tester, _out, '3c-modules-ask-downloading');
    await _show(tester, AskOffPage(app: k.r.app, chat: k.r.chat, downloads: downloads, onChooseModel: () {}, onOpenChat: (_) {}));
    await snap(tester, _out, '3d-ask-page-downloading');
    k.savedChat('Treating a burn', 'How do I treat a burn?', 'Cool the burn under cool running water for 20 minutes.');
    k.savedChat('Water from a stream', 'How do I make stream water safe?', 'Bring it to a rolling boil for one minute.');
    k.savedChat('Signals for help', 'What is the signal for help?', 'Three of anything: three blasts on a whistle, three fires.');
    await _show(tester, k.shell());
    await _tapBar(tester, 'Modules');
    await tester.tap(find.byKey(const ValueKey('module-ask')));
    await _settle(tester);
    await snap(tester, _out, '3e-ask-page-saved-chats');
    await k.dispose(tester);
  });

  testWidgets('4: Home search with no model: with results, and nothing found', (tester) async {
    final k = await _Kit.boot(tester);
    await _show(tester, k.shell());
    await tester.enterText(find.byKey(const ValueKey('home-search')), 'wiki');
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    await snap(tester, _out, '4a-search-results');
    await tester.enterText(find.byKey(const ValueKey('home-search')), 'zzqx');
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    await snap(tester, _out, '4b-search-nothing-found');
    await k.dispose(tester);
  });

  testWidgets('5: an alert without "Ask about this" (no model), and with it (a model)', (tester) async {
    final k = await _Kit.boot(tester);
    final r = k.r;
    await tester.runAsync(() async {
      for (final i in [0, 1, 2]) {
        await r.weather.setRowOn(kCurated[i], true);
      }
    });
    final fetched = r.clock.subtract(const Duration(minutes: 50)).toIso8601String();
    r.liveCore.stored['nws-alerts-point'] = {
      'fetched_at': fetched,
      'age': '5 minutes old',
      'expired': false,
      'items': [
        {'address': 'live:nws-alerts-point/x/1', 'label': 'Red flag warning', 'fields': {'Until': 'Mon 9 PM', 'Area': 'Twin Falls County'}},
      ],
    };
    await tester.runAsync(() async {
      await r.weather.updateNow();
      final here = (await r.weather.watchedPlaces()).first;
      await r.weather.viewFor(here);
    });
    for (final (name, ask) in [('5a-alert-no-ask-button', false), ('5b-alert-with-model-for-comparison', true)]) {
      await _show(tester, WeatherScreen(weather: r.weather, onOpenSettings: () {}, onAsk: ask ? (_) {} : null));
      await _settle(tester, 12);
      _ignoreDebugAsserts(tester);
      await tester.tap(find.text('Red flag warning').first);
      await _settle(tester);
      _ignoreDebugAsserts(tester);
      await snap(tester, _out, name);
    }
    await k.dispose(tester);
  });

  testWidgets('6: a cache:// link to Ask with no model', (tester) async {
    final k = await _Kit.boot(tester);
    await _show(tester, k.shell());
    tester.state<NavigatorState>(find.byType(Navigator).first).push(AppPlaceRoute(child: appPlaceScreen!(AppPlace.ask)!));
    await _settle(tester);
    await tester.pumpAndSettle();
    await snap(tester, _out, '6-cache-link-ask-note');
    await k.dispose(tester);
  });

  testWidgets('7: the delete confirm for the last model', (tester) async {
    final k = await _Kit.boot(tester);
    await k.addModel(tester);
    await _show(tester, ModelsScreen(app: k.r.app, memory: 8 << 30));
    await tester.tap(find.byKey(const ValueKey('delete-model-$_model')));
    await _settle(tester);
    await tester.pumpAndSettle();
    await snap(tester, _out, '7-delete-last-model-confirm');
    await k.dispose(tester);
  });

  testWidgets('8: the open chat after the last model is deleted; a saved chat opened read-only', (tester) async {
    final k = await _Kit.boot(tester);
    await k.addModel(tester);
    final id = k.savedChat('Treating a burn', 'How do I treat a burn?', 'Cool the burn under cool running water for 20 minutes. Do not use ice. Cover it loosely with a clean, dry cloth.');
    await _show(tester, k.shell());
    k.r.chat.openConversation(id);
    await _tapBar(tester, 'Ask');
    await tester.runAsync(() => k.r.app.deleteModel(k.r.app.models.single));
    await _settle(tester);
    await snap(tester, _out, '8a-open-chat-after-delete');
    await tester.tap(find.byKey(const ValueKey('ask-read-back')));
    await _settle(tester);
    await _tapBar(tester, 'Modules');
    await tester.tap(find.byKey(const ValueKey('module-ask')));
    await _settle(tester);
    await tester.tap(find.byKey(ValueKey('saved-chat-$id')));
    await _settle(tester);
    await snap(tester, _out, '8b-saved-chat-read-only');
    await k.dispose(tester);
  });

  testWidgets('9: a model arrives: the bar gets Ask back, "Ask is on." with Open', (tester) async {
    final k = await _Kit.boot(tester);
    await _show(tester, k.shell());
    await k.addModel(tester);
    await _settle(tester);
    await snap(tester, _out, '9-model-arrives-ask-is-on');
    await k.dispose(tester);
  });

  testWidgets('10: Ask with a model installed that did not load: the three fix lines', (tester) async {
    final k = await _Kit.boot(tester);
    await k.addModel(tester);
    final app = k.r.app;
    Future<void> ask(String name) async {
      await _show(tester, AskScreen(app: app, chat: k.r.chat));
      await snap(tester, _out, name);
    }

    app
      ..failed = app.models.single
      ..failure = LoadFailure.tooBig;
    await ask('10a-ask-fix-too-big');
    app.failure = LoadFailure.damaged;
    await ask('10b-ask-fix-damaged');
    app
      ..failed = null
      ..failure = null;
    await ask('10c-ask-fix-not-loaded');
    await k.dispose(tester);
  });
}
