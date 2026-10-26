import 'package:cache_llama/cache_llama.dart';

import 'chat_config.dart';
import 'citations.dart';
import 'model_backend.dart';
import 'tool.dart';

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
    this.systemPrompt = kSystemPrompt,
    this.enableThinking = kEnableThinking,
    this.numbering,
    List<Map<String, dynamic>> history = const [],
    Iterable<NumberedResult> knownResults = const [],
  })
      : _tools = {for (final t in tools) t.name: t} {
    // A conversation reopened from storage: its transcript and the results already numbered in it.
    _messages.addAll(history);
    for (final r in knownResults) {
      _results[r.id] = r;
    }
    _nextId = _results.keys.fold(0, (a, b) => b > a ? b : a) + 1;
  }

  final ModelBackend backend;
  final String systemPrompt;
  final bool enableThinking;
  final Map<String, Tool> _tools;

  /// Numbers the results in the search core. Null: the loop numbers them itself (tests).
  final ResultNumbering? numbering;
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

  /// Takes the numbers already given from [numbering] (a restored conversation), so the citation check
  /// knows them.
  Future<void> syncNumbering() async {
    final n = numbering;
    if (n != null) await _syncIds(n, const []);
  }

  /// A request for the model made of this conversation plus [extra] (one more message that is not kept in
  /// it), for side questions such as a title. With [withTools] the request carries the same tool
  /// definitions as a normal turn, so the model's cached prompt start stays valid.
  Map<String, dynamic> requestWith(Map<String, dynamic> extra, {bool withTools = false}) =>
      _request([..._messages, extra], withTools && _tools.isNotEmpty);

  Map<String, dynamic> _request(List<Map<String, dynamic>> messages, bool withTools) => {
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          ...messages,
        ],
        'enable_thinking': enableThinking,
        if (withTools) 'tools': [for (final t in _tools.values) t.toSchema()],
      };

  /// Frees the numbering in the core. The loop is not used afterwards.
  Future<void> dispose() async => numbering?.dispose();

  String _clean(String s) => checkCitations(s, _results.keys.toSet()).text;

  Stream<TurnUpdate> ask(String userText) async* {
    _stopped = false;
    _messages.add({'role': 'user', 'content': userText});
    var rounds = 0;
    var promptTokens = 0, generatedTokens = 0;
    try {
      while (true) {
        final allowTools = rounds < kMaxToolRounds && _tools.isNotEmpty;
        final request = _request(_messages, allowTools);

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
