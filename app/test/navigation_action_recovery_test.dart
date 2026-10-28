import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/navigation_action.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/history/titles.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';
import 'nav_fakes.dart';
import 'navigation_action_test.dart' show ActionHost, navigate;

class BlockAnswer implements ModelBackend {
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    if (((request['messages'] as List).last as Map)['content'] ==
        kTitlePrompt) {
      yield say('Saved route');
      return;
    }
    if (calls++ == 0) {
      yield navigate();
      return;
    }
    entered.complete();
    await release.future;
    yield say('Ordinary reply with no citation.');
  }

  @override
  void stop() {}
}

class DelayedHost extends ActionHost {
  DelayedHost(super.actions);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<HostToolResult> call(
    String name,
    Map<String, dynamic> args,
    DateTime now,
  ) async {
    entered.complete();
    await release.future;
    return super.call(name, args, now);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('route-recovery-'));
  tearDown(() => dir.deleteSync(recursive: true));
  NavigationAction action() => NavigationAction(
    address: 'nav:exact',
    route: MapRoute.fromJson(fakeRouteJson(id: 'exact', name: 'Hôpital → 家')),
  );

  test(
    'crash-style reopen recovers full snapshot while model answer is still blocked',
    () async {
      final path = '${dir.path}/chat.sqlite';
      final store = ConversationStore.open(path);
      final a = action();
      final backend = BlockAnswer();
      final chat =
          ChatController(tools: const [], newHost: (_) => ActionHost([a]))
            ..attachStore(store)
            ..setBackend(backend);
      final sending = chat.send('Navigate');
      await backend.entered.future;
      final id = chat.activeId!;
      expect(chat.busy, isTrue);
      final reopened = ConversationStore.open(path);
      final restored = ChatController(tools: const [])
        ..attachStore(reopened)
        ..openConversation(id);
      expect(
        restored.messages.last.navigationActions.single.route!.raw,
        a.route!.raw,
      );
      expect(restored.messages.last.text, isEmpty);
      expect(reopened.transcript(id), [
        {'role': 'user', 'content': 'Navigate'},
      ]);
      expect(restored.exportMarkdown(id), isNot(contains(a.route!.geometry)));
      expect(restored.exportMarkdown(id), isNot(contains('Hôpital')));
      reopened.close();
      backend.release.complete();
      await sending;
      await chat.whenIdle();
      expect(
        store.messages(id).where((m) => m.shown && m.role == 'assistant'),
        hasLength(1),
      );
      expect(chat.messages.last.text, 'Ordinary reply with no citation.');
      store.close();
    },
  );

  for (final reset in [false, true]) {
    test(
      '${reset ? 'newChat' : 'stop'} during lookup retains action on original assistant turn',
      () async {
        final store = ConversationStore.memory();
        final host = DelayedHost([action()]);
        final backend = ScriptedBackend([
          (_) => navigate(),
          (_) => say('Old answer'),
        ]);
        final chat = ChatController(tools: const [], newHost: (_) => host)
          ..attachStore(store)
          ..setBackend(backend);
        final sending = chat.send('Old question');
        await host.entered.future;
        final original = chat.activeId!;
        if (reset) {
          chat.newChat();
          chat.setBackend(ScriptedBackend([(_) => say('New answer')]));
          await chat.send('New question');
          await chat.whenIdle();
        } else {
          chat.stop();
        }
        host.release.complete();
        await sending;
        await chat.whenIdle();
        final old = store
            .messages(original)
            .where((m) => m.shown && m.role == 'assistant')
            .single;
        expect(old.navigationActions.single.route!.routeId, 'exact');
        if (reset) {
          expect(chat.activeId, isNot(original));
          expect(chat.messages.last.navigationActions, isEmpty);
          expect(
            store
                .messages(chat.activeId!)
                .every((m) => m.navigationActions.isEmpty),
            isTrue,
          );
        }
        expect(
          jsonEncode(store.transcript(original)),
          isNot(contains(action().route!.geometry)),
        );
        store.close();
      },
    );
  }

  test(
    'ordinary and failed tool replies carry no action across turns',
    () async {
      final store = ConversationStore.memory();
      final backend = ScriptedBackend([
        (_) => navigate(),
        (_) => say('Could not find a route.'),
        (_) => say('Hello'),
      ]);
      final chat =
          ChatController(tools: const [], newHost: (_) => ActionHost([]))
            ..attachStore(store)
            ..setBackend(backend);
      await chat.send('Unavailable route');
      await chat.whenIdle();
      expect(chat.messages.last.navigationActions, isEmpty);
      await chat.send('Hello');
      await chat.whenIdle();
      expect(chat.messages.last.navigationActions, isEmpty);
      store.close();
    },
  );

  test(
    'corrupted coordinates, geometry and unsupported mode cannot become previews',
    () {
      for (final raw in [
        {
          ...fakeRouteJson(id: 'exact'),
          'from': {'lat': double.nan, 'lon': 0},
        },
        {
          ...fakeRouteJson(id: 'exact'),
          'to': {'lat': 91, 'lon': 0},
        },
        {
          ...fakeRouteJson(id: 'exact'),
          'to': {'lat': 0, 'lon': 181},
        },
        {...fakeRouteJson(id: 'exact'), 'mode': 'unsupported'},
        {
          ...fakeRouteJson(id: 'exact'),
          'geometry': encodePolyline6([
            const GeoPoint(91, 0),
            const GeoPoint(0, 0),
          ]),
        },
      ]) {
        expect(
          NavigationAction(
            address: 'nav:exact',
            route: MapRoute.fromJson(raw),
          ).route,
          isNull,
        );
      }
    },
  );
}
