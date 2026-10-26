import 'package:cache_llama/cache_llama.dart';

import 'chat_config.dart';
import 'citations.dart';
import 'model_backend.dart';
import 'tool.dart';

/// The plain prompt of the loop when no builder is given (tests). The app passes [buildSystemPrompt].
const String kSystemPrompt =
    'You are Cache, an offline survival and preparedness assistant. Use your tools to look things up '
    'before answering questions about facts or how to do things. Cite every fact you take from a tool '
    'result with its number in square brackets, like [1]. If your tools find nothing useful, say it is '
    "not in the user's sources.";

const int kMaxToolRounds = 3;

enum TurnPhase { thinking, searching, answering, done }

/// What the UI needs while an answer is being produced.
class TurnUpdate {
  const TurnUpdate({
    required this.phase,
    this.text = '',
    this.cited = const [],
    this.error,
    this.promptTokens = 0,
    this.generatedTokens = 0,
  });

  final TurnPhase phase;

  /// Visible answer text so far (no tool-call or thinking syntax; unknown citation markers removed).
  final String text;

  /// Only set when [phase] is done: the valid cited results.
  final List<NumberedResult> cited;
  final String? error;
  final int promptTokens;
  final int generatedTokens;
}

/// Runs one conversation: sends messages and tool schemas, runs the tools the model asks for (at most
/// [kMaxToolRounds] rounds per answer), numbers every result conversation-wide and continues until the
/// model answers.
class ToolLoop {
  ToolLoop({
    required this.backend,
    required List<Tool> tools,
    this.systemPrompt,
    this.enableThinking = kEnableThinking,
    this.numbering,
    this.host,
  })
      : _tools = {for (final t in tools) t.name: t};

  final ModelBackend backend;

  /// Builds the system prompt for each turn (local time and location change); null: [kSystemPrompt].
  final String Function()? systemPrompt;
  final bool enableThinking;
  final Map<String, Tool> _tools;

  /// Numbers the results in the search core. Null: the loop numbers them itself (tests).
  final ResultNumbering? numbering;

  /// The core's tools: when set, its schemas are offered and every call goes through cs_tool (which numbers the
  /// sources itself); [tools] and [numbering] are not used.
  final ToolHost? host;
  final List<Map<String, dynamic>> _messages = [];
  final Map<int, NumberedResult> _results = {};
  int _nextId = 1;
  bool _stopped = false;

  /// Every result returned in this conversation, by ID.
  Map<int, NumberedResult> get results => Map.unmodifiable(_results);

  /// The conversation so far (without the system prompt), OpenAI style.
  List<Map<String, dynamic>> get messages => List.unmodifiable(_messages);

  void stop() {
    _stopped = true;
    backend.stop();
  }

  /// Frees the numbering in the core. The loop is not used afterwards.
  Future<void> dispose() async {
    await numbering?.dispose();
    await host?.dispose();
  }

  String _clean(String s) => checkCitations(s, _results.keys.toSet()).text;

  Stream<TurnUpdate> ask(String userText) async* {
    _stopped = false;
    _messages.add({'role': 'user', 'content': userText});
    var rounds = 0;
    var promptTokens = 0, generatedTokens = 0;
    final prompt = systemPrompt?.call() ?? kSystemPrompt;
    try {
      final hostSchemas = host == null ? const <Map<String, dynamic>>[] : await host!.schemas();
      while (true) {
        final schemas = host == null ? [for (final t in _tools.values) t.toSchema()] : hostSchemas;
        final allowTools = rounds < kMaxToolRounds && schemas.isNotEmpty;
        final request = <String, dynamic>{
          'messages': [
            {'role': 'system', 'content': prompt},
            ..._messages,
          ],
          'enable_thinking': enableThinking,
          if (allowTools) 'tools': schemas,
        };

        PartialMessage? last;
        await for (final p in backend.generate(request)) {
          last = p;
          if (p.isFinal) break;
          if (p.hasToolCalls) {
            yield const TurnUpdate(phase: TurnPhase.searching);
          } else if (p.content.isNotEmpty) {
            yield TurnUpdate(phase: TurnPhase.answering, text: _clean(p.content));
          } else {
            yield const TurnUpdate(phase: TurnPhase.thinking);
          }
        }
        if (last == null || !last.isFinal) {
          throw StateError('The model stopped without an answer');
        }
        promptTokens += last.promptTokens;
        generatedTokens += last.generatedTokens;

        if (last.hasToolCalls && !_stopped) {
          _messages.add(last.toMessage());
          yield const TurnUpdate(phase: TurnPhase.searching);
          for (final call in last.toolCalls) {
            _messages.add({'role': 'tool', 'tool_call_id': call.id, 'content': await _runCall(call)});
          }
          rounds++;
          continue;
        }

        final check = checkCitations(last.content, _results.keys.toSet());
        _messages.add({'role': 'assistant', 'content': last.content});
        yield TurnUpdate(
          phase: TurnPhase.done,
          text: check.text.trim(),
          cited: [for (final n in check.kept) _results[n]!],
          promptTokens: promptTokens,
          generatedTokens: generatedTokens,
        );
        return;
      }
    } catch (e) {
      yield TurnUpdate(phase: TurnPhase.done, error: e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  /// Runs one tool call and returns the tool message content: `[n] title — snippet`, one per line.
  Future<String> _runCall(ToolCall call) async {
    final host = this.host;
    if (host != null) {
      try {
        final r = await host.call(call.name, call.argumentsMap, DateTime.now());
        for (final id in r.ids) {
          _results.putIfAbsent(id.n, () => NumberedResult(id.n, SourceResult(title: id.title, snippet: '', address: id.address)));
        }
        return r.content;
      } catch (e) {
        return 'Error: the tool failed ($e).';
      }
    }
    final tool = _tools[call.name];
    if (tool == null) return 'Error: there is no tool called ${call.name}.';
    try {
      if (tool is TextTool) return await tool.runText(call.argumentsMap, (n) => _results[n]);
      final found = await tool.run(call.argumentsMap);
      if (found.isEmpty) return 'No results.';
      final numbering = this.numbering;
      if (numbering != null) {
        final message = await numbering.format(found);
        await _syncIds(numbering, found);
        return message;
      }
      final lines = <String>[];
      for (final r in found) {
        final n = NumberedResult(_nextId++, r);
        _results[n.id] = n;
        lines.add('[${n.id}] ${r.title} — ${r.snippet}');
      }
      return lines.join('\n');
    } catch (e) {
      return 'Error: the tool failed ($e).';
    }
  }

  /// Takes the id map from the core (cs_conversation_ids), the source of truth for the citation check.
  Future<void> _syncIds(ResultNumbering numbering, List<SourceResult> found) async {
    final snippets = {for (final r in found) r.address: r.snippet};
    for (final id in await numbering.ids()) {
      _results.putIfAbsent(
        id.n,
        () => NumberedResult(id.n, SourceResult(title: id.title, snippet: snippets[id.address] ?? '', address: id.address)),
      );
    }
  }
}
