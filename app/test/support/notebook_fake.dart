import 'dart:convert';
import 'dart:io';

import 'package:cache/notebook/notebook_state.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException;

/// cs_notebook in memory, with the core's rules that the screens rely on: a Journal on first use, field ids, most recently used
/// first, last entry and counts without drafts, names unique, deletes. Search is a plain substring match.
class FakeNotebookBackend implements NotebookBackend {
  FakeNotebookBackend({bool journal = true}) {
    if (journal) {
      _save({'template': 'journal', 'def': {'name': 'Journal', 'due_every': null, 'fields': []}, 'map': true});
    }
  }

  final List<Map<String, dynamic>> notebooks = [];
  final List<Map<String, dynamic>> entries = [];
  final List<String> calls = [];
  int _clock = 1000;
  int _ids = 0;

  /// Makes the next call fail with this code.
  String? failNext;

  @override
  Future<Map<String, dynamic>> call(String op, [Map<String, dynamic> args = const {}]) async {
    calls.add(op);
    if (failNext != null) {
      final c = failNext!;
      failNext = null;
      throw CacheSearchException(c, 'failed');
    }
    // A round trip through JSON, as the core's answers are.
    return (jsonDecode(jsonEncode(_run(op, jsonDecode(jsonEncode(args)) as Map<String, dynamic>))) as Map).cast<String, dynamic>();
  }

  Map<String, dynamic> _run(String op, Map<String, dynamic> a) => switch (op) {
        'notebooks' => {'notebooks': [for (final n in _ordered()) _nbJson(n)]},
        'notebook' => _nbJson(_nb(a['id'] as String)),
        'notebook_save' => _nbJson(_save(a)),
        'notebook_delete' => _deleteNb(a['id'] as String),
        'entries' => {'entries': [for (final e in _entriesOf(_nb(a['notebook_id'] as String)['id'] as String)) _entryJson(e)]},
        'entry' => _entryJson(_entry(a['id'] as String)),
        'entry_save' => _entryJson(_saveEntry(a)),
        'entry_delete' => _deleteEntry(a['id'] as String),
        'search' => _search(a),
        'pins' => {
            'entries': [
              for (final e in _byTime(entries))
                if (e['draft'] != true && e['place'] != null && (a['notebook_id'] == null ? _nb(e['notebook_id'] as String)['map'] == true : e['notebook_id'] == a['notebook_id'])) _entryJson(e),
            ],
          },
        _ => throw CacheSearchException('unsupported', 'unknown notebook op $op'),
      };

  Map<String, dynamic> _nb(String id) =>
      notebooks.firstWhere((n) => n['id'] == id, orElse: () => throw CacheSearchException('not_found', 'no notebook with id "$id"'));

  Map<String, dynamic> _entry(String id) =>
      entries.firstWhere((e) => e['id'] == id, orElse: () => throw CacheSearchException('not_found', 'no entry with id "$id"'));

  List<Map<String, dynamic>> _ordered() {
    final l = [...notebooks];
    l.sort((a, b) {
      final ua = a['last_used'] as int?, ub = b['last_used'] as int?;
      if (ua != null && ub != null && ua != ub) return ub.compareTo(ua);
      if (ua != null && ub == null) return -1;
      if (ua == null && ub != null) return 1;
      return (b['created'] as int).compareTo(a['created'] as int);
    });
    return l;
  }

  List<Map<String, dynamic>> _byTime(List<Map<String, dynamic>> l) {
    final out = [...l];
    out.sort((a, b) {
      final c = DateTime.parse(b['occurred_at'] as String).compareTo(DateTime.parse(a['occurred_at'] as String));
      return c != 0 ? c : (b['created'] as int).compareTo(a['created'] as int);
    });
    return out;
  }

  List<Map<String, dynamic>> _entriesOf(String nb) => _byTime([for (final e in entries) if (e['notebook_id'] == nb) e]);

  Map<String, dynamic> _nbJson(Map<String, dynamic> n) {
    final done = [for (final e in _entriesOf(n['id'] as String)) if (e['draft'] != true) e];
    return {
      ...n,
      'entries': done.length,
      'files': done.fold<int>(0, (s, e) => s + (e['files'] as List).length),
      'places': done.where((e) => e['place'] != null).length,
      'last_entry': done.isEmpty ? null : _entryJson(done.first),
    };
  }

  Map<String, dynamic> _entryJson(Map<String, dynamic> e) {
    final n = _nb(e['notebook_id'] as String);
    return {...e, 'private': e['private'] == true || n['private'] == true};
  }

  Map<String, dynamic> _save(Map<String, dynamic> a) {
    final def = (a['def'] as Map).cast<String, dynamic>();
    final name = '${def['name']}'.trim();
    final id = a['id'] as String? ?? 'nb${++_ids}';
    for (final n in notebooks) {
      if (n['id'] != id && '${n['def']['name']}'.toLowerCase() == name.toLowerCase()) {
        throw CacheSearchException('bad_json', 'a notebook named "$name" already exists');
      }
    }
    final old = notebooks.where((n) => n['id'] == id).firstOrNull;
    final oldFields = old == null ? const [] : (old['def']['fields'] as List);
    var next = 0;
    for (final f in oldFields) {
      next = [next, int.parse('${f['fid']}'.substring(1))].reduce((x, y) => x > y ? x : y);
    }
    final fields = <Map<String, dynamic>>[
      for (final f in (def['fields'] as List? ?? const []))
        {...(f as Map).cast<String, dynamic>(), 'fid': f['fid'] ?? 'f${++next}'},
    ];
    for (final f in oldFields) {
      final fid = f['fid'];
      if (fields.any((x) => x['fid'] == fid)) continue;
      if (entries.any((e) => e['notebook_id'] == id && (e['values'] as Map).containsKey(fid))) fields.add({...(f as Map).cast<String, dynamic>(), 'hidden': true});
    }
    final stored = {
      for (final k in const ['id', 'version', 'author', 'group']) if (def[k] != null) k: def[k],
      'name': name,
      'due_every': def['due_every'],
      if (def['shape'] != null) 'shape': def['shape'],
      'fields': fields,
    };
    final now = ++_clock;
    if (old == null) {
      final n = {
        'id': id,
        'template': a['template'],
        'def': stored,
        'private': a['private'] ?? false,
        'map': a['map'] ?? true,
        'template_ref': a['template_ref'],
        'created': now,
        'updated': now,
        'last_used': null,
        'rev': 1,
      };
      notebooks.add(n);
      return n;
    }
    old
      ..['def'] = stored
      ..['template'] = a['template'] ?? old['template']
      ..['private'] = a['private'] ?? old['private']
      ..['map'] = a['map'] ?? old['map']
      ..['updated'] = now
      ..['rev'] = (old['rev'] as int) + 1;
    return old;
  }

  Map<String, dynamic> _deleteNb(String id) {
    _nb(id);
    final n = entries.where((e) => e['notebook_id'] == id).length;
    entries.removeWhere((e) => e['notebook_id'] == id);
    notebooks.removeWhere((x) => x['id'] == id);
    return {'deleted': id, 'entries': n};
  }

  Map<String, dynamic> _saveEntry(Map<String, dynamic> a) {
    final nb = _nb(a['notebook_id'] as String);
    final values = (a['values'] as Map? ?? const {}).cast<String, dynamic>();
    for (final k in values.keys) {
      if (!(nb['def']['fields'] as List).any((f) => f['fid'] == k)) throw CacheSearchException('bad_json', 'the notebook has no field "$k"');
    }
    final id = a['id'] as String? ?? 'e${++_ids}';
    final old = entries.where((e) => e['id'] == id).firstOrNull;
    final now = ++_clock;
    final e = <String, dynamic>{
      'id': id,
      'notebook_id': nb['id'],
      'occurred_at': a['occurred_at'],
      if (a['title'] != null) 'title': a['title'],
      if (a['body'] != null) 'body': a['body'],
      'values': values,
      if (a['place'] != null) 'place': a['place'],
      'photos': a['photos'] ?? const [],
      'files': a['files'] ?? const [],
      'draft': a['draft'] == true,
      'private': a['private'] == true,
      'created': old?['created'] ?? now,
      'updated': now,
      'rev': ((old?['rev'] as int?) ?? 0) + 1,
    };
    if (old != null) entries.remove(old);
    entries.add(e);
    if (e['draft'] != true) nb['last_used'] = now;
    return e;
  }

  Map<String, dynamic> _deleteEntry(String id) {
    entries.remove(_entry(id));
    return {'deleted': id};
  }

  Map<String, dynamic> _search(Map<String, dynamic> a) {
    final q = '${a['query']}'.toLowerCase().trim();
    final hits = <Map<String, dynamic>>[];
    for (final e in _byTime(entries)) {
      if (e['draft'] == true || q.isEmpty) continue;
      if (a['notebook_id'] != null && e['notebook_id'] != a['notebook_id']) continue;
      final nb = _nb(e['notebook_id'] as String);
      final text = [e['title'], e['body'], nb['def']['name'], ...(e['values'] as Map).values].whereType<Object>().join(' ');
      final i = text.toLowerCase().indexOf(q);
      if (i < 0) continue;
      hits.add({'entry': _entryJson(e), 'notebook': nb['def']['name'], 'snippet': '${text.substring(0, i)}\u0002${text.substring(i, i + q.length)}\u0003${text.substring(i + q.length)}'});
    }
    return {'hits': hits};
  }
}

/// A NotebookState on the fake, with a media folder in the system temp folder.
NotebookState fakeNotebook(FakeNotebookBackend backend) =>
    NotebookState(backend: backend, mediaDir: () async => Directory('${Directory.systemTemp.path}/cache-notebook-test-media'));
