import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/chat_location.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'package:cache/chat/tool.dart' show NumberedAddress;
import 'location_service_test.dart' show FakeSource;

class PendingNumbering extends MemoryNumbering {
  PendingNumbering() : super([]);
  final ready = Completer<List<NumberedAddress>>();
  int disposed = 0;
  @override
  Future<List<NumberedAddress>> ids() => ready.future;
  @override
  Future<void> dispose() async { disposed++; }
}

class FailingGps extends FakeSource {
  @override
  Future<Fix> current() async {
    currentCalls++;
    throw StateError('GPS unavailable');
  }
}

class SettingsSource extends FakeSource {
  int settingsOpened = 0;
  @override
  Future<void> openAppSettings() async { settingsOpened++; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('chat-location-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Fix fresh() => Fix(lat: 42.5, lon: -113.8, accuracyM: 10, time: DateTime.now());

  Future<(LocationService, ChatLocation)> setup(FakeSource source,
      {Future<bool> Function(Fix?)? sync}) async {
    late ChatLocation bridge;
    final location = LocationService(source: source, settingsDirOverride: dir, onFix: (f) => bridge.update(f));
    bridge = ChatLocation(location: location, synchronize: sync ?? (_) async => true);
    await location.init();
    addTearDown(location.dispose);
    return (location, bridge);
  }

  ChatController controller(ChatLocation bridge, ScriptedBackend backend) =>
      ChatController(tools: const [], prepareTurn: bridge.prepare, locationKnown: () => bridge.known)
        ..setBackend(backend);

  String prompt(Map<String, dynamic> request) => ((request['messages'] as List).first as Map)['content'] as String;

  test('granted fresh position and acknowledged core sync precede inference', () async {
    final source = FakeSource()..state = LocationPermissionState.granted..next = fresh();
    final write = Completer<bool>();
    Fix? coreFix;
    final (_, bridge) = await setup(source, sync: (f) async {
      final ok = await write.future;
      coreFix = f;
      return ok;
    });
    final backend = ScriptedBackend([(r) {
      expect(coreFix, same(source.next));
      expect(prompt(r), contains("current location is known;"));
      return say('Hello');
    }]);
    final chat = controller(bridge, backend);
    final sending = chat.send('hello');
    await Future<void>.delayed(Duration.zero);
    expect(source.currentCalls, 1);
    expect(backend.requests, isEmpty);
    write.complete(true);
    await sending;
    expect(backend.requests, hasLength(1));
    expect(source.prompts, 0);
    expect(source.streamStarts, 1, reason: 'silent preparation never starts another stream');
  });


  test('GPS failure and absent core still allow chat with unknown location', () async {
    final source = FailingGps()..state = LocationPermissionState.granted;
    final (_, bridge) = await setup(source);
    final backend = ScriptedBackend([(r) {
      expect(prompt(r), contains("current location is not known."));
      return say('Hello');
    }]);
    await controller(bridge, backend).send('hello');
    expect(backend.requests, hasLength(1));
    expect(source.prompts, 0);
    expect(await SourcesState().setLocation(null, null), isFalse);
  });

  test('unexpected optional preparation failure cannot block ordinary chat', () async {
    final backend = ScriptedBackend([(_) => say('Hello')]);
    final chat = ChatController(tools: const [], prepareTurn: (_) async {
      throw StateError('optional location unavailable');
    })..setBackend(backend);
    await chat.send('hello');
    expect(backend.requests, hasLength(1));
    expect(chat.messages.last.error, isNull);
  });

  test('recent position is reused without another GPS acquisition', () async {
    final source = FakeSource()..state = LocationPermissionState.granted..next = fresh();
    final (location, bridge) = await setup(source);
    location.publish(source.next);
    await bridge.prepare(() => false);
    expect(source.currentCalls, 0);
    expect(bridge.known, isTrue);
    expect(source.prompts, 0);
  });

  for (final mode in ['denied', 'off', 'service off', 'core failure']) {
    test('$mode does not prevent ordinary chat or falsely claim core location', () async {
      final source = FakeSource()..next = fresh();
      source.state = mode == 'denied' ? LocationPermissionState.deniedForever : LocationPermissionState.granted;
      source.service = mode != 'service off';
      final (location, bridge) = await setup(source, sync: (_) async => mode != 'core failure');
      if (mode == 'off') await location.setEnabled(false);
      final backend = ScriptedBackend([(r) {
        expect(prompt(r), contains("current location is not known."));
        return say('Hello');
      }]);
      await controller(bridge, backend).send('hello');
      expect(backend.requests, hasLength(1));
      expect(source.prompts, 0);
      if (mode == 'core failure') expect(location.fix, isNotNull);
    });
  }

  test('silent timeout ignores late GPS completion', () async {
    final source = FakeSource()..state = LocationPermissionState.granted;
    final pending = Completer<Fix>();
    source.pendingFix = pending.future;
    final (location, _) = await setup(source);
    expect(await location.prepareForChat(isCancelled: () => false,
        timeout: const Duration(milliseconds: 1)), isNull);
    pending.complete(fresh());
    await Future<void>.delayed(Duration.zero);
    expect(location.fix, isNull);
    expect(source.prompts, 0);
  });

  test('guidance reuses a recent fix and never acquires another stream or fix', () async {
    final source = FakeSource()..state = LocationPermissionState.granted..next = fresh();
    final (location, bridge) = await setup(source);
    location.holdStream(true);
    location.publish(source.next);
    await bridge.prepare(() => false);
    expect(bridge.known, isTrue);
    expect(source.currentCalls, 0);
    expect(source.streamStarts, 1);
  });

  test('ordered writes cannot let an older fix overwrite the prepared core fix', () async {
    final source = FakeSource()..state = LocationPermissionState.granted;
    final firstWrite = Completer<bool>();
    var count = 0;
    Fix? coreFix;
    final (location, bridge) = await setup(source, sync: (f) async {
      if (++count == 1) await firstWrite.future;
      coreFix = f;
      return true;
    });
    final first = fresh(), second = fresh();
    location.publish(first);
    location.publish(second);
    final backend = ScriptedBackend([(r) {
      expect(coreFix, same(second));
      expect(bridge.known, isTrue);
      return say('Hello');
    }]);
    final sending = controller(bridge, backend).send('hello');
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests, isEmpty);
    firstWrite.complete(true);
    await sending;
    expect(coreFix, same(second));
  });

  for (final action in ['stop', 'new chat']) {
    test('$action during location preparation cannot start inference or publish late fix', () async {
      final source = FakeSource()..state = LocationPermissionState.granted;
      final pending = Completer<Fix>();
      source.pendingFix = pending.future;
      final (location, bridge) = await setup(source);
      final backend = ScriptedBackend([(_) => say('Hello')]);
      final chat = controller(bridge, backend);
      final sending = chat.send('old');
      await Future<void>.delayed(Duration.zero);
      if (action == 'stop') { chat.stop(); } else { chat.newChat(); }
      pending.complete(fresh());
      await sending;
      expect(backend.requests, isEmpty);
      expect(location.fix, isNull);
      expect(chat.busy, isFalse);
      source.pendingFix = null;
      source.next = fresh();
      await chat.send('new');
      expect(backend.requests, hasLength(1));
      expect(chat.messages.last.text, 'Hello');
    });
  }

  for (final action in ['stop', 'new chat']) {
    test('$action while numbering sync is pending cannot start backend', () async {
      final numbering = PendingNumbering();
      final backend = ScriptedBackend([(_) => say('Hello')]);
      final chat = ChatController(tools: const [], newNumbering: () => numbering)..setBackend(backend);
      final sending = chat.send('old');
      await Future<void>.delayed(Duration.zero);
      if (action == 'stop') { chat.stop(); } else { chat.newChat(); }
      numbering.ready.complete([]);
      await sending;
      expect(backend.requests, isEmpty);
      expect(numbering.disposed, 1);
    });
  }

  test('preparation runs for new, continuing and reopened conversations', () async {
    var preparations = 0;
    final store = ConversationStore.memory();
    addTearDown(store.close);
    final backend = ScriptedBackend([(_) => say('Hello')]);
    final chat = ChatController(tools: const [], prepareTurn: (_) async { preparations++; })
      ..attachStore(store)..setBackend(backend);
    await chat.send('first');
    await chat.whenIdle();
    final id = chat.activeId!;
    await chat.send('second');
    chat.newChat();
    chat.openConversation(id);
    await chat.send('third');
    expect(preparations, 3);
    expect(backend.requests, hasLength(3));
  });

  testWidgets('Ask never asks for the location: no location line; the + menu holds the "Use my location" switch', (tester) async {
    final source = SettingsSource()..next = fresh();
    final (location, bridge) = (await tester.runAsync(() => setup(source)))!;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark),
        home: AskScreen(app: AppState(), chat: ChatController(tools: const []), location: location, chatLocation: bridge)));
    expect(find.text('Use my location'), findsNothing);
    expect(find.text('Location ready'), findsNothing);
    expect(source.prompts, 0);
    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    await tester.pumpAndSettle();
    expect(find.text('Use my location'), findsOneWidget);
    expect(find.text('Cache finds things near you'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('use-my-location'))).value, isTrue);
    // The switch turns location off (run on the real event loop: the choice is written to a file before the folder goes).
    final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('use-my-location')));
    await tester.runAsync(() async {
      sw.onChanged!(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(location.enabled, isFalse);
    expect(source.prompts, 0, reason: 'nothing is asked');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('when the phone blocks the location, the switch is off and says why, with the way to the phone settings', (tester) async {
    final source = SettingsSource()..state = LocationPermissionState.deniedForever;
    final (location, _) = (await tester.runAsync(() => setup(source)))!;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark),
        home: AskScreen(app: AppState(), chat: ChatController(tools: const []), location: location)));
    await tester.tap(find.byKey(const ValueKey('ask-plus')));
    await tester.pumpAndSettle();
    final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('use-my-location')));
    expect(sw.onChanged, isNull);
    expect(sw.value, isFalse);
    expect(find.text("Blocked in the phone's settings"), findsOneWidget);
    await tester.tap(find.text("Open the phone's settings"));
    await tester.pumpAndSettle();
    expect(source.settingsOpened, 1);
    expect(source.prompts, 0);
  });
}
