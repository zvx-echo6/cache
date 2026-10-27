import 'package:flutter/foundation.dart';

import '../history/conversation_store.dart';
import '../history/markdown_export.dart';
import '../history/titles.dart';
import '../search/numbering_state.dart';
import 'model_backend.dart';
import 'system_prompt.dart';
import 'tool.dart';
import 'tool_loop.dart';

/// One message in the Ask screen.
class ChatMessage {
  ChatMessage.user(this.text)
      : isUser = true,
        phase = TurnPhase.done;
  ChatMessage.assistant()
      : isUser = false,
        text = '',
        phase = TurnPhase.thinking;

  /// A message read back from storage.
  ChatMessage.stored(StoredMessage m)
      : isUser = m.role == 'user',
        text = m.content,
        phase = TurnPhase.done,
        error = m.error,
        sources = [
          for (final c in m.citations)
            NumberedResult(c.n, SourceResult(title: c.title, snippet: c.snippet, address: c.address)),
        ];

  final bool isUser;
  String text;
  TurnPhase phase;
  List<NumberedResult> sources = const [];
  String? error;
  bool get isDone => phase == TurnPhase.done;
  bool get streaming => !isDone;
}

/// The Ask conversation and the list of past ones. Lives above the tabs so it survives switching between
/// them. The open conversation is kept in the [ConversationStore] as it goes; a new chat is stored with its
/// first question.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.tools,
    this.newNumbering,
    this.newHost,
    this.locationKnown,
    this.prepareTurn,
    this.numberingState,
  });

  final List<Tool> tools;

  /// The search core's tools for a new chat (cs_tool_schemas, cs_tool); null (or returning null): [tools] are used.
  /// It gets the chat's numbering, whose conversation the core's tools number their sources in.
  final ToolHost? Function(ResultNumbering? numbering)? newHost;

  /// Whether the phone's location is known right now, for the system prompt.
  final bool Function()? locationKnown;

  /// Optional shared preparation before each inference, including restored chats.
  /// Cancellation must prevent late preparation from starting model generation.
  final Future<void> Function(bool Function() isCancelled)? prepareTurn;

  /// Makes the numbering of a new chat in the search core; null (or returning null) numbers in Dart.
  final ResultNumbering? Function()? newNumbering;

  /// Saves and restores a conversation's numbering; null: it is not kept between runs.
  final NumberingState? numberingState;
  final List<ChatMessage> messages = [];

  /// Bumped when the list of conversations changes, so the drawer can reload without listening to every
  /// streamed token.
  final ValueNotifier<int> historyRevision = ValueNotifier(0);

  ConversationStore? _store;
  ToolLoop? _loop;
  ModelBackend? _backend;
  String _modelName = '';
  int? _activeId;
  int _epoch = 0;
  Object? _turn;
  bool _preparing = false;
  bool busy = false;
  Future<void>? _titleJob;
  bool _titleCancelled = false;

  ConversationStore? get store => _store;

  /// The stored conversation on screen; null for a new chat that has no question yet.
  int? get activeId => _activeId;

  /// Starts keeping conversations in [store]. Conversations deleted but not undone last time are removed.
  void attachStore(ConversationStore store) {
    _store = store..purgeDeleted();
    _bump();
  }

  void _bump() => historyRevision.value++;

  /// The model for the next answers. A different model keeps the open conversation: its transcript is
  /// sent to the new model, which rebuilds its context.
  void setBackend(ModelBackend? backend, {String modelName = ''}) {
    if (identical(backend, _backend)) return;
    _backend = backend;
    _modelName = modelName;
    _dropLoop();
    _turn = null;
    _preparing = false;
    notifyListeners();
  }

  bool get canSend => _backend != null && !busy;

  /// Lets go of the loop. While an answer is being stored the loop is still needed; [send] frees it then.
  void _dropLoop() {
    final loop = _loop;
    _loop = null;
    if (loop == null) return;
    loop.stop();
    if (!busy || _preparing) loop.dispose();
  }

  void newChat() {
    _dropLoop();
    _epoch++;
    _turn = null;
    _preparing = false;
    messages.clear();
    _activeId = null;
    busy = false;
    notifyListeners();
  }

  /// Shows a stored conversation as it was. Sending continues it.
  void openConversation(int id) {
    final store = _store;
    if (store == null || id == _activeId || store.get(id) == null) return;
    newChat();
    _activeId = id;
    messages.addAll([
      for (final m in store.messages(id))
        if (m.shown) ChatMessage.stored(m),
    ]);
    notifyListeners();
  }

  void stop() {
    _turn = null;
    _loop?.stop();
  }

  Future<void> renameConversation(int id, String title) async {
    title = title.trim();
    if (title.isEmpty) return;
    _store?.rename(id, title);
    _bump();
  }

  void setPinned(int id, bool pinned) {
    _store?.setPinned(id, pinned);
    _bump();
  }

  /// Hides a conversation so it can be undone; call [purgeConversation] when it can no longer be.
  void deleteConversation(int id) {
    if (id == _activeId) newChat();
    _store?.delete(id);
    _bump();
  }

  void undoDelete(int id) {
    _store?.undelete(id);
    _bump();
  }

  void purgeConversation(int id) => _store?.purge(id);

  void deleteAllConversations() {
    newChat();
    _store?.deleteAll();
    _bump();
  }

  /// The conversation as Markdown, or null if it does not exist.
  String? exportMarkdown(int id) {
    final store = _store;
    final c = store?.get(id);
    return c == null ? null : conversationToMarkdown(c, store!.messages(id));
  }

  Future<ToolLoop> _loopFor(int? id, ModelBackend backend) async {
    final store = _store;
    final history = id == null || store == null ? const <Map<String, dynamic>>[] : store.transcript(id);
    final cited = <int, NumberedResult>{};
    if (id != null && store != null) {
      for (final m in store.messages(id)) {
        for (final c in m.citations) {
          cited[c.n] = NumberedResult(c.n, SourceResult(title: c.title, snippet: c.snippet, address: c.address));
        }
      }
    }
    ResultNumbering? numbering;
    final saved = id == null ? null : store?.numbering(id);
    if (saved != null && numberingState != null) {
      numbering = await numberingState!.restore(saved);
    } else if (history.isEmpty) {
      numbering = newNumbering?.call();
    }
    final loop = ToolLoop(
      backend: backend,
      tools: tools,
      numbering: numbering,
      host: newHost?.call(numbering),
      systemPrompt: () => buildSystemPrompt(now: DateTime.now(), locationKnown: locationKnown?.call() ?? false),
      history: history,
      knownResults: cited.values,
    );
    await loop.syncNumbering();
    return loop;
  }

  Future<void> send(String text) async {
    text = text.trim();
    final backend = _backend;
    if (text.isEmpty || backend == null || busy) return;
    busy = true;
    final epoch = _epoch;
    final turn = _turn = Object();
    bool cancelled() => epoch != _epoch || !identical(_turn, turn);
    final reply = ChatMessage.assistant();
    messages
      ..add(ChatMessage.user(text))
      ..add(reply);
    notifyListeners();

    ToolLoop? loop;
    int? convId;
    var start = 0;
    final clock = Stopwatch()..start();
    TurnUpdate? last;
    try {
      await _cancelTitle(backend);
      if (cancelled()) return;
      _preparing = true;
      try {
        await prepareTurn?.call(cancelled);
      } catch (_) {
        // Optional device context never blocks an ordinary question.
      } finally {
        if (identical(_turn, turn)) _preparing = false;
      }
      if (cancelled()) return;
      final store = _store;
      convId = _activeId;
      if (store != null && convId == null) {
        try {
          convId = _activeId = store.create(title: questionTitle(text), model: _modelName).id;
          _bump();
        } catch (_) {
          // Keeping the history must never break answering.
        }
      }
      // The loop reads the stored transcript, so it is made before this question is stored.
      var made = _loop;
      if (made == null) {
        made = await _loopFor(convId, backend);
        if (cancelled()) {
          await made.dispose();
          return;
        }
        _loop = made;
      }
      loop = made;
      if (store != null && convId != null) {
        try {
          store.addMessage(convId, role: 'user', content: text, message: {'role': 'user', 'content': text}, model: _modelName);
        } catch (_) {}
      }
      if (cancelled()) return;
      start = loop.messages.length;
      await for (final u in loop.ask(text)) {
        if (epoch != _epoch) return; // chat was reset meanwhile
        last = u;
        reply
          ..phase = u.phase
          ..error = u.error;
        if (u.phase == TurnPhase.answering || u.phase == TurnPhase.done) reply.text = u.text;
        if (u.phase == TurnPhase.done) reply.sources = u.cited;
        notifyListeners();
      }
    } catch (e) {
      reply.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      reply.phase = TurnPhase.done;
      if (loop != null && convId != null) {
        await _saveTurn(convId, loop, start, reply, last, clock.elapsedMilliseconds);
      }
      if (loop != null && !identical(_loop, loop)) await loop.dispose();
      if (epoch == _epoch) busy = false;
      notifyListeners();
    }
    if (epoch == _epoch && identical(_loop, loop) && start == 0 && loop != null && convId != null && reply.error == null && reply.text.isNotEmpty) {
      _titleJob = _writeTitle(convId, loop, backend);
    }
  }

  /// Stores what the turn added to the transcript, with the shown answer, its citations and its stats.
  Future<void> _saveTurn(int convId, ToolLoop loop, int start, ChatMessage reply, TurnUpdate? last, int ms) async {
    final store = _store;
    if (store == null) return;
    try {
      final added = loop.messages.skip(start + 1).toList(); // the question was stored when it was sent
      final stats = GenerationStats(
        promptTokens: last?.promptTokens ?? 0,
        generatedTokens: last?.generatedTokens ?? 0,
        durationMs: ms,
      );
      var answered = false;
      for (var i = 0; i < added.length; i++) {
        final m = added[i];
        final isAnswer = i == added.length - 1 && m['role'] == 'assistant' && m['tool_calls'] == null && reply.error == null;
        answered = isAnswer;
        store.addMessage(
          convId,
          role: m['role'] as String,
          content: isAnswer ? reply.text : (m['content'] ?? '').toString(),
          message: m,
          citations: isAnswer
              ? [for (final s in reply.sources) StoredCitation(n: s.id, title: s.result.title, snippet: s.result.snippet, address: s.result.address)]
              : const [],
          stats: isAnswer ? stats : const GenerationStats(),
          model: _modelName,
        );
      }
      if (!answered) {
        store.addMessage(
          convId,
          role: 'assistant',
          content: reply.text,
          message: {'role': 'assistant', 'content': reply.text},
          error: reply.error ?? 'No answer was produced.',
          stats: stats,
          inTranscript: false,
          model: _modelName,
        );
      }
      final numbering = loop.numbering;
      if (numbering != null && numberingState != null) {
        final state = await numberingState!.save(numbering);
        if (state != null) store.setNumbering(convId, state);
      }
      _bump();
    } catch (_) {
      // Keeping the history must never break answering.
    }
  }

  /// Replaces the question-title with one the model writes, when the model is idle.
  Future<void> _writeTitle(int convId, ToolLoop loop, ModelBackend backend) async {
    _titleCancelled = false;
    try {
      final title = await generateTitle(backend, loop, isCancelled: () => _titleCancelled);
      if (title == null || _titleCancelled) return;
      if (_store?.setGeneratedTitle(convId, title) ?? false) _bump();
    } catch (_) {
      // The question stays as the title.
    } finally {
      _titleJob = null;
    }
  }

  /// Completes when no title is being written (a test hook).
  Future<void> whenIdle() => _titleJob ?? Future.value();

  /// A question must not wait behind a title: stop the title and wait for the model to be free.
  Future<void> _cancelTitle(ModelBackend backend) async {
    final job = _titleJob;
    if (job == null) return;
    _titleCancelled = true;
    backend.stop();
    await job;
  }
}
