import 'dart:convert';

import 'package:cache/actions/act_core.dart';
import 'package:cache/actions/action_registry.dart';
import 'package:cache/actions/confirm.dart';
import 'package:cache/chat/chat_controller.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/history/conversation_store.dart';
import 'package:cache/screens/confirm_card.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fakes.dart';

/// Plays the core's act tool for a change action: the call comes back as needs_confirmation, c1, c2, ...
class FakeAct extends TextTool {
  int n = 0;

  @override
  String get name => 'act';
  @override
  String get description => 'act';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};

  @override
  Future<String> runText(Map<String, dynamic> args, NumberedResult? Function(int n) lookup) async {
    final fields = (args['fields'] as Map).cast<String, dynamic>();
    return jsonEncode({
      'ok': true,
      'status': 'needs_confirmation',
      'confirm_id': 'c${++n}',
      'action': args['action'],
      'title': 'Save a place',
      'summary': {'name': fields['name'], 'place': '44.21000, -114.93000 (12 mi NE of Stanley)'},
    });
  }
}

PartialMessage callAct(String id) => PartialMessage(
      isFinal: true,
      toolCalls: [
        ToolCall(id: id, name: 'act', arguments: jsonEncode({'action': 'places.save', 'fields': {'name': 'Elk camp', 'place': '44.21,-114.93'}})),
      ],
    );

const _placeFields = {
  'places.save': {'place'},
};

Map<String, dynamic> _saveDef() => {
      'id': 'places.save',
      'module': 'places',
      'title': 'Save a place',
      'description': "Save a place to the user's saved places.",
      'effect': 'change',
      'fields': {
        'name': {'type': 'string'},
        'place': {'type': 'place'},
      },
      'required': ['name', 'place'],
    };

/// Records cs_act_resolve calls and answers like the core: places become coordinates with a name.
class RecordingActCore implements ActCore {
  final calls = <String>[];
  Map<String, dynamic>? answer;

  @override
  Future<void> install(List<Map<String, dynamic>> definitions, Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) run) async {}

  @override
  Future<Map<String, dynamic>> actResolve(String action, Map<String, dynamic> fields) async {
    calls.add(action);
    return answer ??
        {
          'ok': true,
          'action': action,
          'fields': {...fields, 'place': {'lat': 44.21, 'lon': -114.93, 'name': 'Elk camp', 'label': '12 mi NE of Stanley'}},
        };
  }
}

class Harness {
  Harness({ActOutcomeForm form = kActOutcomeForm, this.fail = false, ActCore? core}) {
    registry.publish('places', [_saveDef()], {
      'places.save': (f) async {
        runs.add(f);
        if (fail) throw const ActionFailure('full', 'No room for more places.');
        return {'name': f['name']};
      },
    });
    chat = ChatController(
      tools: [FakeAct()],
      actions: registry,
      actCore: core ?? const ActCoreStandIn(placeFields: _placeFields),
      outcomeForm: form,
    )
      ..attachStore(store)
      ..setBackend(backend);
  }

  final bool fail;
  final registry = ActionRegistry();
  final runs = <Map<String, dynamic>>[];
  final store = ConversationStore.memory();
  final backend = ScriptedBackend([
    (_) => callAct('t1'),
    (_) => say('I put up a card to save Elk camp. Nothing is saved until you tap Save a place.'),
    (_) => say('Elk camp is saved.'),
  ]);
  late final ChatController chat;

  /// Sends the question and waits until the title is written too.
  Future<void> ask(String text) async {
    await chat.send(text);
    await chat.whenIdle();
  }
}

Widget _cards(ChatController chat) => MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: chat,
          builder: (context, _) => ListView(children: [
            for (final m in chat.messages)
              for (final c in m.confirms) ConfirmCardView(card: c, enabled: chat.canSend, onDecide: (ok) => chat.resolveConfirm(c, confirm: ok)),
          ]),
        ),
      ),
    );

void main() {
  test('a needs_confirmation result becomes a card; nothing runs until the tap', () async {
    final h = Harness();
    await h.chat.send('Save 44.21,-114.93 as Elk camp');
    final c = h.chat.messages[1].confirms.single;
    expect(c.confirmId, 'c1');
    expect(c.toolCallId, 'call_1');
    expect(c.title, 'Save a place');
    expect(c.summary.map((e) => '${e.key}=${e.value}'), ['name=Elk camp', 'place=44.21000, -114.93000 (12 mi NE of Stanley)']);
    expect(c.state, ConfirmState.open);
    expect(h.runs, isEmpty);
  });

  testWidgets('confirm runs the action once, appends the outcome as a system host event and gets a follow-up', (tester) async {
    final h = Harness();
    await tester.runAsync(() => h.ask('Save 44.21,-114.93 as Elk camp'));
    await tester.pumpWidget(_cards(h.chat));
    expect(find.text('Name: Elk camp'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save a place'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-run-c1')));
    await tester.tap(find.byKey(const ValueKey('confirm-run-c1')), warnIfMissed: false);
    // The card's resolution was made outside the fake clock (runAsync), so let real time run too.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    expect(h.runs, [
      {'name': 'Elk camp', 'place': {'lat': 44.21, 'lon': -114.93}},
    ]);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-run-c1')), findsNothing);
    expect(h.backend.requests, hasLength(3));
    final sent = (h.backend.requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(sent[sent.length - 2]['role'], 'assistant'); // the model's text reply comes between the call and the outcome
    expect(sent.last['role'], 'system');
    expect(sent.last.keys, ['role', 'content']);
    // The whole content is exactly one JSON object, host_event first.
    expect(sent.last['content'],
        '{"host_event":"act_outcome","ok":true,"status":"done","confirm_id":"c1","action":"places.save","result":{"name":"Elk camp"}}');
    expect(h.chat.messages.last.text, 'Elk camp is saved.');
  });

  testWidgets('cancel declines without running', (tester) async {
    final h = Harness();
    await tester.runAsync(() => h.ask('Save 44.21,-114.93 as Elk camp'));
    await tester.pumpWidget(_cards(h.chat));
    await tester.tap(find.byKey(const ValueKey('confirm-cancel-c1')));
    await tester.tap(find.byKey(const ValueKey('confirm-cancel-c1')), warnIfMissed: false);
    // The card's resolution was made outside the fake clock (runAsync), so let real time run too.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(h.runs, isEmpty);
    expect(find.text('Cancelled'), findsOneWidget);
    final sent = (h.backend.requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(sent.last['role'], 'system');
    expect(sent.last['content'], '{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}');
    expect(h.backend.requests, hasLength(3));
  });

  testWidgets('a failed run shows why and tells the model', (tester) async {
    final h = Harness(fail: true);
    await tester.runAsync(() => h.ask('Save 44.21,-114.93 as Elk camp'));
    await tester.pumpWidget(_cards(h.chat));
    await tester.tap(find.byKey(const ValueKey('confirm-run-c1')));
    // The card's resolution was made outside the fake clock (runAsync), so let real time run too.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('Could not do it. No room for more places.'), findsOneWidget);
    final sent = (h.backend.requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(jsonDecode(sent.last['content'] as String), {
      'host_event': 'act_outcome',
      'ok': false,
      'status': 'failed',
      'confirm_id': 'c1',
      'action': 'places.save',
      'error': {'type': 'full', 'detail': 'No room for more places.'},
    });
  });

  test('the card is resolved when it is shown, and the tap runs those values', () async {
    final core = RecordingActCore();
    final h = Harness(core: core);
    await h.ask('Save 44.21,-114.93 as Elk camp');
    expect(core.calls, ['places.save']);
    expect(h.runs, isEmpty);
    core.answer = {'ok': false, 'error': {'type': 'place_not_found', 'detail': 'changed', 'field': 'place'}};
    await h.chat.resolveConfirm(h.chat.messages[1].confirms.single, confirm: true);
    expect(core.calls, ['places.save']);
    expect(h.runs, [
      {'name': 'Elk camp', 'place': {'lat': 44.21, 'lon': -114.93, 'name': 'Elk camp', 'label': '12 mi NE of Stanley'}},
    ]);
  });

  test('a card whose fields no longer resolve fails without running', () async {
    final core = RecordingActCore()
      ..answer = {
        'ok': false,
        'error': {'type': 'place_not_found', 'detail': 'No place found for "Elk camp".', 'field': 'place', 'query': 'Elk camp'},
      };
    final h = Harness(core: core);
    await h.ask('Save Elk camp');
    final card = h.chat.messages[1].confirms.single;
    await h.chat.resolveConfirm(card, confirm: true);
    expect(h.runs, isEmpty);
    expect(card.state, ConfirmState.failed);
    expect(card.error, 'No place found for "Elk camp".');
    final sent = (h.backend.requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(jsonDecode(sent.last['content'] as String)['error'],
        {'type': 'place_not_found', 'detail': 'No place found for "Elk camp".', 'field': 'place', 'query': 'Elk camp'});
  });

  test('typed words do not confirm: the card stays open', () async {
    final h = Harness();
    await h.chat.send('Save 44.21,-114.93 as Elk camp');
    await h.chat.send('yes do it');
    expect(h.chat.messages[1].confirms.single.state, ConfirmState.open);
    expect(h.runs, isEmpty);
  });

  test('the tool message form sends the same JSON as the act tool result', () async {
    final h = Harness(form: ActOutcomeForm.toolMessage);
    await h.chat.send('Save 44.21,-114.93 as Elk camp');
    await h.chat.resolveConfirm(h.chat.messages[1].confirms.single, confirm: true);
    final sent = (h.backend.requests.last['messages'] as List).cast<Map<String, dynamic>>();
    expect(sent.last['role'], 'tool');
    expect(sent.last['tool_call_id'], 'call_1');
    expect(jsonDecode(sent.last['content'] as String), {'ok': true, 'status': 'done', 'confirm_id': 'c1', 'action': 'places.save', 'result': {'name': 'Elk camp'}});
    final reopened = ChatController(tools: [FakeAct()], actions: h.registry)
      ..attachStore(h.store)
      ..openConversation(h.chat.activeId!);
    expect(reopened.messages[1].confirms.single.state, ConfirmState.done);
  });

  test('a saved chat keeps the act call and result, and shows a resolved card as its outcome', () async {
    final h = Harness();
    await h.chat.send('Save 44.21,-114.93 as Elk camp');
    await h.chat.resolveConfirm(h.chat.messages[1].confirms.single, confirm: true);
    final id = h.chat.activeId!;
    final transcript = h.store.transcript(id);
    expect([for (final m in transcript) m['role']], ['user', 'assistant', 'tool', 'assistant', 'system', 'assistant']);
    expect(jsonDecode(transcript[2]['content'] as String)['status'], 'needs_confirmation');
    expect(jsonDecode(transcript[4]['content'] as String)['status'], 'done');

    final reopened = ChatController(tools: [FakeAct()], actions: h.registry)..attachStore(h.store);
    reopened.openConversation(id);
    expect([for (final m in reopened.messages) m.text], [
      'Save 44.21,-114.93 as Elk camp',
      'I put up a card to save Elk camp. Nothing is saved until you tap Save a place.',
      'Elk camp is saved.',
    ]);
    final card = reopened.messages[1].confirms.single;
    expect(card.state, ConfirmState.done);
    expect(reopened.messages[2].confirms, isEmpty);
  });

  test('a card still open when the chat is closed is dropped and cannot run', () async {
    final h = Harness();
    await h.chat.send('Save 44.21,-114.93 as Elk camp');
    final id = h.chat.activeId!;
    final reopened = ChatController(tools: [FakeAct()], actions: h.registry)
      ..attachStore(h.store)
      ..setBackend(h.backend)
      ..openConversation(id);
    final card = reopened.messages[1].confirms.single;
    expect(card.state, ConfirmState.dropped);
    await reopened.resolveConfirm(card, confirm: true);
    expect(h.runs, isEmpty);
  });

  test('cardsInTranscript reads a host event outcome', () {
    final cards = cardsInTranscript([
      {'role': 'user', 'content': 'x'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {'id': 'a', 'type': 'function', 'function': {'name': 'act', 'arguments': '{"action":"places.save","fields":{"name":"N"}}'}},
        ],
      },
      {'role': 'tool', 'tool_call_id': 'a', 'content': '{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"places.save","title":"Save a place","summary":{"name":"N"}}'},
      {'role': 'assistant', 'content': 'Tap the card.'},
      {'role': 'system', 'content': '{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}'},
    ]);
    expect(cards.keys, [2]);
    expect(cards[2]!.state, ConfirmState.declined);
    expect(cards[2]!.fields, {'name': 'N'});
  });

  test('field names read as labels', () {
    expect(fieldLabel('route_id'), 'Route id');
    expect(fieldLabel('place'), 'Place');
  });
}
