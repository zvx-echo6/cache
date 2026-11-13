// Back in front after the chat model was let go in the background: with Ask shown the model loads again (under the same memory gate
// as opening Ask); the releases and loads never fight.

import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/prompt_read_ahead.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/memory.dart';
import 'package:cache/platform/model_release.dart';
import 'package:cache/screens/shell.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/settings_rig.dart';

const _file = 'gemma-4-E2B-it-Q4_K_M.gguf';
const _gb = 1 << 30;
const _info = ModelInfo(description: 'Gemma 4 E2B', nCtx: 8192, chatFormat: 'gemma', supportsTools: true);

/// The read ahead's engine, by hand: it counts the checks it is asked for and says everything is covered.
class _CountingEngine implements ReadAheadEngine {
  _CountingEngine(this.app);
  final AppState app;
  final checks = <bool>[];

  @override
  bool get isLoaded => app.active != null;
  @override
  bool get questionRunning => false;
  @override
  Future<WarmResult> warm(Map<String, dynamic> request, {bool checkOnly = false}) async {
    checks.add(checkOnly);
    return const WarmResult(WarmOutcome.covered);
  }

  @override
  void cancelWarm() {}
}

/// The native session, by hand: a load or an unload waits until the test lets it finish, and every call is kept in order.
class FakeSession implements LlamaSession {
  final calls = <String>[];
  Completer<void>? loadGate;
  Completer<void>? unloadGate;

  @override
  Future<ModelInfo> load(String path, {int nCtx = 8192, bool repackWeights = false, String? prefixDir, int prereadMbps = 0, int nUbatch = 0}) async {
    calls.add('load');
    await loadGate?.future;
    return _info;
  }

  @override
  Future<void> unload() async {
    calls.add('unload');
    await unloadGate?.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  late FakeSession session;
  var avail = 6 * _gb;

  AppState makeApp(Directory dir, Directory models) => AppState(
    settingsDirOverride: dir,
    modelsDirOverride: models,
    session: session,
    memory: () async => MemoryReading(avail: avail, total: 8 * _gb, threshold: 200 << 20),
  );

  setUp(() {
    session = FakeSession();
    avail = 6 * _gb;
  });

  group('Shell: resumed', () {
    late SettingsRig r;
    late LayoutState layout;
    late NavState nav;
    late _CountingEngine engine;
    var hot = false;
    setUp(() => hot = false);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Real time passes (file reads in the memory gate) until [done] holds, at most about two seconds.
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> setUpShell(WidgetTester tester, {void Function(bool shown)? onAskShown}) async {
      r = await SettingsRig.create(tester, appFactory: makeApp);
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
      // the chosen model, let go while Cache was in the back
      r.app.resting = r.app.models.first;
      engine = _CountingEngine(r.app);
      tester.view.physicalSize = const Size(430, 932) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Shell(app: r.app, chat: r.chat, sources: r.sources, location: r.location, maps: r.maps, video: r.video, browse: r.browse, nav: nav, layout: layout, hub: r.hub, readAhead: PromptReadAhead(engine: engine, request: (_) async => {'messages': []}, isHot: () async => hot), railPrefs: RailPrefs(dirOverride: Directory('${r.dir.path}/layout')), onAskShown: onAskShown),
      ));
      await settle(tester);
    }

    Future<void> tearDownShell(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      nav.dispose();
      layout.dispose();
      await r.dispose(tester);
    }

    Future<void> openAsk(WidgetTester tester) async {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ask')));
      await settle(tester);
    }

    Future<void> background(WidgetTester tester) async {
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
    }

    Future<void> resume(WidgetTester tester) async {
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
    }

    testWidgets('the app is told when Ask becomes the screen shown and when it is left (the chat model\'s idle release)', (tester) async {
      final shown = <bool>[];
      await setUpShell(tester, onAskShown: shown.add);
      expect(shown, isEmpty, reason: 'the shell starts on Home');
      await openAsk(tester);
      expect(shown, [true]);
      await openAsk(tester);
      expect(shown, [true], reason: 'Ask again is no change');
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Home')));
      await settle(tester);
      expect(shown, [true, false]);
      await tearDownShell(tester);
    });

    testWidgets('Ask shown and room: the model loads, the loading title shows, and there is no card', (tester) async {
      avail = 1 * _gb; // opening Ask finds no room: stays resting, with the card
      await setUpShell(tester);
      await openAsk(tester);
      expect(r.app.resting, isNotNull);
      expect(find.byKey(const ValueKey('ask-fix')), findsOneWidget);
      expect(session.calls, isEmpty);

      await background(tester);
      avail = 6 * _gb;
      session.loadGate = Completer<void>();
      await resume(tester);
      expect(session.calls, ['load']);
      expect(r.app.loading, isNotNull);
      expect(find.descendant(of: find.byKey(const ValueKey('model-name')), matching: find.text('Loading…')), findsOneWidget);
      expect(find.byKey(const ValueKey('ask-fix')), findsNothing);
      session.loadGate!.complete();
      await settle(tester);
      expect(r.app.active, isNotNull);
      expect(r.app.resting, isNull);
      await tearDownShell(tester);
    });

    testWidgets('Ask shown and the gate holding: the model stays resting and the card shows', (tester) async {
      avail = 1 * _gb;
      await setUpShell(tester);
      await openAsk(tester);
      await background(tester);
      await resume(tester);
      expect(session.calls, isEmpty);
      expect(r.app.active, isNull);
      expect(r.app.resting, isNotNull);
      expect(find.byKey(const ValueKey('ask-fix')), findsOneWidget);
      await tearDownShell(tester);
    });

    testWidgets('Ask opened with room: the model loads, then the prompt start is checked for a read ahead', (tester) async {
      await setUpShell(tester);
      await openAsk(tester);
      await until(tester, () => engine.checks.isNotEmpty);
      expect(r.app.active, isNotNull);
      expect(engine.checks, [true], reason: 'one check, after the load');
      await tearDownShell(tester);
    });

    testWidgets('Ask opened with no room: the model stays out and nothing is read ahead', (tester) async {
      avail = 1 * _gb;
      await setUpShell(tester);
      await openAsk(tester);
      expect(r.app.active, isNull);
      expect(engine.checks, isEmpty);
      await tearDownShell(tester);
    });

    testWidgets('back in front with Ask shown: the model loads and the prompt start is checked again', (tester) async {
      await setUpShell(tester);
      await openAsk(tester);
      await until(tester, () => engine.checks.isNotEmpty);
      engine.checks.clear();
      await tester.runAsync(r.app.release);
      await background(tester);
      await resume(tester);
      await until(tester, () => engine.checks.isNotEmpty);
      expect(r.app.active, isNotNull);
      expect(engine.checks, [true]);
      await tearDownShell(tester);
    });

    testWidgets('Ask opened while the model is still loading (the app start\'s load): the read ahead starts when the load completes, once', (tester) async {
      await setUpShell(tester);
      r.app.resting = null;
      session.loadGate = Completer<void>();
      unawaited(r.app.activate(r.app.models.first));
      await settle(tester);
      expect(r.app.loading, isNotNull);
      await openAsk(tester);
      expect(engine.checks, isEmpty, reason: 'no model yet: no read');
      session.loadGate!.complete();
      await until(tester, () => engine.checks.isNotEmpty);
      expect(r.app.active, isNotNull);
      expect(engine.checks, [true], reason: 'the read starts on load completion');
      r.app.notifyListeners();
      await settle(tester);
      expect(engine.checks, [true], reason: 'one read per opening');
      await tearDownShell(tester);
    });

    testWidgets('Ask opened while the model loads and the device is hot: no read when the load completes', (tester) async {
      hot = true;
      await setUpShell(tester);
      r.app.resting = null;
      session.loadGate = Completer<void>();
      unawaited(r.app.activate(r.app.models.first));
      await settle(tester);
      await openAsk(tester);
      session.loadGate!.complete();
      await settle(tester);
      await until(tester, () => r.app.active != null);
      await settle(tester);
      expect(engine.checks, isEmpty);
      await tearDownShell(tester);
    });

    testWidgets('another model loaded while Ask stays open: the new model gets its read ahead', (tester) async {
      await setUpShell(tester);
      await openAsk(tester);
      await until(tester, () => engine.checks.isNotEmpty);
      expect(engine.checks, [true]);
      engine.checks.clear();
      await tester.runAsync(r.app.release);
      await tester.runAsync(r.app.wake); // the model is loaded again (a new generation), Ask never closed
      await until(tester, () => engine.checks.isNotEmpty);
      expect(engine.checks, [true], reason: 'a new model: one read');
      await tearDownShell(tester);
    });

    testWidgets('another module shown: nothing loads on resume', (tester) async {
      await setUpShell(tester); // Home is shown; there is room
      await background(tester);
      await resume(tester);
      expect(session.calls, isEmpty);
      expect(r.app.active, isNull);
      expect(r.app.resting, isNotNull);
      await tearDownShell(tester);
    });
  });

  group('races between the release, a load and the person coming back', () {
    late Directory dir;
    late AppState app;
    late BackgroundModelRelease bg;
    const grace = Duration(milliseconds: 80);

    Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    // The model is loaded, and the background release is wired as in main.dart.
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('wake-races');
      Directory('${dir.path}/models').createSync();
      File('${dir.path}/models/$_file').writeAsBytesSync(List.filled(16, 0));
      app = makeApp(dir, Directory('${dir.path}/models'));
      app.models = [ModelEntry(path: '${dir.path}/models/$_file', size: 16)];
      await app.activate(app.models.first);
      expect(app.active, isNotNull);
      session.calls.clear();
      bg = BackgroundModelRelease(
        busy: () => app.loading != null,
        loaded: () => app.active != null,
        release: app.release,
        changes: app,
        grace: grace,
      );
    });
    tearDown(() {
      bg.dispose();
      dir.deleteSync(recursive: true);
    });

    /// Loaded or resting, never both and never neither (while nothing loads).
    void consistent() {
      if (app.loading != null) return;
      expect((app.active != null) != (app.resting != null), isTrue, reason: 'active ${app.active}, resting ${app.resting}');
    }

    test('back in front just before the timer fires: toFront cancels it, nothing is released, the wake finds the model loaded', () async {
      bg.toBackground();
      await pause(60);
      bg.toFront();
      await app.wake();
      await pause(200);
      expect(session.calls, isEmpty);
      expect(app.active, isNotNull);
      consistent();
    });

    test('the wake runs before toFront: the same result', () async {
      bg.toBackground();
      await pause(60);
      final w = app.wake();
      bg.toFront();
      await w;
      await pause(200);
      expect(session.calls, isEmpty);
      expect(app.active, isNotNull);
    });

    test('back in front just after the timer fired: the wake waits for the unload, then loads; the model ends loaded', () async {
      session.unloadGate = Completer<void>();
      bg.toBackground();
      await pause(120); // fired: the release is in progress, its unload not done
      expect(session.calls, ['unload']);
      expect(app.active, isNull);
      expect(app.resting, isNotNull);
      bg.toFront();
      final w = app.wake();
      await pause(30);
      expect(session.calls, ['unload'], reason: 'the load does not begin under the unload');
      session.unloadGate!.complete();
      await w;
      expect(session.calls, ['unload', 'load']);
      expect(app.active, isNotNull);
      expect(app.resting, isNull);
      consistent();
    });

    test('a wake while a release is in progress: it waits, then loads', () async {
      session.unloadGate = Completer<void>();
      final rel = app.release();
      final w = app.wake();
      await pause(30);
      expect(session.calls, ['unload']);
      session.unloadGate!.complete();
      await Future.wait([rel, w]);
      expect(session.calls, ['unload', 'load']);
      expect(app.active, isNotNull);
      consistent();
    });

    test('a manual unload in progress: a load that follows waits for it, as after a release', () async {
      session.unloadGate = Completer<void>();
      final un = app.unload();
      final act = app.activate(app.models.first);
      await pause(30);
      expect(session.calls, ['unload'], reason: 'the load has not begun under the unload');
      session.unloadGate!.complete();
      await Future.wait([un, act]);
      expect(session.calls, ['unload', 'load']);
    });

    test('the release timer fires while a wake-load is in flight: it waits, and never unloads a model just asked for', () async {
      await app.release();
      session.calls.clear();
      session.loadGate = Completer<void>();
      bg.toBackground();
      final w = app.wake();
      await pause(250); // well past the grace, load still in flight
      expect(session.calls, ['load']);
      expect(app.loading, isNotNull);
      expect(app.resting, isNull);
      session.loadGate!.complete();
      await w;
      expect(app.active, isNotNull);
      consistent();
      // Cache is still in the back: a new grace period starts when the load ends, then the model is released
      await pause(40);
      expect(session.calls, ['load'], reason: 'not before the new grace period has passed');
      await pause(150);
      expect(session.calls, ['load', 'unload']);
      expect(app.active, isNull);
      expect(app.resting, isNotNull);
      consistent();
    });

    test('a double resume loads the model once', () async {
      await app.release();
      session.calls.clear();
      session.loadGate = Completer<void>();
      final a = app.wake();
      final b = app.wake();
      await pause(30);
      session.loadGate!.complete();
      await Future.wait([a, b]);
      expect(session.calls, ['load']);
      expect(app.active, isNotNull);
      consistent();
    });

    test('a double resume with the memory read slow loads once too', () async {
      await app.release();
      session.calls.clear();
      final a = app.wake();
      final b = app.wake();
      await Future.wait([a, b]);
      expect(session.calls, ['load']);
      expect(app.active, isNotNull);
    });
  });

  test('the grace period constant is unchanged', () => expect(kBackgroundReleaseGrace, const Duration(seconds: 30)));
}
