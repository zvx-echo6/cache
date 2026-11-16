import 'dart:typed_data';

import '../chat/navigation_action.dart';
import 'conversation_store.dart';

/// The conversations in memory, for the browser until the server keeps them (history over the server is a later step). It has the
/// shape of [ConversationStore]: it starts empty, hands back the same kinds of answers, and keeps nothing once the page closes.
class MemoryConversationStore implements ConversationStore {
  MemoryConversationStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<int, _Row> _rows = {};
  int _nextConversation = 1;
  int _nextMessage = 1;

  @override
  void close() {}

  /// Puts a conversation in as another keeper (the server's history) has it, replacing one with the same id. Not part of
  /// [ConversationStore]; [ServerConversationStore] uses it.
  void restore(Conversation c, {required bool deleted, Uint8List? numbering, required List<StoredMessage> messages}) {
    final r = _Row(c.id, c.title, c.created, c.model, c.voice)
      ..titleSource = c.titleSource
      ..updated = c.updated
      ..pinned = c.pinned
      ..deleted = deleted
      ..numbering = numbering
      ..messages.addAll(messages);
    _rows[c.id] = r;
  }

  /// Whether a conversation is kept, deleted or not.
  bool has(int id) => _rows.containsKey(id);

  /// Drops a conversation without the delete and purge steps (the server says it is gone).
  void forget(int id) => _rows.remove(id);

  @override
  void atomic(void Function() write) => write();

  Conversation _view(_Row r) => Conversation(
        id: r.id,
        title: r.title,
        titleSource: r.titleSource,
        created: r.created,
        updated: r.updated,
        pinned: r.pinned,
        model: r.model,
        voice: r.voice,
      );

  @override
  Conversation create({required String title, String model = '', bool voice = false, int? id}) {
    final t = _now();
    final r = _Row(id ?? _nextConversation++, title, t, model, voice);
    _rows[r.id] = r;
    return _view(r);
  }

  @override
  Conversation? get(int id) {
    final r = _rows[id];
    return r == null || r.deleted ? null : _view(r);
  }

  @override
  List<Conversation> list() {
    final rows = [for (final r in _rows.values) if (!r.deleted) r]
      ..sort((a, b) {
        final byTime = b.updated.compareTo(a.updated);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
    return [for (final r in rows) _view(r)];
  }

  @override
  void rename(int id, String title) {
    final r = _rows[id];
    if (r == null) return;
    r.title = title;
    r.titleSource = TitleSource.user;
  }

  @override
  bool setGeneratedTitle(int id, String title) {
    final r = _rows[id];
    if (r == null || r.titleSource != TitleSource.question) return false;
    r.title = title;
    r.titleSource = TitleSource.generated;
    return true;
  }

  @override
  void setPinned(int id, bool pinned) => _rows[id]?.pinned = pinned;

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
    int? id,
  }) {
    final r = _rows[conversationId];
    id ??= _nextMessage++;
    final t = _now();
    r?.messages.add(StoredMessage(
      id: id,
      role: role,
      content: content,
      message: message,
      citations: citations,
      error: error,
      created: t,
      stats: stats,
      inTranscript: inTranscript,
      navigationActions: navigationActions,
    ));
    if (r != null) {
      r.updated = t;
      if (model != null) r.model = model;
    }
    return id;
  }

  @override
  void setNavigationActions(int messageId, List<NavigationAction> actions) {
    for (final r in _rows.values) {
      for (var i = 0; i < r.messages.length; i++) {
        final m = r.messages[i];
        if (m.id != messageId) continue;
        r.messages[i] = StoredMessage(
          id: m.id,
          role: m.role,
          content: m.content,
          message: m.message,
          citations: m.citations,
          error: m.error,
          created: m.created,
          stats: m.stats,
          inTranscript: m.inTranscript,
          navigationActions: actions,
        );
        return;
      }
    }
  }

  @override
  void removeActionDraft(int messageId) {
    for (final r in _rows.values) {
      r.messages.removeWhere((m) => m.id == messageId && !m.inTranscript);
    }
  }

  @override
  List<StoredMessage> messages(int conversationId) => List.of(_rows[conversationId]?.messages ?? const <StoredMessage>[]);

  @override
  List<Map<String, dynamic>> transcript(int conversationId) => [
        for (final m in messages(conversationId))
          if (m.inTranscript) m.message,
      ];

  @override
  Uint8List? numbering(int id) => _rows[id]?.numbering;

  @override
  void setNumbering(int id, Uint8List? state) => _rows[id]?.numbering = state;

  @override
  void delete(int id) => _rows[id]?.deleted = true;

  @override
  void undelete(int id) => _rows[id]?.deleted = false;

  @override
  void purge(int id) {
    if (_rows[id]?.deleted == true) _rows.remove(id);
  }

  @override
  void purgeDeleted() => _rows.removeWhere((_, r) => r.deleted);

  @override
  void deleteAll() => _rows.clear();

  @override
  List<SearchHit> search(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    bool matches(String text) {
      final t = text.toLowerCase();
      return words.every(t.contains);
    }

    final hits = <SearchHit>[];
    for (final c in list()) {
      final r = _rows[c.id]!;
      String? snippet;
      for (final m in r.messages) {
        if (m.shown && m.content.trim().isNotEmpty && matches(m.content)) {
          snippet = m.content;
          break;
        }
      }
      if (snippet != null) {
        hits.add(SearchHit(c, snippet));
      } else if (matches(c.title)) {
        hits.add(SearchHit(c, ''));
      }
    }
    return hits;
  }
}

class _Row {
  _Row(this.id, this.title, this.created, this.model, this.voice) : updated = created;

  final int id;
  String title;
  TitleSource titleSource = TitleSource.question;
  final DateTime created;
  DateTime updated;
  bool pinned = false;
  String model;
  final bool voice;
  bool deleted = false;
  Uint8List? numbering;
  final List<StoredMessage> messages = [];
}
