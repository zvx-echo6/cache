// Ask when a model is chosen but not loaded: Send works. The question shows in the chat at once with a quiet line, the model wakes
// (under the memory gate), and the question is sent when the model has loaded. A slim bar at the top loads the model by hand, the
// header names the chosen model, and a held question that is dropped goes back into the field.

import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/ask_about.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'nav_fakes.dart';
import 'support/act_core_stand_in.dart';
import 'support/settings_rig.dart';

const _file = 'gemma-4-E2B-it-Q4_K_M.gguf';
const _gb = 1 << 30;
const _info = ModelInfo(description: 'Gemma 4 E2B', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);
const _about = AskAbout(sourceTitle: 'Weather Service alerts', sourceId: 'nws-alerts-point', place: 'Pocatello', label: 'Freeze Warning');
const _question = 'How do I purify water?';

/// The native session, by hand: a load waits until the test lets it finish, or fails.
class _Session implements LlamaSession {
  Completer<void>? loadGate;
  Object? loadError;
  int loads = 0;

  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async {
    loads++;
    await loadGate?.future;
    if (loadError != null) throw loadError!;
    return _info;
  }

  @override
  Future<void> unload() async {}

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  late _Session session;
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;
  late ScriptedBackend backend;
  late ChatController chat;
  var avail = 6 * _gb;
  setUp(() => avail = 6 * _gb);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Real time passes (file reads in the memory gate) until [done] holds, at most about ten seconds.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The shell on Home. A model file is on the device. With [resting] the chosen model rests from the start (opening Ask wakes it);
  /// otherwise it is set to rest by [rest], after Ask is open.
  Future<void> setUpShell(WidgetTester tester, {bool resting = false, bool loaded = false}) async {
    session = _Session();
    backend = ScriptedBackend([(_) => say('Answer.')]);
    r = await SettingsRig.create(tester, appFactory: (dir, models) => AppState(
          settingsDirOverride: dir,
          modelsDirOverride: models,
          session: session,
          memory: () async => MemoryReading(avail: avail, total: 8 * _gb, threshold: 200 << 20),
        ));
    chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])..attachStore(r.store);
    r.chat = chat;
    var wired = false;
    r.app.addListener(() {
      final on = r.app.active != null;
      if (on == wired) return;
      wired = on;
      chat.setBackend(on ? backend : null);
    });
    final dir = Directory('${r.dir.path}/layout')..createSync();
    PanePrefs.testDir = dir;
    addTearDown(() => PanePrefs.testDir = null);
    layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    nav = NavState(backend: FakeBackend(), location: r.location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
    await tester.runAsync(() async {
      File('${r.modelsDir.path}/$_file').writeAsBytesSync(List.filled(16, 0));
      await r.app.refreshModels();
    });
    if (resting) r.app.resting = r.app.models.first;
    if (loaded) await tester.runAsync(() => r.app.activate(r.app.models.first));
    tester.view.physicalSize = const Size(430, 932) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.light),
      home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, railPrefs: RailPrefs(dirOverride: Directory('${r.dir.path}/layout'))),
    ));
    await settle(tester);
  }

  Future<void> tearDownShell(WidgetTester tester) async {
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    nav.dispose();
    layout.dispose();
    await r.dispose(tester);
  }

  Future<void> openAsk(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ask')));
    await settle(tester);
  }

  /// The chosen model comes to rest while Ask is open (no wake: that was at the opening).
  Future<void> rest(WidgetTester tester) async {
    r.app.resting = r.app.models.first;
    await tester.runAsync(r.app.refreshModels);
    await settle(tester);
  }

  String name() => r.app.plainName(r.app.models.first);
  Finder field() => find.descendant(of: find.byType(AskScreen), matching: find.byType(TextField));
  Finder send() => find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
  bool sendOn(WidgetTester tester) => tester.widget<IconButton>(send()).onPressed != null;
  String typed(WidgetTester tester) => tester.widget<TextField>(field()).controller!.text;

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pump();
  }

  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(send());
    await settle(tester);
  }

  String asked() {
    final m = (backend.requests.last['messages'] as List).cast<Map>();
    return m.lastWhere((x) => x['role'] == 'user')['content'] as String;
  }

  group('a model is chosen but not loaded', () {
    testWidgets('(a) resting: Send is on; the question shows at once with its line; after the load it is sent and answered', (tester) async {
      await setUpShell(tester);
      await openAsk(tester);
      await rest(tester);
      expect(find.text('${name()} is resting'), findsOneWidget);
      expect(sendOn(tester), isTrue);
      session.loadGate = Completer<void>();
      await type(tester, _question);
      await tapSend(tester);
      expect(typed(tester), isEmpty, reason: 'the question left the field');
      expect(find.text(_question), findsOneWidget, reason: 'shown in the chat as the person\'s message');
      expect(find.text('Sent when ${name()} has loaded'), findsOneWidget);
      await until(tester, () => r.app.loading != null);
      expect(r.app.loading, isNotNull, reason: 'Send woke the model');
      expect(backend.requests, isEmpty);
      session.loadGate!.complete();
      await until(tester, () => backend.requests.isNotEmpty);
      await settle(tester);
      expect(asked(), endsWith(_question));
      expect([for (final m in chat.messages) if (m.isUser) m.text], [_question]);
      expect(find.text(_question), findsOneWidget);
      expect(find.textContaining('Sent when'), findsNothing);
      expect(find.text('Answer.'), findsOneWidget);
      await tearDownShell(tester);
    });

    testWidgets('(b) the memory gate holds: the bar says so; the question stays held; Load anyway loads it and sends it', (tester) async {
      avail = 1 * _gb;
      await setUpShell(tester, resting: true);
      await openAsk(tester);
      expect(find.text('Waiting for free memory'), findsOneWidget);
      expect(find.text('Load anyway'), findsOneWidget);
      expect(find.text('Other apps are using it right now. Loading anyway may close some of them.'), findsNothing, reason: 'the old card is gone');
      expect(sendOn(tester), isTrue);
      await type(tester, _question);
      await tapSend(tester);
      expect(find.text(_question), findsOneWidget);
      expect(find.text('Sent when ${name()} has loaded'), findsOneWidget);
      await settle(tester);
      expect(session.loads, 0, reason: 'Send does not bypass the memory gate');
      expect(r.app.active, isNull);
      expect(backend.requests, isEmpty);
      await tester.tap(find.text('Load anyway'));
      await until(tester, () => backend.requests.isNotEmpty);
      await settle(tester);
      expect(session.loads, 1);
      expect(r.app.active, isNotNull);
      expect(asked(), endsWith(_question));
      expect(find.textContaining('Sent when'), findsNothing);
      await tearDownShell(tester);
    });

    testWidgets('(e) the header names the resting model; with the gate holding it too', (tester) async {
      avail = 1 * _gb;
      await setUpShell(tester, resting: true);
      await openAsk(tester);
      expect(find.descendant(of: find.byKey(const ValueKey('model-name')), matching: find.text(name())), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('model-name')), matching: find.text('No model')), findsNothing);
      await tearDownShell(tester);
    });
  });

  testWidgets('(c) no model chosen: Send is off and the field says No model; the header says No model', (tester) async {
    final app = AppState();
    final c = ChatController(actCore: const ActCoreStandIn(), tools: const []);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AskScreen(app: app, chat: c)));
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)).onPressed, isNull);
    expect(find.text('No model'), findsWidgets);
    expect(find.descendant(of: find.byType(TextField), matching: find.text('No model')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('model-name')), matching: find.text('No model')), findsOneWidget);
    c.dispose();
    app.dispose();
  });

  testWidgets('(f) a model loaded: a question is sent at once, and there is no bar', (tester) async {
    await setUpShell(tester, loaded: true);
    await openAsk(tester);
    expect(find.textContaining('is resting'), findsNothing);
    expect(find.text('Waiting for free memory'), findsNothing);
    expect(find.textContaining('Loading '), findsNothing);
    expect(sendOn(tester), isTrue);
    await type(tester, _question);
    await tapSend(tester);
    await until(tester, () => backend.requests.isNotEmpty);
    expect(asked(), endsWith(_question));
    expect(find.textContaining('Sent when'), findsNothing);
    await tearDownShell(tester);
  });

  group('a held question that is dropped goes back into the field', () {
    testWidgets('(d) the load fails: the typed question is back in the field, and nothing is sent', (tester) async {
      await setUpShell(tester, resting: true);
      session.loadGate = Completer<void>();
      session.loadError = StateError('out of memory');
      await openAsk(tester);
      await until(tester, () => r.app.loading != null);
      await type(tester, _question);
      await tapSend(tester);
      expect(find.text(_question), findsOneWidget);
      session.loadGate!.complete();
      await until(tester, () => r.app.loading == null && r.app.loadError != null);
      await settle(tester);
      expect(typed(tester), _question);
      expect(find.textContaining('Sent when'), findsNothing, reason: 'no longer held');
      expect(chat.messages, isEmpty);
      expect(backend.requests, isEmpty);
      await tearDownShell(tester);
    });

    testWidgets('a field that already has text keeps it: the dropped question is added after it, on a new line', (tester) async {
      await setUpShell(tester, resting: true);
      session.loadGate = Completer<void>();
      session.loadError = StateError('out of memory');
      await openAsk(tester);
      await until(tester, () => r.app.loading != null);
      await type(tester, _question);
      await tapSend(tester);
      await type(tester, 'something I am still typing');
      session.loadGate!.complete();
      await until(tester, () => r.app.loading == null && r.app.loadError != null);
      await settle(tester);
      expect(typed(tester), 'something I am still typing\n$_question');
      await tearDownShell(tester);
    });

    testWidgets('a newer held question replaces the older: one bubble, the older one back in the field', (tester) async {
      avail = 1 * _gb;
      await setUpShell(tester, resting: true);
      await openAsk(tester);
      await type(tester, _question);
      await tapSend(tester);
      await type(tester, 'And boiling time?');
      await tapSend(tester);
      final chatList = find.byType(ListView);
      expect(find.descendant(of: chatList, matching: find.text('And boiling time?')), findsOneWidget);
      expect(find.descendant(of: chatList, matching: find.text(_question)), findsNothing, reason: 'only the newer one is held, so only it shows in the chat');
      expect(typed(tester), _question);
      await tearDownShell(tester);
    });

    testWidgets('"Ask about this" held: its bubble shows; when the load fails its text is back in the field', (tester) async {
      await setUpShell(tester, resting: true);
      session.loadGate = Completer<void>();
      session.loadError = StateError('out of memory');
      (tester.state(find.byType(Shell)) as dynamic).askAbout(_about);
      await until(tester, () => r.app.loading != null);
      await settle(tester);
      expect(find.text(_about.question), findsOneWidget, reason: 'the held question stays shown in the chat');
      session.loadGate!.complete();
      await until(tester, () => r.app.loading == null && r.app.loadError != null);
      await settle(tester);
      expect(find.textContaining('Sent when'), findsNothing);
      expect(typed(tester), _about.question);
      await tearDownShell(tester);
    });
  });
}
