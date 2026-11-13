import 'dart:convert';

import 'package:cache_llama/cache_llama.dart';

import '../actions/confirm.dart';

import 'chat_config.dart';
import 'citations.dart';
import 'model_backend.dart';
import 'progress_steps.dart';
import 'navigation_action.dart';
import 'system_prompt.dart';
import 'tool.dart';
import 'tool_call_text.dart';
import '../platform/app_log.dart';
import '../platform/ask_diagnostics.dart';

/// The plain prompt of the loop when no builder is given (tests). The app passes [buildSystemPrompt].
const String kSystemPrompt =
    'You are Cache, an offline survival and preparedness assistant. Use your tools to look things up '
    'before answering questions about facts or how to do things. Cite every fact you take from a tool '
    'result with its number in square brackets, like [1]. If your tools find nothing useful, say it is '
    "not in the user's sources.";

const int kMaxToolRounds = 3;

/// Sent (not kept in the conversation) with every request after the cap: the tool schemas stay in the request (so the
/// prompt start the engine keeps is not read again), but `tool_choice` "none" stops the model from calling them.
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
    this.activeTool,
    this.step,
    this.finishedStep,
    this.completedToolText,
    this.promptTokens = 0,
    this.generatedTokens = 0,
    this.chatFull = false,
    this.cutShort = false,
  });

  final TurnPhase phase;

  /// Visible answer text so far (no tool-call or thinking syntax; unknown citation markers removed).
  final String text;

  /// Only set when [phase] is done: the valid cited results.
  final List<NumberedResult> cited;
  final String? error;

  /// Machine tool name for the current progress label; never sent to the model.
  final String? activeTool;

  /// The tool call that runs now, with its own arguments, for the progress line; never sent to the model.
  final ToolStep? step;

  /// A tool call that just finished, for the trail of steps above the progress line; never sent to the model.
  final ToolStep? finishedStep;

  /// A completed tool round's commentary, retained in the visible work flow.
  final String? completedToolText;
  final int promptTokens;
  final int generatedTokens;

  /// Only with [phase] done: the next request did not fit the context, so there is no answer and the chat is full.
  final bool chatFull;

  /// Only with [phase] done: the answer ended because the context filled up, so it is cut off.
  final bool cutShort;
}

/// Runs one conversation: sends messages and tool schemas, runs the tools the model asks for (at most
/// [kMaxToolRounds] rounds per answer), numbers every result conversation-wide and continues until the
/// model answers.
class ToolLoop {
  ToolLoop({
    required this.backend,
    required List<Tool> tools,
    this.systemPrompt,
    this.timeLine,
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

  /// Builds the local time line of a new question, put at the start of its user message ([withTimeLine]); null: the question
  /// goes alone.
  final String Function()? timeLine;
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

  /// Reads the core's tool schemas for the next request (a turn does it first, and so does [warmRequest]).
  Future<void> _loadSchemas() async {
    if (host == null) return;
    _hostSchemas = await host!.schemas();
    logDetail('Ask tools offered: ${[for (final t in _hostSchemas) (t['function'] as Map?)?['name']]}');
  }

  /// The request of the prompt read ahead: the request of a conversation's first model round (the same [_request] a turn builds,
  /// with the system prompt and the tool schemas as a turn reads them now), with no messages after the system prompt. The engine
  /// reads the part of the prompt the template renders before any question (the system prompt and the tools) from it, so this is the
  /// only way the read ahead builds a request, and a change to a turn's request reaches it.
  Future<Map<String, dynamic>> warmRequest() async {
    await _loadSchemas();
    return _request(const [], _schemas.isNotEmpty, prompt: systemPrompt?.call() ?? kSystemPrompt);
  }

  /// [noToolCalls]: the tools stay in the request, so the rendered prompt start is the same as in the rounds before, but the
  /// model may not call them (`tool_choice` "none": no tool-call grammar, and the engine stops at a tool-call opening).
  Map<String, dynamic> _request(List<Map<String, dynamic>> messages, bool withTools,
          {required String prompt, Map<String, dynamic>? extra, bool noToolCalls = false}) =>
      {
        'messages': [
          {'role': 'system', 'content': prompt},
          ...messages,
          ?extra,
        ],
        'enable_thinking': enableThinking,
        'max_tokens': kMaxTokens,
        if (withTools) 'tools': _schemas,
        if (withTools && noToolCalls) 'tool_choice': 'none',
      };

  /// Frees the numbering in the core. The loop is not used afterwards.
  Future<void> dispose() async {
    await numbering?.dispose();
    await host?.dispose();
  }

  String _clean(String s) => checkCitations(stripToolCalls(s), _results.keys.toSet()).text;

  /// The user message for [userText] as the model reads it: the question's time line ([timeLine]) first, then the question.
  /// The conversation keeps this message as it is, so later turns render it the same way.
  Map<String, dynamic> userMessage(String userText) {
    final line = timeLine?.call();
    return {'role': 'user', 'content': line == null ? userText : withTimeLine(line, userText)};
  }

  /// Asks [userText] ([message]: its user message from [userMessage], when the caller stored it already). With [seed], the turn
  /// starts with that tool call (its arguments as JSON text) and its real result, as if the model had made it (Ask about this);
  /// the seed is not one of the turn's tool rounds.
  Stream<TurnUpdate> ask(String userText, {({String name, String arguments})? seed, Map<String, dynamic>? message}) {
    _messages.add(message ?? userMessage(userText));
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
    var modelRequests = 0;
    var promptTokens = 0, generatedTokens = 0;
    final prompt = _lastPrompt = systemPrompt?.call() ?? kSystemPrompt;
    var finalAnswer = false;
    try {
      await _loadSchemas();
      if (seed != null) {
        final call = _numbered(seed.name, seed.arguments);
        final step = _stepOf(call);
        yield TurnUpdate(phase: TurnPhase.searching, activeTool: seed.name, step: step);
        _messages.add({'role': 'assistant', 'content': null, 'tool_calls': [call.toJson()]});
        await _addResult(call);
        yield TurnUpdate(phase: TurnPhase.thinking, finishedStep: step);
      }
      while (true) {
        // Stop came while no generation was running (the tool schemas were being read, or a tool was running): the step has
        // finished and its result is kept, but no further generation starts. The turn ends as one stopped before the model's
        // first word does: an empty answer in the conversation and the done update.
        if (_stopped) {
          _messages.add({'role': 'assistant', 'content': ''});
          yield TurnUpdate(phase: TurnPhase.done, promptTokens: promptTokens, generatedTokens: generatedTokens);
          return;
        }
        // After kMaxToolRounds rounds the same tool schemas are still sent (a request without them renders a different prompt,
        // which the engine would read again from the tool schemas on), with tool calls switched off and the nudge.
        final capped = rounds >= kMaxToolRounds || finalAnswer;
        final request = _request(_messages, _schemas.isNotEmpty, prompt: prompt, extra: capped ? _kAnswerNow : null, noToolCalls: capped);

        final roundClock = Stopwatch()..start();
        final requestNumber = ++modelRequests;
        int? firstTextMs;
        logInfo('Ask round $requestNumber starts: messages=${(request['messages'] as List).length}, '
            'system_chars=${prompt.length}, tools_chars=${jsonEncode(request['tools'] ?? const []).length}, '
            'thinking_requested=$enableThinking, tool_calls_off=${request['tool_choice'] == 'none'}');
        PartialMessage? last;
        final diagnostics = AskDiagnostics.start(requestNumber);
        try {
          await for (final p in backend.generate(request)) {
            last = p;
            if (p.isFinal) break;
            if (p.hasToolCalls) {
              yield TurnUpdate(phase: TurnPhase.searching, text: _clean(p.content), activeTool: p.toolCalls.first.name);
            } else if (p.content.isNotEmpty) {
              final text = _clean(p.content);
              if (text.trim().isNotEmpty) firstTextMs ??= roundClock.elapsedMilliseconds;
              yield TurnUpdate(phase: TurnPhase.answering, text: text);
            } else {
              yield const TurnUpdate(phase: TurnPhase.thinking);
            }
          }
        } finally {
          diagnostics?.stop();
        }
        if (last == null || !last.isFinal) {
          throw StateError('The model stopped without an answer');
        }
        if (!last.hasToolCalls && _clean(last.content).trim().isNotEmpty) {
          firstTextMs ??= roundClock.elapsedMilliseconds;
        }
        logInfo('Ask round $requestNumber done: prompt=${last.promptTokens}, '
            'reused=${last.reusedTokens ?? 'unknown'}, evaluated=${last.evaluatedPromptTokens ?? 'unknown'}, '
            'start_ms=${last.startMs ?? 'unknown'}, first_token_ms=${last.firstTokenMs ?? 'unknown'}, '
            'first_text_ms=${firstTextMs ?? 'none'}, generated=${last.generatedTokens}, '
            'content_chars=${last.content.length}, reasoning_chars=${last.reasoning.length}, '
            'tool_calls=${last.toolCalls.length}, parse_error=${last.parseError != null}, '
            'native_ms=${last.totalMs ?? 'unknown'}, round_ms=${roundClock.elapsedMilliseconds}');
        if (last.prefixNote != null) logInfo(last.prefixNote!);
        promptTokens += last.promptTokens;
        generatedTokens += last.generatedTokens;

        // The cap is enforced here too, not only by tool_choice "none": once kMaxToolRounds rounds have run, a tool call the
        // model returns anyway is ignored. Its text, if any, is the answer; with none, one more request goes out to get one.
        if (last.hasToolCalls && !_stopped && rounds >= kMaxToolRounds) {
          if (last.content.trim().isEmpty && !finalAnswer) {
            finalAnswer = true;
            continue;
          }
        } else if (last.hasToolCalls && !_stopped) {
          final calls = [for (final c in last.toolCalls) _numbered(c.name, c.arguments)];
          _messages.add({...last.toMessage(), 'tool_calls': [for (final c in calls) c.toJson()]});
          yield TurnUpdate(phase: TurnPhase.searching, activeTool: calls.first.name, completedToolText: _clean(last.content).trim());
          for (final call in calls) {
            final step = _stepOf(call);
            yield TurnUpdate(phase: TurnPhase.searching, activeTool: call.name, step: step);
            await _addResult(call);
            yield TurnUpdate(phase: TurnPhase.thinking, finishedStep: step);
          }
          rounds++;
          continue;
        }

        // The person reads the answer without any tool call the model wrote as text; the conversation keeps what it wrote.
        final check = checkCitations(stripToolCalls(last.content), _results.keys.toSet());
        _messages.add({'role': 'assistant', 'content': last.content});
        yield TurnUpdate(
          phase: TurnPhase.done,
          text: check.text.trim(),
          cited: [for (final n in check.kept) _results[n]!],
          promptTokens: promptTokens,
          generatedTokens: generatedTokens,
          cutShort: last.cutByContext,
        );
        return;
      }
    } on ContextFullException catch (e) {
      logError('Ask: the chat is full (${e.detail})');  // the engine text goes to the log, never to the screen
      yield const TurnUpdate(phase: TurnPhase.done, chatFull: true);
    } catch (e) {
      yield TurnUpdate(phase: TurnPhase.done, error: e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  /// [call] as the progress line shows it. A `read` carries the title of the earlier result it opens (null when that number is not
  /// one of this conversation's results).
  ToolStep _stepOf(ToolCall call) {
    final args = call.argumentsMap;
    if (call.name != 'read') return ToolStep(call.name, args);
    final n = args['n'];
    return ToolStep(call.name, args, n is num ? _results[n.toInt()]?.result.title : null);
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
    final clock = Stopwatch()..start();
    logInfo('Ask tool ${call.name} starts');
    try {
      return await _runCallInner(call);
    } finally {
      logInfo('Ask tool ${call.name} finished in ${clock.elapsedMilliseconds} ms');
    }
  }

  Future<String> _runCallInner(ToolCall call) async {
    final host = this.host;
    if (host != null) {
      try {
        final r = await host.call(call.name, call.argumentsMap, DateTime.now());
        // One line per call for logcat (no arguments or text): which tool ran and which [n] it gave.
        logInfo('Ask tool ${call.name}: new ids ${[for (final i in r.ids) i.n]}, ${r.content.length} chars');
        for (final id in r.ids) {
          _results.putIfAbsent(id.n, () => NumberedResult(id.n, SourceResult(title: id.title, snippet: '', address: id.address, link: id.link, time: id.time, pdfPage: id.pdfPage, quote: id.quote, timeEnd: id.timeEnd, lang: id.lang)));
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
        () => NumberedResult(id.n, SourceResult(title: id.title, snippet: snippets[id.address] ?? '', address: id.address, link: id.link, time: id.time, pdfPage: id.pdfPage, quote: id.quote, timeEnd: id.timeEnd, lang: id.lang)),
      );
    }
  }
}
