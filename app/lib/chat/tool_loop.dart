import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../actions/confirm.dart';

import 'chat_config.dart';
import 'citations.dart';
import 'model_backend.dart';
import 'navigation_action.dart';
import 'tool.dart';

/// The plain prompt of the loop when no builder is given (tests). The app passes [buildSystemPrompt].
const String kSystemPrompt =
    'You are Cache, an offline survival and preparedness assistant. Use your tools to look things up '
    'before answering questions about facts or how to do things. Cite every fact you take from a tool '
    'result with its number in square brackets, like [1]. If your tools find nothing useful, say it is '
    "not in the user's sources.";

const int kMaxToolRounds = 3;

/// Sent (not kept in the conversation) when the model asked for more tools after the cap and said nothing.
const Map<String, dynamic> _kAnswerNow = {
  'role': 'user',
  'content': 'Answer now from the tool results above. No more tools are available.',
};

enum TurnPhase {
  /// The search core is still starting; the question waits for it (it is never answered without the core's tools).
  starting,
  thinking,
  searching,
  answering,
  done,
}

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
    for (final m in history) {
      for (final c in m['tool_calls'] is List ? m['tool_calls'] as List : const []) {
        final n = c is Map ? _callNumber.firstMatch('${c['id']}') : null;
        final k = n == null ? 0 : int.parse(n.group(1)!);
        if (k >= _nextCall) _nextCall = k + 1;
      }
    }
  }

  static final _callNumber = RegExp(r'^call_(\d+)$');

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

  /// Synchronous app sideband, saved before the next model request.
  void Function(List<NavigationAction>)? onNavigationActions;

  /// Synchronous app sideband: the confirm cards an `act` call asked for (change actions).
  void Function(List<ConfirmCard>)? onConfirmations;
  final List<Map<String, dynamic>> _messages = [];
  final Map<int, NumberedResult> _results = {};
  int _nextId = 1;

  /// Tool-call ids are one sequence per conversation, call_1, call_2, ... in the order the calls are made, across turns, as in the
  /// training captures (the model's parser numbers each message from call_0, so the loop gives the ids).
  int _nextCall = 1;
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
      _request(_messages, withTools && _schemas.isNotEmpty, prompt: _prompt, extra: extra);

  /// The system prompt and tool schemas of the last turn are reused, so a side question keeps the model's cached
  /// prompt start.
  String? _lastPrompt;
  String get _prompt => _lastPrompt ?? (systemPrompt?.call() ?? kSystemPrompt);
  List<Map<String, dynamic>> _hostSchemas = const [];

  List<Map<String, dynamic>> get _schemas => host == null ? [for (final t in _tools.values) t.toSchema()] : _hostSchemas;

  Map<String, dynamic> _request(List<Map<String, dynamic>> messages, bool withTools, {required String prompt, Map<String, dynamic>? extra}) => {
        'messages': [
          {'role': 'system', 'content': prompt},
          ...messages,
          ?extra,
        ],
        'enable_thinking': enableThinking,
        if (withTools) 'tools': _schemas,
      };

  /// Frees the numbering in the core. The loop is not used afterwards.
  Future<void> dispose() async {
    await numbering?.dispose();
    await host?.dispose();
  }

  String _clean(String s) => checkCitations(s, _results.keys.toSet()).text;

  /// Asks [userText]. With [seed], the turn starts with that tool call (its arguments as JSON text) and its real result, as if the
  /// model had made it (Ask about this); the seed is not one of the turn's tool rounds.
  Stream<TurnUpdate> ask(String userText, {({String name, String arguments})? seed}) {
    _messages.add({'role': 'user', 'content': userText});
    return _turn(seed: seed);
  }

  ToolCall _numbered(String name, String arguments) => ToolCall(id: 'call_${_nextCall++}', name: name, arguments: arguments);

  /// Adds a message the host writes (the outcome of a confirm card) to the conversation.
  void addMessage(Map<String, dynamic> message) => _messages.add(message);

  /// Lets the model answer the conversation as it stands (its short follow-up after [addMessage]), as after a question.
  Stream<TurnUpdate> resume() => _turn();

  Stream<TurnUpdate> _turn({({String name, String arguments})? seed}) async* {
    _stopped = false;
    var rounds = 0;
    var promptTokens = 0, generatedTokens = 0;
    final prompt = _lastPrompt = systemPrompt?.call() ?? kSystemPrompt;
    var finalAnswer = false;
    try {
      if (host != null) {
        _hostSchemas = await host!.schemas();
        debugPrint('cache tools offered: ${[for (final t in _hostSchemas) (t['function'] as Map?)?['name']]}');
      }
      if (seed != null) {
        yield const TurnUpdate(phase: TurnPhase.searching);
        final call = _numbered(seed.name, seed.arguments);
        _messages.add({'role': 'assistant', 'content': null, 'tool_calls': [call.toJson()]});
        await _addResult(call);
      }
      while (true) {
        final allowTools = rounds < kMaxToolRounds && _schemas.isNotEmpty && !finalAnswer;
        final request = _request(_messages, allowTools, prompt: prompt, extra: finalAnswer ? _kAnswerNow : null);

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

        // The cap is enforced here, not only by leaving the schemas out: once kMaxToolRounds rounds have run, a tool
        // call the model returns anyway is ignored. Its text, if any, is the answer; with none, one more request
        // goes out without tools to get one.
        if (last.hasToolCalls && !_stopped && rounds >= kMaxToolRounds) {
          if (last.content.trim().isEmpty && !finalAnswer) {
            finalAnswer = true;
            continue;
          }
        } else if (last.hasToolCalls && !_stopped) {
          final calls = [for (final c in last.toolCalls) _numbered(c.name, c.arguments)];
          _messages.add({...last.toMessage(), 'tool_calls': [for (final c in calls) c.toJson()]});
          yield const TurnUpdate(phase: TurnPhase.searching);
          for (final call in calls) {
            await _addResult(call);
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

  /// Runs [call] and adds its tool message; an `act` call that needs a tap shows its confirm card.
  Future<void> _addResult(ToolCall call) async {
    final content = await _runCall(call);
    _messages.add({'role': 'tool', 'tool_call_id': call.id, 'content': content});
    if (call.name == 'act') {
      final card = ConfirmCard.fromResult(call.id, call.argumentsMap, content);
      if (card != null) onConfirmations?.call([card]);
    }
  }

  /// Runs one tool call and returns the tool message content: `[n] title — snippet`, one per line.
  Future<String> _runCall(ToolCall call) async {
    final host = this.host;
    if (host != null) {
      try {
        final r = await host.call(call.name, call.argumentsMap, DateTime.now());
        // One line per call for logcat (no arguments or text): which tool ran and which [n] it gave.
        debugPrint('cache tool ${call.name}: new ids ${[for (final i in r.ids) i.n]}, ${r.content.length} chars');
        for (final id in r.ids) {
          _results.putIfAbsent(id.n, () => NumberedResult(id.n, SourceResult(title: id.title, snippet: '', address: id.address)));
        }
        if (r.navigationActions.isNotEmpty) onNavigationActions?.call(r.navigationActions);
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
