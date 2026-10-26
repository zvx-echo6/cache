import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Where a conversation's title came from. A title the user typed is never replaced.
enum TitleSource { question, generated, user }

/// One conversation in the list.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.titleSource,
    required this.created,
    required this.updated,
    required this.pinned,
    required this.model,
  });

  final int id;
  final String title;
  final TitleSource titleSource;
  final DateTime created;
  final DateTime updated;
  final bool pinned;

  /// The model that gave the last answer (its display name), or empty.
  final String model;
}

/// A cited result as the answer showed it: its number, and the address it opens.
class StoredCitation {
  const StoredCitation({required this.n, required this.title, required this.snippet, required this.address});

  factory StoredCitation.fromJson(Map<String, dynamic> j) => StoredCitation(
        n: j['n'] as int,
        title: (j['title'] ?? '') as String,
        snippet: (j['snippet'] ?? '') as String,
        address: (j['address'] ?? '') as String,
      );

  final int n;
  final String title;
  final String snippet;
  final String address;

  Map<String, dynamic> toJson() => {'n': n, 'title': title, 'snippet': snippet, 'address': address};
}

/// Prompt size, answer size and time of one answer.
class GenerationStats {
  const GenerationStats({this.promptTokens = 0, this.generatedTokens = 0, this.durationMs = 0});

  final int promptTokens;
  final int generatedTokens;
  final int durationMs;
}

/// One stored message. [message] is the exact OpenAI style map the model saw (tool calls and tool results
/// included). [content] is the text the screen shows (the answer with unknown [n] markers removed).
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.message,
    required this.citations,
    required this.error,
    required this.created,
    required this.stats,
    required this.inTranscript,
  });

  final int id;
  final String role;
  final String content;
  final Map<String, dynamic> message;
  final List<StoredCitation> citations;
  final String? error;
  final DateTime created;
  final GenerationStats stats;

  /// False for rows only the screen needs (an error line); true for what the model saw.
  final bool inTranscript;

  /// Whether the Ask screen shows this row: questions and final answers, not tool calls or results.
  bool get shown => !inTranscript || role == 'user' || (role == 'assistant' && message['tool_calls'] == null);
}

/// A search hit: the conversation and a short piece of the matching text.
class SearchHit {
  const SearchHit(this.conversation, this.snippet);

  final Conversation conversation;

  /// Empty when only the title matched.
  final String snippet;
}

const int _schemaVersion = 1;

/// The conversations on this phone, in SQLite (the `sqlite3` package, which brings its own SQLite with FTS5).
/// Calls are synchronous: rows are small and the database is local.
class ConversationStore {
  ConversationStore._(this._db, this._now) {
    _migrate();
  }

  /// Opens (or creates) the database file at [path].
  factory ConversationStore.open(String path, {DateTime Function()? now}) =>
      ConversationStore._(sqlite3.open(path), now ?? DateTime.now);

  /// A throwaway database in memory (tests).
  factory ConversationStore.memory({DateTime Function()? now}) =>
      ConversationStore._(sqlite3.openInMemory(), now ?? DateTime.now);

  final Database _db;
  final DateTime Function() _now;

  void close() => _db.close();

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    try {
      _db.execute('PRAGMA journal_mode = WAL');
    } catch (_) {}
    final v = _db.userVersion;
    if (v >= _schemaVersion) return;
    _db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        title_source INTEGER NOT NULL DEFAULT 0,
        created INTEGER NOT NULL,
        updated INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        model TEXT NOT NULL DEFAULT '',
        numbering BLOB,
        deleted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        message_json TEXT NOT NULL,
        citations_json TEXT NOT NULL DEFAULT '[]',
        error TEXT,
        created INTEGER NOT NULL,
        prompt_tokens INTEGER NOT NULL DEFAULT 0,
        generated_tokens INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        in_transcript INTEGER NOT NULL DEFAULT 1
      );
      CREATE INDEX messages_by_conversation ON messages(conversation_id, id);
      CREATE VIRTUAL TABLE search_fts USING fts5(
        text,
        conversation_id UNINDEXED,
        message_id UNINDEXED,
        tokenize = 'unicode61 remove_diacritics 2'
      );
    ''');
    _db.userVersion = _schemaVersion;
  }

  int _ms(DateTime t) => t.millisecondsSinceEpoch;

  Conversation _conversation(Row r) => Conversation(
        id: r['id'] as int,
        title: r['title'] as String,
        titleSource: TitleSource.values[r['title_source'] as int],
        created: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
        updated: DateTime.fromMillisecondsSinceEpoch(r['updated'] as int),
        pinned: (r['pinned'] as int) != 0,
        model: r['model'] as String,
      );

  /// Starts a conversation titled with the (trimmed) first question.
  Conversation create({required String title, String model = ''}) {
    final t = _ms(_now());
    _db.execute('INSERT INTO conversations (title, created, updated, model) VALUES (?, ?, ?, ?)', [title, t, t, model]);
    final id = _db.lastInsertRowId;
    _indexTitle(id, title);
    return get(id)!;
  }

  Conversation? get(int id) {
    final rows = _db.select('SELECT * FROM conversations WHERE id = ? AND deleted = 0', [id]);
    return rows.isEmpty ? null : _conversation(rows.first);
  }

  /// Every conversation that is not deleted, most recently changed first.
  List<Conversation> list() => [
        for (final r in _db.select('SELECT * FROM conversations WHERE deleted = 0 ORDER BY updated DESC, id DESC'))
          _conversation(r),
      ];

  void _touch(int id, {String? model}) {
    _db.execute('UPDATE conversations SET updated = ?, model = COALESCE(?, model) WHERE id = ?', [_ms(_now()), model, id]);
  }

  void _indexTitle(int id, String title) {
    _db.execute('DELETE FROM search_fts WHERE conversation_id = ? AND message_id = 0', [id]);
    _db.execute('INSERT INTO search_fts (text, conversation_id, message_id) VALUES (?, ?, 0)', [title, id]);
  }

  /// A title the user typed. Never replaced by a generated one.
  void rename(int id, String title) {
    _db.execute('UPDATE conversations SET title = ?, title_source = ? WHERE id = ?', [title, TitleSource.user.index, id]);
    _indexTitle(id, title);
  }

  /// The title the model wrote. Only used while the title is still the trimmed question.
  bool setGeneratedTitle(int id, String title) {
    _db.execute('UPDATE conversations SET title = ?, title_source = ? WHERE id = ? AND title_source = ?',
        [title, TitleSource.generated.index, id, TitleSource.question.index]);
    final changed = _db.updatedRows > 0;
    if (changed) _indexTitle(id, title);
    return changed;
  }

  void setPinned(int id, bool pinned) {
    _db.execute('UPDATE conversations SET pinned = ? WHERE id = ?', [pinned ? 1 : 0, id]);
  }

  /// Appends a message and returns its id. Text the person can read (questions and shown answers) is
  /// indexed for search.
  int addMessage(
    int conversationId, {
    required String role,
    required String content,
    required Map<String, dynamic> message,
    List<StoredCitation> citations = const [],
    String? error,
    GenerationStats stats = const GenerationStats(),
    bool inTranscript = true,
    String? model,
  }) {
    _db.execute(
      'INSERT INTO messages (conversation_id, role, content, message_json, citations_json, error, created, '
      'prompt_tokens, generated_tokens, duration_ms, in_transcript) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        conversationId,
        role,
        content,
        jsonEncode(message),
        jsonEncode([for (final c in citations) c.toJson()]),
        error,
        _ms(_now()),
        stats.promptTokens,
        stats.generatedTokens,
        stats.durationMs,
        inTranscript ? 1 : 0,
      ],
    );
    final id = _db.lastInsertRowId;
    if (content.trim().isNotEmpty && (role == 'user' || (role == 'assistant' && message['tool_calls'] == null))) {
      _db.execute('INSERT INTO search_fts (text, conversation_id, message_id) VALUES (?, ?, ?)', [content, conversationId, id]);
    }
    _touch(conversationId, model: model);
    return id;
  }

  List<StoredMessage> messages(int conversationId) => [
        for (final r in _db.select('SELECT * FROM messages WHERE conversation_id = ? ORDER BY id', [conversationId]))
          StoredMessage(
            id: r['id'] as int,
            role: r['role'] as String,
            content: r['content'] as String,
            message: (jsonDecode(r['message_json'] as String) as Map).cast<String, dynamic>(),
            citations: [
              for (final c in jsonDecode(r['citations_json'] as String) as List)
                StoredCitation.fromJson((c as Map).cast<String, dynamic>()),
            ],
            error: r['error'] as String?,
            created: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
            stats: GenerationStats(
              promptTokens: r['prompt_tokens'] as int,
              generatedTokens: r['generated_tokens'] as int,
              durationMs: r['duration_ms'] as int,
            ),
            inTranscript: (r['in_transcript'] as int) != 0,
          ),
      ];

  /// The conversation exactly as the model saw it (without the system prompt), in order.
  List<Map<String, dynamic>> transcript(int conversationId) => [
        for (final m in messages(conversationId))
          if (m.inTranscript) m.message,
      ];

  /// The opaque numbering state saved by the core (or its stand-in).
  Uint8List? numbering(int id) {
    final rows = _db.select('SELECT numbering FROM conversations WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final v = rows.first['numbering'];
    return v is Uint8List ? v : (v is List<int> ? Uint8List.fromList(v) : null);
  }

  void setNumbering(int id, Uint8List? state) {
    _db.execute('UPDATE conversations SET numbering = ? WHERE id = ?', [state, id]);
  }

  /// Hides a conversation. [undelete] brings it back; [purge] removes it for good.
  void delete(int id) => _db.execute('UPDATE conversations SET deleted = 1 WHERE id = ?', [id]);

  void undelete(int id) => _db.execute('UPDATE conversations SET deleted = 0 WHERE id = ?', [id]);

  void purge(int id) {
    _db.execute('DELETE FROM search_fts WHERE conversation_id = ?', [id]);
    _db.execute('DELETE FROM conversations WHERE id = ? AND deleted = 1', [id]);
  }

  /// Removes everything that was deleted but not undone (at start-up).
  void purgeDeleted() {
    for (final r in _db.select('SELECT id FROM conversations WHERE deleted = 1')) {
      purge(r['id'] as int);
    }
  }

  void deleteAll() {
    _db.execute('DELETE FROM search_fts');
    _db.execute('DELETE FROM conversations');
  }

  /// Full-text search over titles and message text. Each word must match; the last one may be a start of
  /// a word. One hit per conversation, best match first.
  List<SearchHit> search(String query) {
    final match = ftsQuery(query);
    if (match.isEmpty) return const [];
    final ResultSet rows;
    try {
      rows = _db.select(
        'SELECT f.conversation_id AS cid, f.message_id AS mid, '
        "snippet(search_fts, 0, '', '', '…', 14) AS snip, bm25(search_fts) AS rank "
        'FROM search_fts f JOIN conversations c ON c.id = f.conversation_id '
        'WHERE search_fts MATCH ? AND c.deleted = 0 ORDER BY rank',
        [match],
      );
    } on SqliteException {
      return const [];
    }
    final seen = <int>{};
    final hits = <SearchHit>[];
    for (final r in rows) {
      final cid = r['cid'] as int;
      if (!seen.add(cid)) continue;
      final c = get(cid);
      if (c != null) hits.add(SearchHit(c, (r['mid'] as int) == 0 ? '' : (r['snip'] as String)));
    }
    return hits;
  }
}

/// Turns what was typed into an FTS5 query: each word quoted, the last one a prefix. This only escapes
/// text for the database; it does not interpret it.
String ftsQuery(String input) {
  final words = input.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '';
  return [
    for (var i = 0; i < words.length; i++) '"${words[i].replaceAll('"', '""')}"${i == words.length - 1 ? '*' : ''}',
  ].join(' ');
}
