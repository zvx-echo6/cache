import 'package:cache/chat/model_backend.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/history/titles.dart';
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
