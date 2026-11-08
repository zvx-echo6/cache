import 'dart:convert';
import 'dart:io';

import 'package:cache/library/cds_shelf_source.dart' show readPackHeaderLine;
import 'package:cache/library/shelves_calls.dart';

/// A stand-in for the core's Bookshelves calls in the app's tests (the app tests have no native library). It writes and reads
/// real log files in the Bookshelves folder, so the app's writes are checked as lines, and resolves them by a short form of
/// server/builder/LIBRARY-LOG.md "Resolution" (groups by the latest same/notsame of a pair with the person's outranking the
/// detector's, held numbers, the earliest held number in the shelf's division, clash ranks by (at, copy), next free). The core's
/// own resolution, the weakest-link split and the import's details are tested in packages/cache_shelves and through the C ABI in
/// packages/cache_search/native/cache_search/tests/shelves_ffi.rs; this is only what the app needs to see its writes come back.
/// Detection: the same content hash, or the same `minhash` (a stand-in for the core's text match).
class FakeShelvesCalls implements ShelvesCalls {
  FakeShelvesCalls({this.now = 9000});

  int now;

  /// When set, resolve answers this view as it is.
  Map<String, dynamic>? canned;

  /// Every event appended, as written (with v, at and dev).
  final List<Map<String, dynamic>> appended = [];

  /// The copies detection was run for, in order.
  final List<String> detected = [];
  int imports = 0;
  int importedEvents = 0;
  int resolves = 0;

  static const _known = {'place', 'unsort', 'assign', 'retire', 'title', 'remove', 'restore', 'same', 'notsame', 'prefer', 'facts'};

  @override
  Future<List<Map<String, dynamic>>> detect(Map<String, dynamic> args) async {
    final c = (args['copy'] as Map).cast<String, dynamic>();
    detected.add(c['copy'] as String);
    return [
      for (final o in (args['against'] as List).cast<Map>())
        if (o['copy'] != c['copy'])
          if (c['blake3'] != null && o['blake3'] == c['blake3'])
            {'with': o['copy'], 'how': 'blake3', 'score': 1.0}
          else if (c['minhash'] != null && jsonEncode(o['minhash']) == jsonEncode(c['minhash']))
            {'with': o['copy'], 'how': 'text', 'score': 0.9},
    ];
  }

  @override
  Future<Map<String, dynamic>> append(Map<String, dynamic> args) async {
    final dev = args['dev'] as String;
    final lines = <Map<String, dynamic>>[];
    for (final e in (args['events'] as List).cast<Map>()) {
      final m = <String, dynamic>{'v': 1, 'at': e['at'] ?? now, 'dev': dev, ...e.cast<String, dynamic>()};
      if (!_known.contains(m['ev']) || m['copy'] is! String || (m['ev'] == 'same' || m['ev'] == 'notsame') && m['copy'] == m['with']) {
        throw StateError('not a Bookshelves event: $m');
      }
      lines.add(m);
    }
    _write(args['dir'] as String, dev, lines);
    appended.addAll(lines);
    return {'written': lines.length, 'last_at': lines.isEmpty ? null : lines.last['at']};
  }

  static void _write(String dir, String dev, List<Map<String, dynamic>> lines) {
    final f = File('$dir/log/$dev.jsonl')..parent.createSync(recursive: true);
    f.writeAsStringSync(lines.map((l) => '${jsonEncode(l)}\n').join(), mode: FileMode.append, flush: true);
  }

  /// A library's live packs: doc id -> its header.
  static Map<String, Map<String, dynamic>> _packs(Map lib) {
    final dir = Directory('${lib['packs_dir'] ?? '${lib['dir']}/packs'}');
    final best = <String, (int, File)>{};
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final m = RegExp(r'^(.+)@(\d+)\.cdoc$').firstMatch(f.uri.pathSegments.last);
        if (m == null) continue;
        final v = int.parse(m.group(2)!);
        if ((best[m.group(1)!]?.$1 ?? -1) < v) best[m.group(1)!] = (v, f);
      }
    }
    return {
      for (final e in best.entries)
        if (readPackHeaderLine(e.value.$2) case final line?) e.key: (jsonDecode(line) as Map).cast<String, dynamic>(),
    };
  }

  static String _copyOf(Map<String, dynamic> h) => ((h['book'] as Map?)?['original_blake3'] as String?) ?? h['doc_id'] as String;

  static List<Map<String, dynamic>> _lines(File f) => [
        for (final l in f.readAsLinesSync())
          if (l.trim().isNotEmpty)
            if (jsonDecode(l) case final Map m) m.cast<String, dynamic>(),
      ];

  @override
  Future<Map<String, dynamic>> import(Map<String, dynamic> args) async {
    imports++;
    final dir = args['dir'] as String, dev = args['dev'] as String;
    final record = File('$dir/.local/migrated.json');
    final done = record.existsSync() ? ((jsonDecode(record.readAsStringSync()) as Map)['files'] as Map).cast<String, dynamic>() : <String, dynamic>{};
    var n = 0;
    for (final lib in (args['libraries'] as List).cast<Map>()) {
      final key = '${lib['library_id']}/$dev.jsonl';
      final f = File('${lib['dir']}/log/$dev.jsonl');
      if (done.containsKey(key) || !f.existsSync()) continue;
      final packs = _packs(lib);
      final out = [
        for (final e in _lines(f))
          if (packs[e['doc']] case final h?)
            {for (final k in e.keys) if (k != 'doc') k: e[k], 'copy': _copyOf(h), 'loc': '${lib['library_id']}/${e['doc']}'},
      ];
      _write(dir, dev, out);
      n += out.length;
      done[key] = {'size': f.lengthSync(), 'events': out.length, 'unmapped': 0};
    }
    record
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'format': 1, 'files': done}));
    importedEvents += n;
    return {'events': n, 'files': const []};
  }

  @override
  Future<Map<String, dynamic>> resolve(Map<String, dynamic> args) async {
    resolves++;
    if (canned != null) return canned!;
    final dir = args['dir'] as String;
    // the libraries' copies
    final copies = <String, ({List<String> locs, String title, String? suggested, String? seedPlace, String? seedTitle})>{};
    for (final lib in (args['libraries'] as List).cast<Map>()) {
      final seedPlace = <String, String>{}, seedTitle = <String, String>{};
      final logs = Directory('${lib['dir']}/log');
      if (logs.existsSync()) {
        for (final f in logs.listSync().whereType<File>().where((f) => f.uri.pathSegments.last.startsWith('builder-'))) {
          for (final e in _lines(f)) {
            if (e['ev'] == 'place') seedPlace[e['doc'] as String] = e['div'] as String;
            if (e['ev'] == 'title') seedTitle[e['doc'] as String] = e['title'] as String;
          }
        }
      }
      for (final e in _packs(lib).entries) {
        final h = e.value;
        final c = _copyOf(h);
        final book = (h['book'] as Map?)?.cast<String, dynamic>();
        final prev = copies[c];
        copies[c] = (
          locs: [...?prev?.locs, '${lib['library_id']}/${e.key}'],
          title: prev?.title ?? (book?['title'] as String? ?? h['title'] as String? ?? e.key),
          suggested: prev?.suggested ?? (book?['suggested'] as Map?)?['div'] as String?,
          seedPlace: prev?.seedPlace ?? seedPlace[e.key],
          seedTitle: prev?.seedTitle ?? seedTitle[e.key],
        );
      }
    }
    // every event, in (at, dev, position) order
    final events = <(int, String, int, Map<String, dynamic>)>[];
    final logDir = Directory('$dir/log');
    final logSizes = <String, int>{};
    if (logDir.existsSync()) {
      for (final f in logDir.listSync().whereType<File>()) {
        logSizes[f.uri.pathSegments.last] = f.lengthSync();
        var i = 0;
        for (final e in _lines(f)) {
          events.add(((e['at'] as num).toInt(), e['dev'] as String, i++, e));
        }
      }
    }
    events.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : (a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3)));
    // groups
    final pairs = <String, (bool, bool)>{};
    final parent = <String, String>{for (final c in copies.keys) c: c};
    String find(String x) {
      parent.putIfAbsent(x, () => x);
      while (parent[x] != x) {
        x = parent[x]!;
      }
      return x;
    }

    for (final (_, _, _, e) in events) {
      if (e['ev'] != 'same' && e['ev'] != 'notsame') continue;
      final k = ([e['copy'] as String, e['with'] as String]..sort()).join('|');
      final user = e['by'] == 'user';
      if ((pairs[k]?.$2 ?? false) && !user) continue;
      pairs[k] = (e['ev'] == 'same', user);
    }
    for (final e in pairs.entries) {
      final ab = e.key.split('|');
      find(ab[0]);
      find(ab[1]);
      if (e.value.$1) parent[find(ab[0])] = find(ab[1]);
    }
    // numbers
    final held = <String, (String, int, int)>{};
    final claims = <(String, int), Map<String, int>>{};
    final next = <String, int>{};
    final retired = <String, Set<int>>{};
    for (final (at, _, _, e) in events) {
      final c = e['copy'] as String?;
      if (c == null) continue;
      if (e['ev'] == 'assign' || e['ev'] == 'retire') {
        final div = e['div'] as String, seq = (e['seq'] as num).toInt();
        next[div] = (next[div] ?? 1) > seq + 1 ? next[div]! : seq + 1;
        if (e['ev'] == 'assign') {
          held[c] = (div, seq, at);
          claims.putIfAbsent((div, seq), () => {}).putIfAbsent(c, () => at);
        } else {
          retired.putIfAbsent(div, () => {}).add(seq);
          if (held[c] case final h? when h.$1 == div && h.$2 == seq) held.remove(c);
        }
      }
    }
    int suffix(String div, int seq, String copy) {
      final ranked = claims[(div, seq)]!.entries.toList()..sort((a, b) => a.value != b.value ? a.value.compareTo(b.value) : a.key.compareTo(b.key));
      return ranked.indexWhere((x) => x.key == copy);
    }

    Map<String, dynamic>? callOf(String copy, (String, int, int)? h) {
      if (h == null) return null;
      final s = suffix(h.$1, h.$2, copy);
      final n = h.$2.toString().padLeft(3, '0');
      return {'div': h.$1, 'seq': h.$2, 'suffix': s, 'text': s > 0 ? 'CDS ${h.$1}-$n.$s' : 'CDS ${h.$1}-$n'};
    }

    final groups = <String, List<String>>{};
    for (final c in parent.keys.toList()) {
      groups.putIfAbsent(find(c), () => []).add(c);
    }
    final books = <String, dynamic>{};
    for (final g in groups.values) {
      if (!g.any(copies.containsKey)) continue;
      g.sort();
      final inG = g.toSet();
      String? shelf, by, title, prefer;
      var shelved = false, removed = false;
      for (final (_, _, _, e) in events) {
        if (!inG.contains(e['copy'])) continue;
        switch (e['ev']) {
          case 'place':
            (shelf, by, shelved) = (e['div'] as String, e['by'] as String, true);
          case 'unsort':
            (shelf, by, shelved) = (null, e['by'] as String, true);
          case 'title':
            title = e['title'] as String;
          case 'remove':
            removed = true;
          case 'restore':
            removed = false;
          case 'prefer' when copies.containsKey(e['copy']):
            prefer = e['copy'] as String;
        }
      }
      final reading = prefer ?? g.firstWhere(copies.containsKey);
      final r = copies[reading]!;
      final shown = title ?? r.seedTitle ?? r.title;
      final held0 = [for (final c in g) if (held[c] case final h? when h.$1 == shelf) (c, h)]
        ..sort((a, b) => a.$2.$3 != b.$2.$3 ? a.$2.$3.compareTo(b.$2.$3) : a.$1.compareTo(b.$1));
      final sug = r.seedPlace ?? r.suggested;
      books[g.first] = {
        'title': shown,
        'title_from': title != null ? 'log' : (r.seedTitle != null ? 'seed' : 'pack'),
        'aka': {for (final c in g) if (copies[c] case final x? when x.title != shown) x.title}.toList(),
        'reading': reading,
        'copies': [
          for (final c in g)
            {'copy': c, 'locs': copies[c]?.locs ?? const [], 'available': copies.containsKey(c), 'title': copies[c]?.title, 'own_call': callOf(c, held[c]), 'locations': const []},
        ],
        'shelf': shelf,
        'shelved': shelved,
        'by': by,
        'call': held0.isEmpty ? null : callOf(held0.first.$1, held0.first.$2),
        'removed': removed,
        'author': null,
        'edition': null,
        'year': null,
        'suggested': sug == null ? null : {'div': sug, 'label': null, 'from': r.seedPlace != null ? 'seed' : 'pack'},
      };
    }
    return {
      'format': 1,
      'built_from': {'libraries': {}, 'logs': logSizes},
      'books': books,
      'retired': {for (final e in retired.entries) e.key: (e.value.toList()..sort())},
      'next': next,
      'folders': const [],
    };
  }
}
