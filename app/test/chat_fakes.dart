import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/history/titles.dart';
import 'package:cache/search/numbering_state.dart';
import 'package:cache_llama/cache_llama.dart';

/// A model that answers from a script, writes [title] when asked for one, and records every request.
class ScriptedBackend implements ModelBackend {
  ScriptedBackend(this.script, {this.title = 'Treating burns'});

  final List<PartialMessage Function(Map<String, dynamic> request)> script;
  final String title;
  final List<Map<String, dynamic>> requests = [];
  final List<Map<String, dynamic>> titleRequests = [];
  int stops = 0;
  int _answers = 0;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) async* {
    final messages = request['messages'] as List;
    if ((messages.last as Map)['content'] == kTitlePrompt) {
      titleRequests.add(request);
      yield PartialMessage(isFinal: true, content: title);
      return;
    }
    requests.add(request);
    final i = _answers++;
    yield script[i < script.length ? i : script.length - 1](request);
  }

  @override
  void stop() => stops++;
}

PartialMessage callSearch(String query, {String id = 'c1'}) => PartialMessage(
      isFinal: true,
      toolCalls: [ToolCall(id: id, name: 'search', arguments: '{"query":"$query"}')],
    );

PartialMessage say(String text) => PartialMessage(isFinal: true, content: text, promptTokens: 120, generatedTokens: 30);

/// A search tool that returns the next batch of results each time it is called.
class BatchSearch extends Tool {
  BatchSearch(this.batches);

  final List<List<SourceResult>> batches;
  int calls = 0;

  @override
  String get name => 'search';
  @override
  String get description => 'search';
  @override
  Map<String, dynamic> get parameters => {'type': 'object'};
  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async => batches[calls++ < batches.length ? calls - 1 : batches.length - 1];
}

SourceResult hit(String title, String snippet, {String? address}) =>
    SourceResult(title: title, snippet: snippet, address: address ?? 'zim:$title');

/// Test-only numbering that saves its state as the core's format 1 JSON and numbers like cs_format, so the chat
/// controller's save and restore can be tested without the native core.
class MemoryNumberingState implements NumberingState {
  const MemoryNumberingState();

  @override
  Future<Uint8List?> save(ResultNumbering numbering) async {
    final ids = [...await numbering.ids()]..sort((a, b) => a.n.compareTo(b.n));
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 1,
      'next_n': ids.isEmpty ? 1 : ids.last.n + 1,
      'ids': [for (final i in ids) {'n': i.n, 'address': i.address, 'title': i.title}],
    })));
  }

  @override
  Future<ResultNumbering?> restore(Uint8List state) async {
    try {
      final j = jsonDecode(utf8.decode(state)) as Map<String, dynamic>;
      if (j['format'] != 1) return null;
      final ids = [...(j['ids'] as List).cast<Map<String, dynamic>>()]..sort((a, b) => (a['n'] as int).compareTo(b['n'] as int));
      return MemoryNumbering([for (final e in ids) (address: e['address'] as String, title: (e['title'] ?? '') as String)]);
    } catch (_) {
      return null;
    }
  }
}

class MemoryNumbering implements ResultNumbering {
  MemoryNumbering(List<({String address, String title})> entries) {
    for (final e in entries) {
      _byAddress[e.address] = _entries.length;
      _entries.add(e);
    }
  }

  final List<({String address, String title})> _entries = [];
  final Map<String, int> _byAddress = {};

  String _oneLine(String s) => s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

  @override
  Future<String> format(List<SourceResult> results) async {
    if (results.isEmpty) return 'No results found.';
    final seen = <int>{};
    final lines = <String>[];
    for (final r in results) {
      final idx = _byAddress.putIfAbsent(r.address, () {
        _entries.add((address: r.address, title: r.title));
        return _entries.length - 1;
      });
      if (!seen.add(idx)) continue;
      final title = _oneLine(r.title), snippet = _oneLine(r.snippet);
      lines.add(snippet.isEmpty ? '[${idx + 1}] $title' : '[${idx + 1}] $title — $snippet');
    }
    return lines.join('\n');
  }

  @override
  Future<List<NumberedAddress>> ids() async => [
        for (var i = 0; i < _entries.length; i++) NumberedAddress(n: i + 1, address: _entries[i].address, title: _entries[i].title),
      ];

  @override
  Future<void> dispose() async {}
}
