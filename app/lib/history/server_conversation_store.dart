import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cache_search/cache_search.dart' show CacheSearchException, CoreTransport;

import '../chat/navigation_action.dart';
import 'conversation_store.dart';
import 'memory_conversation_store.dart';

/// The browser's chat history: the conversations are kept on the server (the helper's `history.*` ops, server/helper/bin/
/// history_ops.dart) so every tab and browser lists, reopens, renames and deletes the same ones.
///
/// [ConversationStore] is synchronous, so this keeps the conversations in a [MemoryConversationStore] and answers from it. Every
/// write is made there at once and also queued as an op for the server; the queue is sent in order and retried when the server
/// cannot be reached. Ids are made here (time based), so `create` stays synchronous. Every few seconds [refresh] asks the server
/// what changed and takes in what other tabs did, except for a conversation this tab has unsent or just-sent writes for.
class ServerConversationStore implements ConversationStore {
  ServerConversationStore(this._t, {DateTime Function()? now, Random? random, this.onChanged})
      : _now = now ?? DateTime.now,
        _random = random ?? Random(),
        _mem = MemoryConversationStore(now: now);

  /// Opens the store: the first sync must work (it throws when the server cannot be reached). [poll] is how often it looks for
  /// changes made elsewhere; null never polls (tests call [refresh]).
  static Future<ServerConversationStore> open(
    CoreTransport transport, {
    Duration? poll = const Duration(seconds: 4),
    DateTime Function()? now,
    Random? random,
    void Function()? onChanged,
  }) async {
    final s = ServerConversationStore(transport, now: now, random: random, onChanged: onChanged);
    await s.refresh();
    if (poll != null) s._timer = Timer.periodic(poll, (_) => unawaited(s.refresh()));
    return s;
  }

  final CoreTransport _t;
  final DateTime Function() _now;
  final Random _random;
  final MemoryConversationStore _mem;

  /// Called when a refresh changed what the list or an open conversation shows.
  void Function()? onChanged;

  Timer? _timer;
  Timer? _retry;
  int _since = 0;
  int _lastId = 0;
  bool _forceFull = false;
  bool _refreshing = false;
  final List<_Op> _queue = [];
  bool _pumping = false;
  final Set<int> _touched = {};
  final Map<int, int> _messageConversation = {};

  int _newId() {
    var id = _now().millisecondsSinceEpoch * 1024 + _random.nextInt(1024);
    if (id <= _lastId) id = _lastId + 1;
    return _lastId = id;
  }

  static int _ms(DateTime t) => t.millisecondsSinceEpoch;

  // ---- the queue to the server

  void _send(String op, Map<String, dynamic> args, int? conversation) {
    if (conversation != null) _touched.add(conversation);
    _queue.add(_Op(op, args, conversation));
    unawaited(_pump());
  }

  bool _unsent(int id) => _queue.any((o) => o.conversation == id || o.conversation == null);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        final o = _queue.first;
        try {
          await _t.call(o.op, o.args);
        } on CacheSearchException catch (e) {
          if (e.code == 'internal' || e.code == 'unauthorized' || e.code == 'core_unavailable') {
            _retry ??= Timer(const Duration(seconds: 3), () {
              _retry = null;
              unawaited(_pump());
            });
            return;
          }
          // The server refused this op (it would be refused again): drop it.
        } catch (_) {
          // Anything else would fail the same way again: drop it rather than block the ones behind it.
        }
        _queue.removeAt(0);
        if (o.conversation != null) _touched.add(o.conversation!);
      }
    } finally {
      _pumping = false;
    }
  }

  /// Sends what is queued and waits until the queue is empty or the server cannot be reached (for tests and for closing).
  Future<void> flush() async {
    await _pump();
    while (_pumping) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  // ---- taking in what the server has

  /// Asks the server what changed since the last look and takes it in. Does nothing if a refresh is already running.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      _touched.clear();
      final since = _forceFull ? 0 : _since;
      _forceFull = false;
      final r = await _t.call('history.sync', {'since': since});
      if (r is! Map) return;
      var skipped = false;
      var changed = false;
      for (final raw in (r['conversations'] as List? ?? const [])) {
        final c = (raw as Map).cast<String, dynamic>();
        final id = (c['id'] as num).toInt();
        if (_unsent(id) || _touched.contains(id)) {
          skipped = true;
          continue;
        }
        final before = _sig(id);
        _apply(c);
        if (_sig(id) != before) changed = true;
      }
      for (final raw in (r['gone'] as List? ?? const [])) {
        final id = (raw as num).toInt();
        if (_unsent(id) || _touched.contains(id)) {
          skipped = true;
          continue;
        }
        if (_mem.has(id)) {
          _mem.forget(id);
          changed = true;
        }
      }
      // A skipped conversation is looked at again next time: its rev is not passed over.
      if (!skipped) _since = (r['rev'] as num?)?.toInt() ?? _since;
      if (changed) onChanged?.call();
    } finally {
      _refreshing = false;
    }
  }

  String _sig(int id) {
    final c = _mem.get(id);
    if (c == null) return 'none';
    final m = _mem.messages(id);
    return '${c.title}|${c.titleSource.name}|${_ms(c.updated)}|${c.pinned}|${c.model}|${m.length}|${m.isEmpty ? 0 : m.last.id}|${m.fold<int>(0, (a, x) => a + x.navigationActions.length)}';
  }

  void _apply(Map<String, dynamic> c) {
    final id = (c['id'] as num).toInt();
    final messages = [for (final m in (c['messages'] as List? ?? const [])) _message((m as Map).cast<String, dynamic>())];
    final conversation = Conversation(
      id: id,
      title: (c['title'] ?? '') as String,
      titleSource: TitleSource.values.firstWhere((t) => t.name == c['titleSource'], orElse: () => TitleSource.question),
      created: DateTime.fromMillisecondsSinceEpoch((c['created'] as num).toInt()),
      updated: DateTime.fromMillisecondsSinceEpoch((c['updated'] as num).toInt()),
      pinned: c['pinned'] == true,
      model: (c['model'] ?? '') as String,
      voice: c['voice'] == true,
    );
    final n = c['numbering'];
    _mem.restore(conversation, deleted: c['deleted'] == true, numbering: n is String ? base64Decode(n) : null, messages: messages);
    for (final m in messages) {
      _messageConversation[m.id] = id;
    }
  }

  StoredMessage _message(Map<String, dynamic> m) => StoredMessage(
        id: (m['id'] as num).toInt(),
        role: m['role'] as String,
        content: (m['content'] ?? '') as String,
        message: (m['message'] as Map).cast<String, dynamic>(),
        citations: [for (final c in (m['citations'] as List? ?? const [])) StoredCitation.fromJson((c as Map).cast<String, dynamic>())],
        error: m['error'] as String?,
        created: DateTime.fromMillisecondsSinceEpoch((m['created'] as num).toInt()),
        stats: GenerationStats(
          promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
          generatedTokens: (m['generatedTokens'] as num?)?.toInt() ?? 0,
          durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        ),
        inTranscript: m['inTranscript'] != false,
        navigationActions: NavigationAction.decode(jsonEncode(m['navigationActions'] ?? const [])),
      );

  Map<String, dynamic> _messageJson(StoredMessage m) => {
        'id': m.id,
        'role': m.role,
        'content': m.content,
        'message': m.message,
        'citations': [for (final c in m.citations) c.toJson()],
        'error': m.error,
        'created': _ms(m.created),
        'promptTokens': m.stats.promptTokens,
        'generatedTokens': m.stats.generatedTokens,
        'durationMs': m.stats.durationMs,
        'inTranscript': m.inTranscript,
        'navigationActions': [for (final a in m.navigationActions) a.toJson()],
      };

  void _update(int id, Map<String, dynamic> fields) => _send('history.update', {'id': id, 'fields': fields}, id);

  // ---- ConversationStore

  @override
  void close() {
    _timer?.cancel();
    _retry?.cancel();
    _mem.close();
  }

  @override
  void atomic(void Function() write) => write();

  @override
  Conversation create({required String title, String model = '', bool voice = false}) {
    final c = _mem.create(title: title, model: model, voice: voice, id: _newId());
    _send(
      'history.create',
      {
        'conversation': {
          'id': c.id,
          'title': c.title,
          'titleSource': c.titleSource.name,
          'created': _ms(c.created),
          'updated': _ms(c.updated),
          'pinned': c.pinned,
          'model': c.model,
          'voice': c.voice,
        },
      },
      c.id,
    );
    return c;
  }

  @override
  Conversation? get(int id) => _mem.get(id);

  @override
  List<Conversation> list() => _mem.list();

  @override
  void rename(int id, String title) {
    if (_mem.get(id) == null) return;
    _mem.rename(id, title);
    _update(id, {'title': title, 'titleSource': TitleSource.user.name});
  }

  @override
  bool setGeneratedTitle(int id, String title) {
    if (!_mem.setGeneratedTitle(id, title)) return false;
    _update(id, {'title': title, 'titleSource': TitleSource.generated.name});
    return true;
  }

  @override
  void setPinned(int id, bool pinned) {
    if (_mem.get(id) == null) return;
    _mem.setPinned(id, pinned);
    _update(id, {'pinned': pinned});
  }

  @override
  int addMessage(
    int conversationId, {
    required String role,
    required String content,
    required Map<String, dynamic> message,
    List<StoredCitation> citations = const [],
    List<NavigationAction> navigationActions = const [],
    String? error,
    GenerationStats stats = const GenerationStats(),
    bool inTranscript = true,
    String? model,
  }) {
    final id = _newId();
    _mem.addMessage(conversationId,
        role: role,
        content: content,
        message: message,
        citations: citations,
        navigationActions: navigationActions,
        error: error,
        stats: stats,
        inTranscript: inTranscript,
        model: model,
        id: id);
    final c = _mem.get(conversationId);
    final stored = _mem.messages(conversationId).where((m) => m.id == id);
    if (c == null || stored.isEmpty) return id;
    _messageConversation[id] = conversationId;
    _send('history.addMessage', {'id': conversationId, 'message': _messageJson(stored.first), 'updated': _ms(c.updated), 'model': ?model}, conversationId);
    return id;
  }

  @override
  void setNavigationActions(int messageId, List<NavigationAction> actions) {
    final cid = _messageConversation[messageId];
    _mem.setNavigationActions(messageId, actions);
    if (cid != null) _send('history.setNavigationActions', {'id': cid, 'messageId': messageId, 'actions': [for (final a in actions) a.toJson()]}, cid);
  }

  @override
  void removeActionDraft(int messageId) {
    final cid = _messageConversation[messageId];
    _mem.removeActionDraft(messageId);
    if (cid != null) _send('history.removeMessage', {'id': cid, 'messageId': messageId}, cid);
  }

  @override
  List<StoredMessage> messages(int conversationId) => _mem.messages(conversationId);

  @override
  List<Map<String, dynamic>> transcript(int conversationId) => _mem.transcript(conversationId);

  @override
  Uint8List? numbering(int id) => _mem.numbering(id);

  @override
  void setNumbering(int id, Uint8List? state) {
    if (_mem.get(id) == null) return;
    _mem.setNumbering(id, state);
    _update(id, {'numbering': state == null ? null : base64Encode(state)});
  }

  @override
  void delete(int id) {
    _mem.delete(id);
    _update(id, {'deleted': true});
  }

  @override
  void undelete(int id) {
    _mem.undelete(id);
    _update(id, {'deleted': false});
  }

  @override
  void purge(int id) {
    _mem.purge(id);
    _send('history.purge', {'id': id}, id);
  }

  /// Removes what was deleted and not undone, at the server: only what was deleted over a minute ago, so another tab's Undo
  /// still works. (The list never shows a deleted conversation, so nothing is dropped here.)
  @override
  void purgeDeleted() {
    _forceFull = true;
    _send('history.purgeDeleted', {'olderThanMs': 60000}, null);
  }

  @override
  void deleteAll() {
    _mem.deleteAll();
    _send('history.deleteAll', {}, null);
  }

  @override
  List<SearchHit> search(String query) => _mem.search(query);
}

class _Op {
  _Op(this.op, this.args, this.conversation);

  final String op;
  final Map<String, dynamic> args;

  /// The conversation it changes; null for ops that touch all of them.
  final int? conversation;
}
