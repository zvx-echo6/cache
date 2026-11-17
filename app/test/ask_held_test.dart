// "Ask about this" on an alert and Home's "Ask Cache: ..." when a model file is on the device but the model is not loaded (it rests
// until Ask opens or Load is pressed): the question is held, Ask opens in a new chat, the model wakes, and the question is sent once
// the model is loaded. It is dropped when the person sends something else first or the load fails. With a model loaded it is sent at once.

import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/ask_about.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/memory.dart';
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

/// The native session, by hand: a load waits until the test lets it finish, or fails.
class _Session implements LlamaSession {
  Completer<void>? loadGate;
  Object? loadError;

  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async {
    await loadGate?.future;
    if (loadError != null) throw loadError!;
    return _info;
  }

  @override
  Future<void> unload() async {}

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

/// The core's tools: live_data answers, and every call is kept.
class _Host implements ToolHost {
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> schemas() async => [
        {'type': 'function', 'function': {'name': 'live_data', 'parameters': {'type': 'object'}}},
      ];

  @override
  Future<HostToolResult> call(String name, Map<String, dynamic> args, DateTime now) async {
    calls.add(name);
    return HostToolResult(content: '[1] Freeze Warning', ids: const [NumberedAddress(n: 1, address: 'live:nws-alerts-point/1', title: 'Freeze Warning')]);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _Session session;
  late SettingsRig r;
  late LayoutState layout;
  late NavState nav;
  late _Host host;
  late ScriptedBackend backend;
  late ChatController chat;

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

  /// Home with the chosen model resting (a file is on the device, nothing is loaded). The chat takes the loaded model as the app
  /// does (main.dart): the backend when there is a model, none when there is not. [beforeShell] runs before the shell listens.
  Future<void> setUpShell(WidgetTester tester, {void Function()? beforeShell}) async {
    session = _Session();
    host = _Host();
    backend = ScriptedBackend([(_) => say('Answer.')]);
    r = await SettingsRig.create(tester, appFactory: (dir, models) => AppState(
          settingsDirOverride: dir,
          modelsDirOverride: models,
          session: session,
          memory: () async => MemoryReading(avail: 6 * _gb, total: 8 * _gb, threshold: 200 << 20),
        ));
    chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)..attachStore(r.store);
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
    r.app.resting = r.app.models.first;
    tester.view.physicalSize = const Size(430, 932) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    beforeShell?.call();
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

  dynamic shell(WidgetTester tester) => tester.state(find.byType(Shell));

  /// The last user message of the newest request.
  String asked() {
    final m = (backend.requests.last['messages'] as List).cast<Map>();
    return m.lastWhere((x) => x['role'] == 'user')['content'] as String;
  }

  testWidgets('an alert\'s "Ask about this" with the model not loaded: held, the model loads, then the question is sent with its seed', (tester) async {
    await setUpShell(tester);
    session.loadGate = Completer<void>();
    shell(tester).askAbout(_about);
    await until(tester, () => r.app.loading != null);
    expect(r.app.loading, isNotNull, reason: 'Ask opening woke the model');
    expect(chat.messages, isEmpty, reason: 'nothing to send it to yet');
    expect(backend.requests, isEmpty);
    session.loadGate!.complete();
    await until(tester, () => backend.requests.isNotEmpty);
    expect(r.app.active, isNotNull);
    expect(backend.requests, hasLength(1));
    expect(asked(), endsWith(_about.question));
    expect(chat.messages.first.text, _about.question);
    expect(host.calls, ['live_data'], reason: 'the alert\'s own live_data seed went with it');
    await tearDownShell(tester);
  });

  testWidgets('Home search\'s "Ask Cache" with the model not loaded: held, the model loads, then the question is sent', (tester) async {
    await setUpShell(tester);
    session.loadGate = Completer<void>();
    shell(tester).askFromHome('how much water per person');
    await until(tester, () => r.app.loading != null);
    expect(chat.messages, isEmpty);
    expect(backend.requests, isEmpty);
    session.loadGate!.complete();
    await until(tester, () => backend.requests.isNotEmpty);
    expect(backend.requests, hasLength(1));
    expect(asked(), endsWith('how much water per person'));
    expect(chat.messages.first.text, 'how much water per person');
    expect(host.calls, isEmpty, reason: 'no seed for a typed question');
    await tearDownShell(tester);
  });

  testWidgets('held, then the person\'s own question goes first: only theirs is sent, the held one is dropped', (tester) async {
    var mine = false;
    await setUpShell(tester, beforeShell: () {
      // the person's own send, the moment the model is there (before the shell's own look at the chat)
      chat.addListener(() {
        if (mine || !chat.canSend) return;
        mine = true;
        unawaited(chat.send('my own question'));
      });
    });
    session.loadGate = Completer<void>();
    shell(tester).askAbout(_about);
    await until(tester, () => r.app.loading != null);
    session.loadGate!.complete();
    await until(tester, () => backend.requests.isNotEmpty);
    await settle(tester);
    expect(backend.requests, hasLength(1));
    expect(asked(), endsWith('my own question'));
    expect([for (final m in chat.messages) if (m.isUser) m.text], ['my own question']);
    expect(host.calls, isEmpty, reason: 'the held alert was dropped, so its seed never ran');
    await tearDownShell(tester);
  });

  testWidgets('held, then the load fails: nothing is sent, and a later load does not send the old question', (tester) async {
    await setUpShell(tester);
    session.loadGate = Completer<void>();
    session.loadError = StateError('out of memory');
    shell(tester).askAbout(_about);
    await until(tester, () => r.app.loading != null);
    session.loadGate!.complete();
    await until(tester, () => r.app.loading == null && r.app.loadError != null);
    await settle(tester);
    expect(r.app.active, isNull);
    expect(chat.messages, isEmpty);
    expect(backend.requests, isEmpty);
    // not stuck: the model loads on a later try (Load), and the stale question is not sent
    session.loadGate = null;
    session.loadError = null;
    await tester.runAsync(() => r.app.activate(r.app.models.first));
    await settle(tester);
    expect(r.app.active, isNotNull);
    expect(chat.canSend, isTrue);
    expect(backend.requests, isEmpty);
    expect(chat.messages, isEmpty);
    await tearDownShell(tester);
  });

  testWidgets('a model loaded: the question is sent at once, as before', (tester) async {
    await setUpShell(tester);
    await tester.runAsync(() => r.app.activate(r.app.models.first));
    await settle(tester);
    expect(chat.canSend, isTrue);
    shell(tester).askAbout(_about);
    await until(tester, () => backend.requests.isNotEmpty);
    expect(backend.requests, hasLength(1));
    expect(asked(), endsWith(_about.question));
    expect(host.calls, ['live_data']);
    shell(tester).askFromHome('and my dog?');
    await until(tester, () => backend.requests.length == 2);
    expect(asked(), endsWith('and my dog?'));
    await tearDownShell(tester);
  });
}
