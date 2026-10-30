import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../files.dart';
import '../notebook_model.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'formats.dart';
import 'merge.dart';

/// Where notebooks are kept outside Cache:
/// - [obsidian]: one Markdown file per entry, two-way;
/// - [logseq]: one block per entry on its day's journal page of a classic (file-based) Logseq graph, two-way;
/// - [logseqExport]: the same blocks for Logseq 2.x, which imports Markdown: written, never read back;
/// - [share]: Cache's own folder that notebook sync keeps the same on the linked devices, two-way, in the Obsidian format.
enum SyncKind { obsidian, logseq, logseqExport, share }

/// What needs a person's decision.
enum ConflictKind { bothChanged, removedOutside, unreadable }

class SyncConflict {
  const SyncConflict({required this.entryId, required this.kind, required this.title, required this.path, this.cacheText, this.fileText});

  final String entryId;
  final ConflictKind kind;
  final String title;
  final String path;
  final String? cacheText;
  final String? fileText;

  Map<String, dynamic> toJson() => {'entry': entryId, 'kind': kind.name, 'title': title, 'path': path, 'cache': ?cacheText, 'file': ?fileText};

  static SyncConflict fromJson(Map j) => SyncConflict(
        entryId: '${j['entry']}',
        kind: ConflictKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ConflictKind.bothChanged),
        title: '${j['title'] ?? ''}',
        path: '${j['path'] ?? ''}',
        cacheText: j['cache'] as String?,
        fileText: j['file'] as String?,
      );
}

/// What one run did.
class SyncReport {
  int written = 0;
  int read = 0;
  int deleted = 0;

  /// Entries changed in both places whose changes were merged (the person is told, not asked).
  final List<String> merged = [];
  int conflicts = 0;
}

/// One entry's state at the last sync: where it is, the text it had there, and the entry's rev then.
class _Item {
  _Item(this.path, this.base, this.rev, {this.extra = const []});

  String path;
  String base;
  int rev;
  List<String> extra;

  Map<String, dynamic> toJson() => {'path': path, 'base': base, 'rev': rev, if (extra.isNotEmpty) 'extra': extra};

  static _Item fromJson(Map j) => _Item('${j['path']}', '${j['base']}', (j['rev'] as num?)?.toInt() ?? 0, extra: [for (final l in (j['extra'] as List? ?? const [])) '$l']);
}

/// One entry as the folder has it now.
class _Unit {
  _Unit(this.path, this.text, this.doc);

  final String path;
  final String text;
  final EntryDoc doc;
}

/// The two-way sync of the notebooks with one folder, with the rules of the notebook spec (5.4, 6.3): what changed on one side
/// since the last sync goes to the other; changed on both sides, the changes are merged word by word and the person is told;
/// only when both changed the same words is the person asked. Cache creates, changes or deletes only files and blocks that
/// carry its `cache_id` and the photos it wrote.
class NotebookSync {
  NotebookSync({
    required this.notebook,
    required this.kind,
    required this.folder,
    required this.stateFile,
    this.includePrivate = true,
    this.privateBooks = const {},
    this.logseqConfig,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final NotebookState notebook;
  final SyncKind kind;
  final SyncFolder folder;
  final File stateFile;

  /// Private items go to the folder (Obsidian and Logseq: yes; notebook sync: only when the person chose to include them).
  final bool includePrivate;

  /// Private notebooks that go to the folder anyway (their "Include in sync and sharing").
  final Set<String> privateBooks;

  /// A Logseq graph's `logseq/config.edn` (read once when it is connected).
  final ({String format, String dir, bool org})? logseqConfig;
  final DateTime Function() _now;

  Map<String, _Item> _items = {};
  Map<String, Map<String, String>> _props = {};
  List<SyncConflict> _conflicts = [];
  final Set<String> _ignored = {};

  List<SyncConflict> get conflicts => List.unmodifiable(_conflicts);

  bool get _logseq => kind == SyncKind.logseq || kind == SyncKind.logseqExport;
  String get _attachments => _logseq ? 'assets' : (kind == SyncKind.share ? 'photos' : 'attachments');
  String get _journals => logseqConfig?.dir ?? 'journals';
  String get _format => logseqConfig?.format ?? 'yyyy_MM_dd';

  // ---- state ----

  Future<void> _load() async {
    try {
      if (!await stateFile.exists()) return;
      final j = jsonDecode(await stateFile.readAsString()) as Map;
      _items = {for (final e in (j['items'] as Map? ?? const {}).entries) '${e.key}': _Item.fromJson(e.value as Map)};
      _props = {for (final e in (j['props'] as Map? ?? const {}).entries) '${e.key}': (e.value as Map).cast<String, String>()};
      _conflicts = [for (final c in (j['conflicts'] as List? ?? const [])) SyncConflict.fromJson(c as Map)];
      _ignored
        ..clear()
        ..addAll([for (final x in (j['ignored'] as List? ?? const [])) '$x']);
    } catch (e) {
      debugPrint('cache notebook sync: state unreadable ($e)');
    }
  }

  Future<void> _save() async {
    await stateFile.parent.create(recursive: true);
    await writeStringAtomic(
      stateFile,
      jsonEncode({
        'items': {for (final e in _items.entries) e.key: e.value.toJson()},
        'props': _props,
        'conflicts': [for (final c in _conflicts) c.toJson()],
        'ignored': [..._ignored],
      }),
    );
  }

  // ---- entries as documents ----

  /// The field property names of a notebook: fixed per field id the first time a field is written (a label rename keeps
  /// the name, so old files stay readable).
  Map<String, String> _fieldProps(Notebook n) {
    final m = _props.putIfAbsent(n.id, () => {});
    for (final f in n.def.fields) {
      final fid = f.fid;
      if (fid == null || m.containsKey(fid)) continue;
      m[fid] = propName(f.label, taken: m.values);
    }
    return m;
  }

  Map<String, FieldType> _propTypes(Notebook n) {
    final m = _fieldProps(n);
    return {for (final f in n.def.fields) if (f.fid != null && m[f.fid] != null) m[f.fid]!: f.type};
  }

  EntryDoc _docOf(Notebook n, NbEntry e) {
    final m = _fieldProps(n);
    return EntryDoc(
      id: e.id,
      notebook: n.name,
      when: wallTime(e.occurredAt),
      title: e.title,
      body: e.body ?? '',
      place: e.place == null ? null : NbPlace(lat: e.place!.lat, lon: e.place!.lon, label: e.place!.label),
      photos: [for (final p in e.photos) p.id],
      fields: {for (final f in n.def.fields) if (f.fid != null && e.values.containsKey(f.fid) && m[f.fid] != null) m[f.fid]!: e.values[f.fid]},
      private: e.private,
      extra: _items[e.id]?.extra ?? const [],
    );
  }

  String _render(EntryDoc d) => _logseq ? renderLogseq(d) : renderObsidian(d);

  bool _included(Notebook n, NbEntry e) => !e.draft && (includePrivate || !e.private || privateBooks.contains(n.id));

  // ---- the folder ----

  Future<Map<String, _Unit>> _scan(Map<String, Notebook> byName, List<_Unit> newOutside, List<SyncConflict> unreadable) async {
    final out = <String, _Unit>{};
    if (kind == SyncKind.logseqExport) return out;
    if (_logseq) {
      for (final dir in [_journals, 'pages']) {
        for (final f in await folder.list(dir)) {
          if (!f.path.endsWith('.md')) continue;
          final text = await folder.readText(f.path);
          if (text == null) continue;
          final day = dayOfJournal(f.path.split('/').last, format: _format);
          for (final b in splitPage(text).blocks) {
            final id = b.cacheId;
            final nbName = RegExp(r'^\s+notebook::\s*(.+)$', multiLine: true).firstMatch(b.text)?.group(1)?.trim();
            final book = nbName == null ? null : byName[nbName.replaceAll('"', '')];
            if (id == null && book == null) continue; // the person's own blocks
            final doc = parseLogseq(b, day: day ?? _now().toIso8601String().substring(0, 10), fallbackNotebook: book?.name ?? nbName ?? '', fieldProps: book == null ? const {} : _propTypes(book));
            final u = _Unit(f.path, b.text, doc);
            if (id == null) {
              newOutside.add(u);
            } else if (!out.containsKey(id)) {
              out[id] = u;
            }
          }
        }
      }
      return out;
    }
    for (final f in await folder.list('')) {
      if (!f.path.endsWith('.md') || f.path.startsWith('Conflicts/') || f.path.startsWith('.cache/')) continue;
      final text = await folder.readText(f.path);
      if (text == null) continue;
      final folderName = f.path.contains('/') ? f.path.substring(0, f.path.indexOf('/')) : '';
      final book = byName.values.where((n) => folderNameOf(n) == folderName).firstOrNull;
      final probe = parseObsidian(text, fallbackId: '', fallbackNotebook: book?.name ?? '', fieldProps: const {});
      if (probe == null) {
        final known = _items.entries.where((e) => e.value.path == f.path).firstOrNull;
        if (!_ignored.contains(f.path)) {
          unreadable.add(SyncConflict(entryId: known?.key ?? '', kind: ConflictKind.unreadable, title: f.path.split('/').last, path: f.path));
        }
        continue;
      }
      final owner = byName[probe.notebook] ?? book;
      final doc = parseObsidian(text, fallbackId: '', fallbackNotebook: owner?.name ?? '', fieldProps: owner == null ? const {} : _propTypes(owner))!;
      final u = _Unit(f.path, text, doc);
      if (doc.id.isEmpty) {
        if (owner != null) newOutside.add(u);
        continue;
      }
      final prev = out[doc.id];
      if (prev == null) {
        out[doc.id] = u;
      } else {
        // A duplicated file: the one Cache knows keeps the id; the other becomes a new entry.
        final keep = _items[doc.id]?.path == prev.path ? prev : u;
        final other = identical(keep, prev) ? u : prev;
        out[doc.id] = keep;
        newOutside.add(_Unit(other.path, other.text, EntryDoc(id: '', notebook: other.doc.notebook, when: other.doc.when, title: other.doc.title, body: other.doc.body, place: other.doc.place, photos: other.doc.photos, fields: other.doc.fields, private: other.doc.private, extra: other.doc.extra)));
      }
    }
    return out;
  }

  static String folderNameOf(Notebook n) => folderName(n.name);

  Future<String> _newPath(EntryDoc d, Notebook n) async {
    final dir = folderNameOf(n);
    final base = noteFileName(d);
    var name = '$dir/$base.md';
    var i = 2;
    while (await folder.exists(name) || _items.values.any((x) => x.path == name)) {
      name = '$dir/$base ${i++}.md';
    }
    return name;
  }

  Future<void> _copyPhotosOut(EntryDoc d) async {
    final ids = [...d.photos, for (final v in d.fields.values) if (v is List) ...v.whereType<String>()];
    for (final id in ids) {
      final path = '$_attachments/cache-$id.jpg';
      if (await folder.exists(path)) continue;
      final f = await notebook.photoFile(id);
      if (await f.exists()) await folder.writeBytes(path, await f.readAsBytes());
    }
  }

  /// Writes [text] as entry [id]'s file or block; returns where it is.
  Future<String> _write(String id, EntryDoc d, Notebook n, String text) async {
    await _copyPhotosOut(d);
    if (!_logseq) {
      final path = _items[id]?.path ?? await _newPath(d, n);
      await folder.writeText(path, text);
      return path;
    }
    final page = '$_journals/${journalFileName(d.when.substring(0, 10), format: _format)}';
    final old = _items[id]?.path;
    if (old != null && old != page) await _removeBlock(old, id);
    final cur = await folder.readText(page) ?? '';
    final p = splitPage(cur);
    final at = p.blocks.indexWhere((b) => b.cacheId == id);
    final String next;
    if (at >= 0) {
      next = p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? text : p.blocks[i].text].join();
    } else {
      final sep = cur.isEmpty || cur.endsWith('\n') ? '' : '\n';
      next = '$cur$sep$text';
    }
    await folder.writeText(page, next);
    return page;
  }

  Future<void> _removeBlock(String page, String id) async {
    final cur = await folder.readText(page);
    if (cur == null) return;
    final p = splitPage(cur);
    if (!p.blocks.any((b) => b.cacheId == id)) return;
    await folder.writeText(page, p.head + [for (final b in p.blocks) if (b.cacheId != id) b.text].join());
  }

  Future<void> _deleteOutside(String id) async {
    final it = _items[id];
    if (it == null) return;
    if (_logseq) {
      await _removeBlock(it.path, id);
    } else {
      await folder.delete(it.path);
    }
  }

  /// Keeps the version not chosen in a conflict: `Conflicts/` (Obsidian), `pages/Cache conflicts.md` (Logseq).
  Future<void> _keepCopy(String title, String text) async {
    final stamp = _now().toIso8601String();
    if (_logseq) {
      const page = 'pages/Cache conflicts.md';
      final cur = await folder.readText(page) ?? '';
      final body = text.split('\n').where((l) => l.trim().isNotEmpty).map((l) => '\t$l').join('\n');
      await folder.writeText(page, '$cur${cur.isEmpty || cur.endsWith('\n') ? '' : '\n'}- ${stamp.substring(0, 16).replaceFirst('T', ' ')} $title\n$body\n');
      return;
    }
    final name = '${stamp.substring(0, 10)} ${stamp.substring(11, 13)}${stamp.substring(14, 16)} $title'.replaceAll(RegExp(r'[#|^:%\[\]/\\?*"<>]'), ' ').trim();
    await folder.writeText('Conflicts/$name.md', text);
  }

  // ---- reading into Cache ----

  Future<Notebook> _bookFor(EntryDoc d, Map<String, Notebook> byName) async {
    final have = byName[d.notebook];
    if (have != null) return have;
    final shared = await _sharedBook(d.notebook);
    final made = await notebook.saveNotebook(
      id: shared?['id'] as String?,
      template: (shared?['template'] as String?) ?? 'notes',
      def: shared?['def'] is Map ? NotebookDef.fromJson(_withoutFids(shared!['def'] as Map)) : NotebookDef(name: d.notebook, fields: const [], sort: NotebookSort.recent),
      private: shared?['private'] == true,
    );
    byName[made.name] = made;
    // The other device's property names, by label, so both write the same ones.
    final sharedProps = shared?['props'];
    final sharedFields = shared?['def'] is Map ? (shared!['def'] as Map)['fields'] as List? ?? const [] : const [];
    if (sharedProps is Map) {
      final byLabel = {for (final f in sharedFields) '${(f as Map)['label']}': sharedProps['${f['fid']}']};
      _props[made.id] = {
        for (final f in made.def.fields)
          if (f.fid != null && byLabel[f.label] is String) f.fid!: byLabel[f.label] as String,
      };
    }
    return made;
  }

  static Map _withoutFids(Map def) => {
        ...def,
        'fields': [for (final f in (def['fields'] as List? ?? const [])) if ((f as Map)['hidden'] != true) {...f}..remove('fid')],
      };

  Map<String, dynamic>? _sharedBooks;

  Future<Map<String, dynamic>?> _sharedBook(String name) async {
    if (_sharedBooks == null) {
      try {
        final t = await folder.readText('.cache/notebooks.json');
        final j = t == null ? null : jsonDecode(t);
        _sharedBooks = {for (final n in (j is Map ? j['notebooks'] as List? ?? const [] : const [])) '${(n as Map)['def']?['name']}': n};
      } catch (_) {
        _sharedBooks = {};
      }
    }
    final n = _sharedBooks![name];
    return n is Map ? n.cast<String, dynamic>() : null;
  }

  /// [d] into Cache as entry [id] (made or replaced); returns the entry as stored. Values that do not fit their field stay in
  /// the file as the person's own properties.
  Future<NbEntry> _apply(String id, EntryDoc d, Map<String, Notebook> byName, {String? text}) async {
    final known = byName.containsKey(d.notebook);
    var book = await _bookFor(d, byName);
    if (!known && text != null) {
      // The notebook was just made: read the fields again with its field names.
      final again = _logseq
          ? parseLogseq(splitPage(text).blocks.firstOrNull ?? LsBlock([text]), day: d.when.substring(0, 10), fallbackNotebook: book.name, fieldProps: _propTypes(book))
          : parseObsidian(text, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book));
      if (again != null) d = again;
    }
    if (book.savedPlaces == false && kind == SyncKind.share) {
      final shared = await _sharedBook(d.notebook);
      if (shared?['saved_places'] == true) book = await notebook.ensureSavedPlaces();
    }
    final existing = await notebook.entry(id);
    final propToFid = {for (final e in _fieldProps(book).entries) e.value: e.key};
    final values = <String, dynamic>{};
    final extra = [...d.extra];
    for (final e in d.fields.entries) {
      final fid = propToFid[e.key];
      final f = fid == null ? null : book.def.field(fid);
      final v = e.value;
      final ok = switch (f?.type) {
        FieldType.number => v is num,
        FieldType.yesNo => v is bool,
        FieldType.text || FieldType.choice => v is String || v is num || v is bool,
        FieldType.place => v is Map,
        FieldType.photo => v is List,
        null => false,
      };
      if (ok) {
        values[fid!] = f!.type == FieldType.text || f.type == FieldType.choice ? '$v' : v;
      } else if (v != null) {
        extra.add('${e.key}: ${yamlText('$v')}');
      }
    }
    final photoIds = [...d.photos, for (final v in values.values) if (v is List) ...v.whereType<String>()];
    for (final pid in photoIds) {
      final f = await notebook.photoFile(pid);
      if (await f.exists()) continue;
      final bytes = await folder.readBytes('$_attachments/cache-$pid.jpg');
      if (bytes != null) await storePhotoBytes(pid, bytes);
    }
    final had = {for (final p in existing?.photos ?? const <NbPhoto>[]) p.id: p};
    final offset = offsetOf(existing?.occurredAt, now: _now());
    final place = d.place == null
        ? null
        : NbPlace(
            lat: d.place!.lat,
            lon: d.place!.lon,
            label: d.place!.label,
            key: existing?.place != null && existing!.place!.lat == d.place!.lat && existing.place!.lon == d.place!.lon ? existing.place!.key : existing?.place?.key,
          );
    final saved = await notebook.saveEntry(
      id: id,
      notebookId: book.id,
      occurredAt: existing != null && wallTime(existing.occurredAt) == d.when ? existing.occurredAt : withOffset(d.when, offset),
      title: (d.title ?? '').trim().isEmpty ? null : d.title!.trim(),
      body: d.body.trim().isEmpty ? null : d.body,
      values: values,
      place: place,
      photos: [
        for (final pid in d.photos)
          if (had[pid] != null) had[pid]! else if (await (await notebook.photoFile(pid)).exists()) NbPhoto(id: pid),
      ],
      files: existing?.files ?? const [],
      private: kind == SyncKind.share ? d.private : (existing?.private ?? d.private),
      props: existing?.props ?? const {},
    );
    _items[id] = _Item(_items[id]?.path ?? '', '', saved.rev, extra: extra);
    return saved;
  }

  /// Writes a photo that came from the folder under its own id (the app stores it as a Notebook photo).
  Future<void> Function(String id, Uint8List bytes) storePhotoBytes = (id, bytes) async {};

  // ---- the run ----

  /// One sync. Errors reaching the folder are thrown (the status line shows them); nothing in Cache is lost.
  Future<SyncReport> run() async {
    final r = SyncReport();
    await _load();
    _sharedBooks = null;
    if (!await folder.reachable()) throw const FileSystemException("Can't reach the folder");
    await notebook.reload();
    final books = notebook.notebooks;
    final byName = {for (final n in books) n.name: n};
    final cache = <String, (Notebook, NbEntry)>{};
    for (final n in books) {
      for (final e in await notebook.entries(n.id)) {
        if (_included(n, e)) cache[e.id] = (n, e);
      }
    }
    final newOutside = <_Unit>[];
    final unreadable = <SyncConflict>[];
    final outside = await _scan(byName, newOutside, unreadable);
    final open = {for (final c in _conflicts) c.entryId};
    final conflicts = <SyncConflict>[...unreadable];
    final ids = {...cache.keys, ..._items.keys, ...outside.keys};
    for (final id in ids) {
      if (open.contains(id)) {
        conflicts.addAll(_conflicts.where((c) => c.entryId == id));
        continue;
      }
      final c = cache[id];
      final s = _items[id];
      final f = outside[id];
      final cacheChanged = c != null && (s == null || c.$2.rev != s.rev);
      final fileChanged = kind != SyncKind.logseqExport && f != null && s != null && f.text != s.base;
      final missing = kind != SyncKind.logseqExport && f == null && s != null;
      if (c != null) {
        final doc = _docOf(c.$1, c.$2);
        final text = _render(doc);
        if (s == null && f == null) {
          _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev);
          r.written++;
        } else if (s == null && f != null) {
          // Both have it and Cache has no record (a folder connected again, or a second device joining).
          if (f.text != text) {
            final m = merge3('', text, f.text);
            if (m.clean) {
              _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev);
              r.written++;
            } else {
              conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
            }
          } else {
            _items[id] = _Item(f.path, f.text, c.$2.rev);
          }
        } else if (missing) {
          if (kind == SyncKind.share && !cacheChanged) {
            await notebook.deleteEntry(id);
            _items.remove(id);
            r.deleted++;
          } else if (kind == SyncKind.share) {
            _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev);
            r.written++;
          } else {
            conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.removedOutside, title: doc.title ?? doc.when, path: s.path, cacheText: text));
          }
        } else if (cacheChanged && !fileChanged) {
          _items[id] = _Item(await _write(id, doc, c.$1, text), text, c.$2.rev, extra: s?.extra ?? const []);
          r.written++;
        } else if (!cacheChanged && fileChanged) {
          final saved = await _apply(id, f.doc, byName, text: f.text);
          _items[id] = _Item(f.path, f.text, saved.rev, extra: _items[id]!.extra);
          r.read++;
        } else if (cacheChanged && fileChanged) {
          final m = merge3(s.base, text, f.text);
          if (m.clean) {
            final mergedDoc = _logseq
                ? parseLogseq(splitPage(m.text).blocks.firstOrNull ?? LsBlock([m.text]), day: doc.when.substring(0, 10), fallbackNotebook: c.$1.name, fieldProps: _propTypes(c.$1))
                : parseObsidian(m.text, fallbackId: id, fallbackNotebook: c.$1.name, fieldProps: _propTypes(c.$1));
            if (mergedDoc == null) {
              conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
              continue;
            }
            final saved = await _apply(id, mergedDoc, byName);
            final path = await _write(id, mergedDoc, c.$1, m.text);
            _items[id] = _Item(path, m.text, saved.rev, extra: _items[id]!.extra);
            r.merged.add(doc.title ?? doc.when);
          } else {
            conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
          }
        }
      } else if (s != null) {
        if (f == null || kind == SyncKind.logseqExport) {
          // Gone from Cache: gone from the folder too (unless only the folder had it, already gone).
          if (f == null && kind != SyncKind.logseqExport) {
            _items.remove(id);
          } else {
            await _deleteOutside(id);
            _items.remove(id);
            r.deleted++;
          }
        } else if (!fileChanged) {
          await _deleteOutside(id);
          _items.remove(id);
          r.deleted++;
        } else {
          // Deleted in Cache but changed in the folder: the file wins (an edit outside is newer intent).
          final saved = await _apply(id, f.doc, byName, text: f.text);
          _items[id] = _Item(f.path, f.text, saved.rev, extra: _items[id]!.extra);
          r.read++;
        }
      } else if (f != null) {
        // A file or block with an id Cache does not know: read as that entry.
        final saved = await _apply(id, f.doc, byName, text: f.text);
        _items[id] = _Item(f.path, f.text, saved.rev, extra: _items[id]!.extra);
        r.read++;
      }
    }
    // New notes and blocks written outside (no id yet): read as new entries, and the id written into them.
    for (final u in newOutside) {
      final id = _newId();
      final saved = await _apply(id, u.doc, byName, text: u.text);
      final book = notebook.notebook(saved.notebookId) ?? byName[u.doc.notebook]!;
      final doc = _docOf(book, saved);
      final text = _render(doc);
      if (_logseq) {
        final cur = await folder.readText(u.path) ?? '';
        final i = cur.indexOf(u.text);
        if (i >= 0) await folder.writeText(u.path, cur.replaceRange(i, i + u.text.length, text));
        _items[id] = _Item(u.path, text, saved.rev, extra: doc.extra);
      } else {
        _items[id] = _Item(u.path, text, saved.rev, extra: doc.extra);
        await folder.writeText(u.path, text);
      }
      r.read++;
    }
    _conflicts = conflicts;
    r.conflicts = conflicts.length;
    if (!_logseq) await _writeBooks(books);
    await _save();
    return r;
  }

  /// `.cache/notebooks.json`: each notebook's definition, so a device that does not have it yet makes it the same way.
  Future<void> _writeBooks(List<Notebook> books) async {
    final list = [
      for (final n in books)
        if (includePrivate || !n.private || privateBooks.contains(n.id))
          {'id': n.id, 'template': n.template, 'def': n.def.toJson(), 'private': n.private, 'map': n.map, if (n.savedPlaces) 'saved_places': true, 'props': _fieldProps(n)},
    ];
    final text = '${const JsonEncoder.withIndent(' ').convert({'format': 'cache-notebooks', 'version': 1, 'notebooks': list})}\n';
    if (await folder.readText('.cache/notebooks.json') != text) await folder.writeText('.cache/notebooks.json', text);
  }

  String _newId() {
    final rnd = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(12, '0');
    final h = (rnd + rnd.split('').reversed.join() + rnd).substring(0, 32);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  /// The person's decision on a conflict. Both changed: [keepCache] writes Cache's version to the folder, else the folder's
  /// is read into Cache; the other is kept as a copy. Removed outside: [keepCache] writes it again, else deletes it here.
  /// Unreadable: [keepCache] = ignore the file from now on.
  Future<void> resolve(SyncConflict c, {required bool keepCache}) async {
    await _load();
    await notebook.reload();
    final byName = {for (final n in notebook.notebooks) n.name: n};
    final e = c.entryId.isEmpty ? null : await notebook.entry(c.entryId);
    final book = e == null ? null : notebook.notebook(e.notebookId);
    switch (c.kind) {
      case ConflictKind.unreadable:
        _ignored.add(c.path);
      case ConflictKind.removedOutside:
        if (keepCache && e != null && book != null) {
          final doc = _docOf(book, e);
          final text = _render(doc);
          _items.remove(c.entryId);
          _items[c.entryId] = _Item(await _write(c.entryId, doc, book, text), text, e.rev);
        } else {
          if (e != null) await notebook.deleteEntry(c.entryId);
          _items.remove(c.entryId);
        }
      case ConflictKind.bothChanged:
        if (e == null || book == null) break;
        final doc = _docOf(book, e);
        final text = _render(doc);
        if (keepCache) {
          if (c.fileText != null) await _keepCopy(doc.title ?? doc.when, c.fileText!);
          _items[c.entryId] = _Item(await _write(c.entryId, doc, book, text), text, e.rev, extra: _items[c.entryId]?.extra ?? const []);
        } else {
          await _keepCopy(doc.title ?? doc.when, text);
          final fileDoc = c.fileText == null
              ? null
              : _logseq
                  ? parseLogseq(splitPage(c.fileText!).blocks.firstOrNull ?? LsBlock([c.fileText!]), day: doc.when.substring(0, 10), fallbackNotebook: book.name, fieldProps: _propTypes(book))
                  : parseObsidian(c.fileText!, fallbackId: c.entryId, fallbackNotebook: book.name, fieldProps: _propTypes(book));
          if (fileDoc != null) {
            final saved = await _apply(c.entryId, fileDoc, byName);
            _items[c.entryId] = _Item(c.path, c.fileText!, saved.rev, extra: _items[c.entryId]!.extra);
          }
        }
    }
    _conflicts = [for (final x in _conflicts) if (!(x.entryId == c.entryId && x.path == c.path && x.kind == c.kind)) x];
    await _save();
  }

  /// Drops the record of what was synced (the folder was disconnected): the next connection starts fresh.
  Future<void> forget() async {
    try {
      if (await stateFile.exists()) await stateFile.delete();
    } catch (_) {}
  }
}
