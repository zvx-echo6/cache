import 'package:cache/chat/citations.dart';
import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers each generate() call from a script and records the requests it got.
class FakeBackend implements ModelBackend {
  FakeBackend(this.script);

  final List<PartialMessage Function(Map<String, dynamic> request)> script;
  final List<Map<String, dynamic>> requests = [];
  int stops = 0;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    requests.add(request);
    final i = requests.length - 1;
    final msg = script[i < script.length ? i : script.length - 1](request);
    yield PartialMessage(content: msg.content.isEmpty ? '' : msg.content.substring(0, msg.content.length ~/ 2));
    yield msg;
  }

  @override
  void stop() => stops++;
}

PartialMessage toolCall(String query, {String id = 'c1'}) => PartialMessage(
      isFinal: true,
      toolCalls: [ToolCall(id: id, name: 'search', arguments: '{"query":"$query"}')],
    );

PartialMessage answer(String text) => PartialMessage(isFinal: true, content: text);

class FakeSearch extends Tool {
  FakeSearch(this.batches);

  final List<List<SourceResult>> batches;
  int calls = 0;

  @override
  String get name => 'search';
  @override
  String get description => 'search';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};
  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async =>
      batches[calls++ < batches.length ? calls - 1 : batches.length - 1];
}

SourceResult r(String t, String s) => SourceResult(title: t, snippet: s, address: 'local:$t');

void main() {
  group('citation check', () {
    test('keeps known markers, removes unknown ones', () {
      final c = checkCitations('Cool it [1]. Then see a doctor [2] or [7].', {1, 2});
      expect(c.text, 'Cool it [1]. Then see a doctor [2] or.');
      expect(c.kept, [1, 2]);
    });

    test('duplicates count once and kept is sorted', () {
      final c = checkCitations('A [2] B [1] C [2]', {1, 2});
      expect(c.kept, [1, 2]);
      expect(c.text, 'A [2] B [1] C [2]');
    });

    test('no markers or no valid ids', () {
      expect(checkCitations('Plain text.', {1}).kept, isEmpty);
      final c = checkCitations('Made up [3].', <int>{});
      expect(c.kept, isEmpty);
      expect(c.text, 'Made up.');
    });

    test('other brackets are left alone', () {
      final c = checkCitations('Use [a] and [] and [1x].', {1});
      expect(c.text, 'Use [a] and [] and [1x].');
    });
  });

  group('tool loop', () {
    test('numbers results conversation-wide and formats the tool message', () async {
      final search = FakeSearch([
        [r('WikiMed: Burn', 'Cool the burn.'), r('Manual p.142', 'Seek help.')],
        [r('Water', 'Boil it.')],
      ]);
      final backend = FakeBackend([
        (_) => toolCall('burn'),
        (_) => answer('Cool it [1], get help [2].'),
        (_) => toolCall('water'),
        (_) => answer('Boil [3]. Also [1]. Bogus [9].'),
      ]);
      final loop = ToolLoop(backend: backend, tools: [search]);

      final first = await loop.ask('burn?').toList();
      expect(first.last.phase, TurnPhase.done);
      expect(first.last.text, 'Cool it [1], get help [2].');
      expect([for (final c in first.last.cited) c.id], [1, 2]);

      // The second request carried the tool message in the agreed form.
      final toolMsg = (backend.requests[1]['messages'] as List).last as Map;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'c1');
      expect(toolMsg['content'], '[1] WikiMed: Burn — Cool the burn.\n[2] Manual p.142 — Seek help.');
      expect(backend.requests[0]['tools'], isNotNull);
      expect((backend.requests[0]['messages'] as List).first['role'], 'system');
      expect((backend.requests[0]['messages'] as List).first['content'], kSystemPrompt);

      // A later question continues the numbering and may cite earlier results.
      final second = await loop.ask('water?').toList();
      final toolMsg2 = (backend.requests[3]['messages'] as List).last as Map;
      expect(toolMsg2['content'], '[3] Water — Boil it.');
      expect(second.last.text, 'Boil [3]. Also [1]. Bogus.');
      expect([for (final c in second.last.cited) c.id], [1, 3]);
      expect(loop.results.keys, [1, 2, 3]);
    });

    test('empty search gives No results and no sources', () async {
      final backend = FakeBackend([(_) => toolCall('x'), (_) => answer('Not in your sources.')]);
      final loop = ToolLoop(backend: backend, tools: [FakeSearch([[]])]);
      final updates = await loop.ask('x?').toList();
      final toolMsg = (backend.requests[1]['messages'] as List).last as Map;
      expect(toolMsg['content'], 'No results.');
      expect(updates.last.cited, isEmpty);
      expect(updates.last.text, 'Not in your sources.');
    });

    test('at most 3 tool rounds, then tools are withheld', () async {
      final backend = FakeBackend([
        (_) => toolCall('a'),
        (_) => toolCall('b'),
        (_) => toolCall('c'),
        (_) => answer('Final [1].'),
      ]);
      final search = FakeSearch([[r('T', 'S')]]);
      final loop = ToolLoop(backend: backend, tools: [search]);
      final updates = await loop.ask('q').toList();
      expect(search.calls, 3);
      expect(backend.requests.length, 4);
      expect(backend.requests[2]['tools'], isNotNull);
      expect(backend.requests[3].containsKey('tools'), isFalse);
      expect(updates.last.text, 'Final [1].');
    });

    test('the cap is enforced at dispatch: a tool call after the cap is ignored and its text is the answer', () async {
      final backend = FakeBackend([
        (_) => toolCall('a'),
        (_) => toolCall('b'),
        (_) => toolCall('c'),
        (_) => PartialMessage(
              isFinal: true,
              content: 'Answer from what I have [1].',
              toolCalls: [ToolCall(id: 'c9', name: 'search', arguments: '{"query":"d"}')],
            ),
      ]);
      final search = FakeSearch([[r('T', 'S')]]);
      final loop = ToolLoop(backend: backend, tools: [search]);
      final updates = await loop.ask('q').toList();
      expect(search.calls, 3); // the fourth call was not run
      expect(backend.requests.length, 4);
      expect(updates.last.phase, TurnPhase.done);
      expect(updates.last.text, 'Answer from what I have [1].');
      expect([for (final m in loop.messages) m['role']], ['user', 'assistant', 'tool', 'assistant', 'tool', 'assistant', 'tool', 'assistant']);
      expect(loop.messages.last.containsKey('tool_calls'), isFalse);
    });

    test('after the cap, a tool call with no text gets one more request without tools', () async {
      final backend = FakeBackend([
        (_) => toolCall('a'),
        (_) => toolCall('b'),
        (_) => toolCall('c'),
        (_) => toolCall('d'),
        (_) => answer('Done [1].'),
      ]);
      final search = FakeSearch([[r('T', 'S')]]);
      final loop = ToolLoop(backend: backend, tools: [search]);
      final updates = await loop.ask('q').toList();
      expect(search.calls, 3);
      expect(backend.requests.length, 5);
      expect(backend.requests[3].containsKey('tools'), isFalse);
      expect(backend.requests[4].containsKey('tools'), isFalse);
      // The nudge is sent but not kept in the conversation.
      expect((backend.requests[4]['messages'] as List).last['role'], 'user');
      expect(loop.messages.where((m) => m['role'] == 'user').length, 1);
      expect(updates.last.text, 'Done [1].');
    });

    test('streams phases: thinking/searching/answering then done', () async {
      final backend = FakeBackend([(_) => toolCall('a'), (_) => answer('Hello there')]);
      final loop = ToolLoop(backend: backend, tools: [FakeSearch([[]])]);
      final phases = [for (final u in await loop.ask('q').toList()) u.phase];
      expect(phases.contains(TurnPhase.searching), isTrue);
      expect(phases.contains(TurnPhase.answering), isTrue);
      expect(phases.last, TurnPhase.done);
    });

    test('unknown tool name is reported to the model, not thrown', () async {
      final backend = FakeBackend([
        (_) => const PartialMessage(isFinal: true, toolCalls: [ToolCall(id: 'z', name: 'nope', arguments: '{}')]),
        (_) => answer('Ok'),
      ]);
      final loop = ToolLoop(backend: backend, tools: [FakeSearch([[]])]);
      final updates = await loop.ask('q').toList();
      final toolMsg = (backend.requests[1]['messages'] as List).last as Map;
      expect(toolMsg['content'], contains('no tool called nope'));
      expect(updates.last.error, isNull);
    });
  });
}
