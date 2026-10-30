import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/navigation_action.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/screens/ask_screen.dart';
import 'package:cache/search/core_tool_host.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'chat_fakes.dart';
import 'nav_fakes.dart';
import 'support/act_core_stand_in.dart';

class ActionHost implements ToolHost {
  ActionHost(this.actions);
  final List<NavigationAction> actions;
  @override
  Future<List<Map<String, dynamic>>> schemas() async => [
    {
      'type': 'function',
      'function': {
        'name': 'navigate',
        'parameters': {'type': 'object'},
      },
    },
  ];
  @override
  Future<HostToolResult> call(
    String name,
    Map<String, dynamic> args,
    DateTime now,
  ) async => HostToolResult(
    content: '{"ok":true,"route_id":"exact"}',
    ids: const [],
    navigationActions: actions,
  );
  @override
  Future<void> dispose() async {}
}

class RepeatedRouteHost extends ActionHost {
  RepeatedRouteHost(super.actions);
  int calls = 0;
  final lookups = <String>[];
  @override
  Future<HostToolResult> call(
    String name,
    Map<String, dynamic> args,
    DateTime now,
  ) async {
    final ids = calls++ == 0
        ? const [NumberedAddress(n: 1, address: 'nav:exact', title: 'Route')]
        : const <NumberedAddress>[];
    final content = jsonEncode({'ok': true, 'route_id': 'exact', 'n': 1});
    return HostToolResult(
      content: content,
      ids: ids,
      navigationActions: await CoreToolHost.actionsFor(name, content, ids, (
        id,
      ) async {
        lookups.add(id);
        return actions.single.route!;
      }),
    );
  }
}

PartialMessage navigate() => PartialMessage(
  isFinal: true,
  toolCalls: [
    ToolCall(id: 'nav-call', name: 'navigate', arguments: '{"to":"hospital"}'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('route-action-'));
  tearDown(() => dir.deleteSync(recursive: true));
  NavigationAction action([String id = 'exact']) => NavigationAction(
    address: 'nav:$id',
    route: MapRoute.fromJson(fakeRouteJson(id: id, name: 'Hôpital → 家')),
  );

  test(
    'structured navigate success drives lookup, including reused numbering; failures do not',
    () async {
      final calls = <String>[];
      Future<MapRoute> lookup(String id) async {
        calls.add(id);
        if (id == 'gone') {
          throw const CacheSearchException('not_found', 'evicted');
        }
        if (id == 'older') {
          throw const CacheSearchException('unsupported', 'older core');
        }
        return MapRoute.fromJson(
          fakeRouteJson(id: id == 'wrong' ? 'different' : id),
        );
      }

      String success(String id) =>
          jsonEncode({'ok': true, 'route_id': id, 'n': 1});
      for (final content in [
        'not JSON',
        '{"ok":false,"route_id":"exact"}',
        '{"ok":true}',
        '{"ok":true,"route_id":5}',
        '{"ok":true,"route_id":""}',
      ]) {
        expect(
          await CoreToolHost.actionsFor('navigate', content, const [], lookup),
          isEmpty,
        );
      }
      expect(
        await CoreToolHost.actionsFor(
          'search',
          success('exact'),
          const [],
          lookup,
        ),
        isEmpty,
      );
      expect(
        await CoreToolHost.actionsFor('navigate', success('exact'), const [
          NumberedAddress(n: 1, address: 'nav:other', title: 'Other'),
        ], lookup),
        isEmpty,
      );
      expect(calls, isEmpty);
      final results = <NavigationAction>[];
      for (final id in ['exact', 'gone', 'wrong', 'older']) {
        results.addAll(
          await CoreToolHost.actionsFor(
            'navigate',
            success(id),
            const [],
            lookup,
          ),
        );
      }
      expect(calls, ['exact', 'gone', 'wrong', 'older']);
      expect(results.first.route!.routeId, 'exact');
      expect(results.skip(1).every((a) => a.route == null), isTrue);
    },
  );

  test(
    'snapshots persist before next model request, reopen, and never enter model context',
    () async {
      final path = '${dir.path}/chat.sqlite';
      final store = ConversationStore.open(path);
      final a = action();
      final entered = Completer<void>();
      final backend = ScriptedBackend([
        (_) => navigate(),
        (request) {
          final saved = store.messages(store.list().single.id);
          expect(saved.last.navigationActions.single.route!.raw, a.route!.raw);
          expect(saved.last.inTranscript, isFalse);
          expect(jsonEncode(request), isNot(contains(a.route!.geometry)));
          expect(jsonEncode(request), isNot(contains('Hôpital')));
          entered.complete();
          return say('Here is your route.');
        },
      ]);
      final host = ActionHost([a]);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)
        ..attachStore(store)
        ..setBackend(backend);
      await chat.send('Take me there');
      await entered.future;
      await chat.whenIdle();
      final id = chat.activeId!;
      expect(chat.messages.last.navigationActions.single.address, 'nav:exact');
      expect(chat.messages.last.sources, isEmpty); // no prose citation needed
      expect(
        store.messages(id).where((m) => m.shown && m.role == 'assistant'),
        hasLength(1),
      );
      expect(
        jsonEncode(store.transcript(id)),
        isNot(contains(a.route!.geometry)),
      );
      expect(
        backend.titleRequests.every(
          (r) => !jsonEncode(r).contains(a.route!.geometry),
        ),
        isTrue,
      );
      chat.newChat();
      store.close();
      final reopened = ConversationStore.open(path);
      final restored = ChatController(actCore: const ActCoreStandIn(), tools: const [])
        ..attachStore(reopened)
        ..openConversation(id);
      expect(
        restored.messages.last.navigationActions.single.route!.raw,
        a.route!.raw,
      );
      expect(restored.messages.last.text, 'Here is your route.');
      reopened.close();
    },
  );

  test(
    'v1 migration retains messages and old nav citations show unavailable',
    () {
      final path = '${dir.path}/old.sqlite';
      var store = ConversationStore.open(path);
      final id = store.create(title: 'Old route').id;
      store.addMessage(
        id,
        role: 'assistant',
        content: 'Old reply',
        message: {'role': 'assistant', 'content': 'Old reply'},
        citations: const [
          StoredCitation(n: 1, title: 'Route', snippet: '', address: 'nav:old'),
        ],
      );
      store.close();
      final db = sqlite3.open(path);
      db.execute('ALTER TABLE messages DROP COLUMN navigation_actions_json');
      db.execute('ALTER TABLE conversations DROP COLUMN voice');
      db.userVersion = 1;
      db.close();
      store = ConversationStore.open(path);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [])
        ..attachStore(store)
        ..openConversation(id);
      expect(chat.messages.single.text, 'Old reply');
      expect(chat.messages.single.navigationActions.single.address, 'nav:old');
      expect(chat.messages.single.navigationActions.single.route, isNull);
      expect(store.transcript(id).single['content'], 'Old reply');
      store.close();
    },
  );

  test(
    'damaged or mismatched snapshot is unavailable without hiding message',
    () {
      final a = NavigationAction.fromJson({
        'address': 'nav:exact',
        'route': fakeRouteJson(id: 'other'),
      })!;
      expect(a.route, isNull);
      expect(NavigationAction.decode('{broken'), isEmpty);
      expect(
        NavigationAction.fromJson({
          'address': 'nav:exact',
          'route': {'geometry': 1},
        })!.route,
        isNull,
      );
    },
  );

  testWidgets(
    'button is independent of prose/citations; missing snapshot shows unavailable',
    (tester) async {
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
      chat.messages.addAll([
        ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..navigationActions = [action()],
        ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..text = 'Ordinary reply'
          ..navigationActions = [NavigationAction(address: 'nav:gone')],
      ]);
      NavigationAction? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(CacheThemeId.dark),
          home: AskScreen(
            app: app,
            chat: chat,
            onOpenNavigation: (a) => opened = a,
          ),
        ),
      );
      expect(find.text('Open navigation'), findsOneWidget);
      expect(find.textContaining('Navigation unavailable'), findsOneWidget);
      expect(find.text('Ordinary reply'), findsOneWidget);
      await tester.tap(find.text('Open navigation'));
      expect(opened!.route!.routeId, 'exact');
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      chat.dispose();
    },
  );
  testWidgets(
    'multiple routes show snapshot destinations at large text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();

      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const []);
      const first =
          'Hôpital → 家 with a very long destination name across several lines';
      const second =
          'Second destination with another long name for the exact saved route';
      final a = NavigationAction(
        address: 'nav:first',
        route: MapRoute.fromJson(fakeRouteJson(id: 'first', name: first)),
      );
      final b = NavigationAction(
        address: 'nav:second',
        route: MapRoute.fromJson(fakeRouteJson(id: 'second', name: second)),
      );
      chat.messages.add(
        ChatMessage.assistant()
          ..phase = TurnPhase.done
          ..navigationActions = [a, b],
      );
      NavigationAction? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(CacheThemeId.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: AskScreen(
            app: app,
            chat: chat,
            onOpenNavigation: (a) => opened = a,
          ),
        ),
      );
      expect(find.text('To $first'), findsOneWidget);
      expect(find.text('To $second'), findsOneWidget);
      expect(find.text('Open navigation'), findsNWidgets(2));
      await tester.ensureVisible(find.text('Open navigation').last);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.bySemanticsLabel(RegExp('To ${RegExp.escape(second)}')),
        findsWidgets,
      );
      await tester.tap(find.text('Open navigation').last);
      expect(opened!.route!.routeId, 'second');
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      chat.dispose();
    },
  );
  test(
    'repeated successful route with no new ids still attaches and persists on its own turn',
    () async {
      final store = ConversationStore.memory();
      final host = RepeatedRouteHost([action()]);
      final backend = ScriptedBackend([
        (_) => navigate(),
        (_) => say('First route'),
        (_) => navigate(),
        (_) => say('Same route again, uncited'),
      ]);
      final chat = ChatController(actCore: const ActCoreStandIn(), tools: const [], newHost: (_) => host)
        ..attachStore(store)
        ..setBackend(backend);
      await chat.send('First navigation');
      await chat.whenIdle();
      await chat.send('Repeat navigation');
      await chat.whenIdle();
      final id = chat.activeId!;
      expect(host.lookups, ['exact', 'exact']);
      expect(chat.messages.last.sources, isEmpty);
      expect(
        chat.messages.last.navigationActions.single.route!.routeId,
        'exact',
      );
      final replies = store
          .messages(id)
          .where((m) => m.shown && m.role == 'assistant')
          .toList();
      expect(replies, hasLength(2));
      expect(
        replies.every(
          (m) => m.navigationActions.single.route!.routeId == 'exact',
        ),
        isTrue,
      );
      chat.newChat();
      chat.openConversation(id);
      expect(chat.messages.last.navigationActions.single.address, 'nav:exact');
      store.close();
    },
  );
}
