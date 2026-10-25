import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/read_tool.dart';
import 'package:cache/chat/search_tool.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache/search/search_access.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

/// Numbers like the core does: continues across calls and an address seen before keeps its number.
class FakeCoreNumbering implements ResultNumbering {
  final List<NumberedAddress> _ids = [];
  int formatCalls = 0, idsCalls = 0;
  bool disposed = false;

  @override
  Future<String> format(List<SourceResult> results) async {
    formatCalls++;
    final lines = <String>[];
    for (final r in results) {
      var id = _ids.where((i) => i.address == r.address).firstOrNull;
      if (id == null) {
        id = NumberedAddress(n: _ids.length + 1, address: r.address, title: r.title);
        _ids.add(id);
      }
      lines.add('[${id.n}] ${r.title} — ${r.snippet}');
    }
    return lines.join('\n');
  }

  @override
  Future<List<NumberedAddress>> ids() async {
    idsCalls++;
    return List.of(_ids);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeSearch implements SearchAccess {
  final List<String> queries = [];
  final List<String> reads = [];

  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async {
    queries.add(query);
    return const [
      SourceResult(title: 'WikiMed: Burn', snippet: 'Cool the burn.', address: 'zim:u/Burn'),
      SourceResult(title: 'WikiMed: Scald', snippet: 'Run water.', address: 'zim:u/Scald'),
    ];
  }

  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) async {
    reads.add(address);
    return const ReadPage(title: 'WikiMed: Burn', text: 'Full text.', truncated: true);
  }
}

class Scripted implements ModelBackend {
  Scripted(this.script);

  final List<PartialMessage> script;
  final List<Map<String, dynamic>> requests = [];

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    requests.add(request);
    yield script[requests.length - 1];
  }

  @override
  void stop() {}
}

PartialMessage call(String name, String args, {String id = 'c'}) =>
    PartialMessage(isFinal: true, toolCalls: [ToolCall(id: id, name: name, arguments: args)]);

void main() {
  test('the loop takes the tool message and the ids from the core numbering', () async {
    final search = FakeSearch();
    final numbering = FakeCoreNumbering();
    final backend = Scripted([
      call('search', '{"query":"burn"}'),
      const PartialMessage(isFinal: true, content: 'Cool it [1]. Not this [5].'),
    ]);
    final loop = ToolLoop(backend: backend, tools: [SearchTool(search), ReadTool(search)], numbering: numbering);
    final updates = await loop.ask('burn?').toList();

    expect(search.queries, ['burn']);
    final toolMsg = (backend.requests[1]['messages'] as List).last as Map;
    expect(toolMsg['content'], '[1] WikiMed: Burn — Cool the burn.\n[2] WikiMed: Scald — Run water.');
    expect(numbering.idsCalls, 1);
    expect(updates.last.text, 'Cool it [1]. Not this.');
    expect([for (final c in updates.last.cited) c.id], [1]);
    expect(updates.last.cited.single.result.snippet, 'Cool the burn.');
    expect(updates.last.cited.single.result.address, 'zim:u/Burn');
    await loop.dispose();
    expect(numbering.disposed, isTrue);
  });

  test('both tools are offered with their schemas', () async {
    final search = FakeSearch();
    final backend = Scripted([const PartialMessage(isFinal: true, content: 'Hi')]);
    final loop = ToolLoop(backend: backend, tools: [SearchTool(search), ReadTool(search)]);
    await loop.ask('hi').toList();
    final tools = backend.requests.first['tools'] as List;
    expect([for (final t in tools) t['function']['name']], ['search', 'read']);
    expect(tools[1]['function']['parameters']['required'], ['n']);
  });

  test('read opens a numbered result by its number and reports truncation', () async {
    final search = FakeSearch();
    final backend = Scripted([
      call('search', '{"query":"burn"}', id: 'a'),
      call('read', '{"n":2}', id: 'b'),
      const PartialMessage(isFinal: true, content: 'Run water [2].'),
    ]);
    final loop = ToolLoop(backend: backend, tools: [SearchTool(search), ReadTool(search)], numbering: FakeCoreNumbering());
    final updates = await loop.ask('scald?').toList();
    expect(search.reads, ['zim:u/Scald']);
    final readMsg = (backend.requests[2]['messages'] as List).last as Map;
    expect(readMsg['content'], '[2] WikiMed: Burn\nFull text.\n[truncated]');
    expect([for (final c in updates.last.cited) c.id], [2]);
  });

  test('read of a number that was never shown gives the not_found error', () async {
    final search = FakeSearch();
    final backend = Scripted([call('read', '{"n":9}'), const PartialMessage(isFinal: true, content: 'Sorry.')]);
    final loop = ToolLoop(backend: backend, tools: [ReadTool(search)], numbering: FakeCoreNumbering());
    await loop.ask('x').toList();
    final msg = (backend.requests[1]['messages'] as List).last as Map;
    expect(msg['content'], contains('"not_found"'));
    expect(msg['content'], contains('no result [9] in this conversation'));
    expect(search.reads, isEmpty);
  });

  test('a search that fails is reported to the model', () async {
    final backend = Scripted([call('search', '{"query":""}'), const PartialMessage(isFinal: true, content: 'Ok')]);
    final loop = ToolLoop(backend: backend, tools: [SearchTool(FakeSearch())]);
    final updates = await loop.ask('x').toList();
    final msg = (backend.requests[1]['messages'] as List).last as Map;
    expect(msg['content'], startsWith('Error: the tool failed'));
    expect(updates.last.error, isNull);
  });
}
