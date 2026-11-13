import 'dart:convert';
import 'dart:io';

import '../../../packages/cache_search/lib/src/errors.dart';
import 'line_protocol.dart';

/// The `history.*` ops: the Ask conversations of Cache for Linux, kept on the server so every tab and browser sees the same list.
/// The phone keeps them in SQLite; the helper has no SQLite package, so each conversation is one JSON file,
/// `<history dir>/c<id>.json` (the browser's folder is `<support>/history`), written atomically. A purged id goes in
/// `tombstones.json`, so a tab that syncs later learns it is gone. Messages are kept as the browser sent them (the model's own
/// message map, citations and navigation actions stay opaque JSON here).
///
/// Every change gives the conversation the next `rev` (one counter for the whole store), so `history.sync` can send only what
/// changed. All ops are idempotent, so the browser may repeat one after a failure. Ids come from the browser (time based).
///
/// Ops (args by name):
///   history.sync {since} -> {rev, conversations:[row], gone:[id]}   rows with rev > since, full, with their messages
///   history.create {conversation:{id,title,titleSource,created,updated,pinned,model,voice}} -> null   (an id that exists is left)
///   history.update {id, fields:{title,titleSource,pinned,model,updated,numbering(base64|null),deleted}} -> bool
///   history.addMessage {id, message:{id,role,content,message,citations,error,created,promptTokens,generatedTokens,durationMs,
///       inTranscript,navigationActions}, updated, model?} -> bool   (a message id that exists is left)
///   history.setNavigationActions {id, messageId, actions} -> bool
///   history.removeMessage {id, messageId} -> bool    only a row the model never saw (an action draft)
///   history.purge {id} -> bool                       only a deleted conversation (the phone's rule)
///   history.purgeDeleted {olderThanMs?} -> int       deleted for at least that long
///   history.deleteAll {} -> int
class HistoryOps implements OpHandler {
  HistoryOps(this.dir, {DateTime Function()? now, void Function(String message)? log, void Function(File file)? deleteFile})
      : _now = now ?? DateTime.now,
        _delete = deleteFile ?? ((f) => f.deleteSync()),
        _log = log ?? ((m) => stderr.writeln('cache_core_helper: $m')) {
    _load();
  }

  final Directory dir;
  final void Function(String message) _log;
  final void Function(File file) _delete; // tests may make a delete fail
  final DateTime Function() _now;

  final Map<int, Map<String, dynamic>> _convs = {};
  List<Map<String, dynamic>> _tombs = [];
  int _rev = 0;

  static const int _maxTombs = 2000;
  static const Set<String> _fields = {'title', 'titleSource', 'pinned', 'model', 'updated', 'numbering', 'deleted'};

  File _file(int id) => File('${dir.path}/c$id.json');

  void _load() {
    try {
      if (!dir.existsSync()) return;
      for (final f in dir.listSync().whereType<File>()) {
        final n = f.uri.pathSegments.last;
        if (n == 'tombstones.json') {
          try {
            for (final t in jsonDecode(f.readAsStringSync()) as List) {
              // One bad tombstone is skipped; the rest still count (its id has no rev to keep).
              try {
                final m = (t as Map).cast<String, dynamic>();
                _id(m['id'], 'id');
                final r = (m['rev'] as num).toInt();
                _tombs.add(m);
                _rev = _rev > r ? _rev : r;
              } catch (e) {
                _log('history: skipped a tombstone: $e');
              }
            }
          } catch (e) {
            _log('history: cannot read tombstones.json: $e');
          }
          continue;
        }
        if (!n.startsWith('c') || !n.endsWith('.json')) continue;
        try {
          final c = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
          final id = (c['id'] as num).toInt();
          final rev = (c['rev'] as num).toInt(); // inside the guard: a file with no numeric rev is skipped, never stops the helper
          if (c['messages'] is! List) throw const FormatException('no messages list');
          _convs[id] = c;
          _rev = _rev > rev ? _rev : rev;
        } catch (e) {
          _log('history: skipped $n: $e');
        }
      }
    } catch (e) {
      _log('history: cannot read ${dir.path}: $e');
    }
    // A tombstone says the conversation was purged for good: a file that is still there (its delete failed) goes now.
    for (final t in _tombs) {
      final id = (t['id'] as num).toInt();
      final f = _file(id);
      try {
        if (f.existsSync()) {
          _delete(f);
          _log('history: removed c$id.json, which a tombstone says was purged');
        }
      } catch (e) {
        _log('history: cannot remove c$id.json (purged): $e');
      }
      _convs.remove(id);
    }
  }

  void _write(File f, Object json) {
    try {
      dir.createSync(recursive: true);
      final tmp = File('${f.path}.$pid.tmp');
      tmp.writeAsStringSync(jsonEncode(json), flush: true);
      tmp.renameSync(f.path);
    } catch (e) {
      throw CacheSearchException('io_error', 'History could not be saved: $e');
    }
  }

  void _save(Map<String, dynamic> c) {
    c['rev'] = ++_rev;
    _write(_file((c['id'] as num).toInt()), c);
  }

  void _saveTombs() => _write(File('${dir.path}/tombstones.json'), _tombs);

  static int _id(Object? v, String what) {
    if (v is num) return v.toInt();
    throw CacheSearchException('bad_args', '"$what" must be a number');
  }

  /// The types the client reads (`_apply`); anything else is refused so one bad write cannot stop every tab's sync.
  static void _checkField(String key, Object? v) {
    final ok = switch (key) {
      'title' || 'titleSource' || 'model' => v is String,
      'updated' => v is num,
      'pinned' || 'deleted' => v is bool,
      'numbering' => v == null || v is String,
      _ => true,
    };
    if (!ok) throw CacheSearchException('bad_args', '"$key" has the wrong type');
  }

  static void _checkMessage(Map m) {
    bool str(String k) => m[k] is String;
    bool num_(String k) => m[k] == null || m[k] is num;
    if (!str('role') || !str('content') || m['message'] is! Map || !(m['citations'] == null || m['citations'] is List) ||
        !(m['error'] == null || m['error'] is String) || !(m['inTranscript'] == null || m['inTranscript'] is bool) ||
        !(m['navigationActions'] == null || m['navigationActions'] is List) ||
        !num_('created') || !num_('promptTokens') || !num_('generatedTokens') || !num_('durationMs')) {
      throw const CacheSearchException('bad_args', 'The message has a field of the wrong type');
    }
  }

  Map<String, dynamic>? _conv(Object? id) => _convs[_id(id, 'id')];

  @override
  bool handles(String op) => op.startsWith('history.');

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    switch (op) {
      case 'history.sync':
        final since = a['since'] is num ? (a['since'] as num).toInt() : 0;
        return {
          'rev': _rev,
          'conversations': [for (final c in _convs.values) if ((c['rev'] as num).toInt() > since) c],
          'gone': [for (final t in _tombs) if ((t['rev'] as num).toInt() > since) t['id']],
        };
      case 'history.create':
        final c = a['conversation'];
        if (c is! Map) throw const CacheSearchException('bad_args', 'history.create needs a "conversation"');
        final id = _id(c['id'], 'conversation.id');
        if (_convs.containsKey(id)) return null;
        final row = <String, dynamic>{
          'id': id,
          'title': c['title'] is String ? c['title'] : '',
          'titleSource': c['titleSource'] is String ? c['titleSource'] : 'question',
          'created': c['created'] is num ? c['created'] : _now().millisecondsSinceEpoch,
          'updated': c['updated'] is num ? c['updated'] : _now().millisecondsSinceEpoch,
          'pinned': c['pinned'] == true,
          'model': c['model'] is String ? c['model'] : '',
          'voice': c['voice'] == true,
          'deleted': false,
          'numbering': null,
          'messages': <Map<String, dynamic>>[],
        };
        _convs[id] = row;
        _save(row);
        return null;
      case 'history.update':
        final c = _conv(a['id']);
        final f = a['fields'];
        if (c == null || f is! Map) return false;
        for (final e in f.entries) {
          if (_fields.contains(e.key)) _checkField(e.key as String, e.value);
        }
        for (final e in f.entries) {
          if (!_fields.contains(e.key)) continue;
          c[e.key as String] = e.value;
          if (e.key == 'deleted') c['deletedAt'] = e.value == true ? _now().millisecondsSinceEpoch : null;
        }
        _save(c);
        return true;
      case 'history.addMessage':
        final c = _conv(a['id']);
        final m = a['message'];
        if (c == null || m is! Map) return false;
        final mid = _id(m['id'], 'message.id');
        _checkMessage(m);
        final list = c['messages'] as List;
        if (list.any((x) => (x as Map)['id'] == mid)) return false;
        list.add(m.cast<String, dynamic>());
        if (a['updated'] is num) c['updated'] = a['updated'];
        if (a['model'] is String) c['model'] = a['model'];
        _save(c);
        return true;
      case 'history.setNavigationActions':
        final c = _conv(a['id']);
        final mid = a['messageId'];
        if (c == null) return false;
        for (final x in c['messages'] as List) {
          if ((x as Map)['id'] == mid) {
            x['navigationActions'] = a['actions'] is List ? a['actions'] : const [];
            _save(c);
            return true;
          }
        }
        return false;
      case 'history.removeMessage':
        final c = _conv(a['id']);
        if (c == null) return false;
        final list = c['messages'] as List;
        final before = list.length;
        list.removeWhere((x) => (x as Map)['id'] == a['messageId'] && x['inTranscript'] == false);
        if (list.length == before) return false;
        _save(c);
        return true;
      case 'history.purge':
        final id = _id(a['id'], 'id');
        final c = _convs[id];
        if (c == null || c['deleted'] != true) return false;
        _drop(id);
        _saveTombs();
        return true;
      case 'history.purgeDeleted':
        final older = a['olderThanMs'] is num ? (a['olderThanMs'] as num).toInt() : 0;
        final cutoff = _now().millisecondsSinceEpoch - older;
        final ids = [
          for (final c in _convs.values)
            if (c['deleted'] == true && ((c['deletedAt'] as num?)?.toInt() ?? 0) <= cutoff) (c['id'] as num).toInt(),
        ];
        for (final id in ids) {
          _drop(id);
        }
        if (ids.isNotEmpty) _saveTombs();
        return ids.length;
      case 'history.deleteAll':
        final ids = _convs.keys.toList();
        for (final id in ids) {
          _drop(id);
        }
        if (ids.isNotEmpty) _saveTombs();
        return ids.length;
      default:
        throw CacheSearchException('bad_op', 'No such op: $op');
    }
  }

  void _drop(int id) {
    _convs.remove(id);
    try {
      final f = _file(id);
      if (f.existsSync()) _delete(f);
    } catch (e) {
      _log('history: cannot delete c$id.json (a tombstone is saved; it is retried at the next start): $e');
    }
    _tombs.add({'id': id, 'rev': ++_rev});
    if (_tombs.length > _maxTombs) _tombs = _tombs.sublist(_tombs.length - _maxTombs);
  }
}
