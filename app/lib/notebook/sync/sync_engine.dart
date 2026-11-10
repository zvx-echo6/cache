import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../files.dart';
import '../notebook_model.dart';
import '../notebook_state.dart';
import 'folder.dart';
import 'formats.dart';
import 'merge.dart';
import '../../platform/app_log.dart';

/// Where notebooks are kept outside Cache:
/// - [obsidian]: one Markdown file per entry, two-way;
/// - [logseq]: one block per entry on its day's journal page of a classic (file-based) Logseq graph, two-way;
/// - [logseqExport]: the same blocks for Logseq 2.x, which imports Markdown: written, never read back;
/// - [share]: Cache's own folder that notebook sync keeps the same on the linked devices, two-way, in the Obsidian format.
enum SyncKind { obsidian, logseq, logseqExport, share }

/// The file in each notebook's folder (notebook sync) that carries the notebook's id, so it is the same on every linked device.
const String kNotebookIdFile = 'notebook.json';

/// How long the tombstone of a deleted notebook stays in the share.
const int kTombstoneDays = 30;

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

  /// Notes imported by their tag in this run (their titles), and the notebooks they went to.
  final List<String> imported = [];
  final Set<String> importedBooks = {};

  /// Tagged notes Cache could not import (it could not write its id into them: a read-only folder).
  int notAdded = 0;

  /// Imported notes whose entry was deleted in Cache: their id was taken out of them.
  int released = 0;
}

/// One entry's state at the last sync: where it is, the text it had there, and the entry's rev then.
class _Item {
  _Item(this.path, this.base, this.rev, {this.extra = const [], this.imp, this.w0, this.uk = const [], this.ht = false});

  String path;
  String base;
  int rev;
  List<String> extra;

  /// A note the person made that Cache imported by its tag: `note` (Obsidian), `page` or `block` (Logseq); null for Cache's own.
  final String? imp;

  /// The time Cache gave an imported note (its own date and time, or the import's).
  final String? w0;

  /// An imported Obsidian note's property names from before the import: kept as they are, never read as Cache's.
  final List<String> uk;

  /// An imported Obsidian note had a `title` property: it is always written (else only when it is not the file's name).
  final bool ht;

  Map<String, dynamic> toJson() => {
        'path': path, 'base': base, 'rev': rev, if (extra.isNotEmpty) 'extra': extra, if (imp != null) 'imp': imp, if (w0 != null) 'w0': w0, if (uk.isNotEmpty) 'uk': uk,
        if (ht) 'ht': true,
      };

  static _Item fromJson(Map j) => _Item('${j['path']}', '${j['base']}', (j['rev'] as num?)?.toInt() ?? 0,
      extra: [for (final l in (j['extra'] as List? ?? const [])) '$l'], imp: j['imp'] as String?, w0: j['w0'] as String?, uk: [for (final k in (j['uk'] as List? ?? const [])) '$k'], ht: j['ht'] == true);
}

/// A note the person made with the import tag and no Cache id, found by the scan.
class _Cand {
  _Cand(this.kind, this.path, this.text, this.notebook, {this.private = false});

  /// `note`, `page` or `block` (see [_Item.imp]).
  final String kind;
  final String path;

  /// The file (note, page) or the block, as found.
  final String text;

  /// The notebook its `#cachesync/<notebook>` names; null for the plain tag.
  final String? notebook;
  final bool private;
}

/// The notebook a note with the plain import tag goes to when there is no Journal (the Journal is Cache's default notebook).
const String kImportFallbackNotebook = 'Notes';

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
///
/// Obsidian and Logseq work on Cache's own files only, always (owner, 2026-10-31): a file or block Cache wrote (it carries
/// Cache's id and Cache has a record of it) is two-way; a note made in Obsidian or Logseq is never read, even inside Cache's
/// folder; and a Cache file deleted there is written back, because Cache is the source of truth (the entry is not deleted).
/// Notebook sync between the person's devices ([SyncKind.share]) keeps the full two-way rules.
///
/// Import by tag (1.0.30, owner-approved): a note the person made with the import tag ([importTag], `#cachesync`) and no Cache
/// id is imported once, into the notebook `#cachesync/<notebook>` names (made when there is none) or the Journal, and Cache
/// writes its id into it. From then on the id decides, as for Cache's own files: the tag is never read again. When its entry is
/// deleted in Cache, or the person chooses "Stop syncing this note" ([stopSyncing]), the id goes out of the note and
/// `cachesync: off` takes its place, so it is never imported or written again; the note's text stays as it is.
class NotebookSync {
  NotebookSync({
    required this.notebook,
    required this.kind,
    required this.folder,
    required this.stateFile,
    this.includePrivate = true,
    this.privateBooks = const {},
    this.logseqConfig,
    this.importTag = kDefaultImportTag,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// The tag that imports a note (Obsidian and two-way Logseq).
  final String importTag;

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

  /// Entries the person stopped syncing with this folder: kept in Cache, never written here again.
  final Set<String> _stopped = {};

  /// Notebook sync: the folders this device wrote a notebook.json in, and for which id (to see a notebook leave the share).
  Map<String, String> _idDirs = {};

  /// Names a notebook had before another device renamed it (name to id): an old file that still says the old name is that
  /// notebook's, not a new one.
  Map<String, String> _aliases = {};

  /// Entries whose file is missing from the old folder of a renamed notebook, and how many runs they were waited for (the new
  /// file may not have arrived yet): never deleted at once.
  Map<String, int> _moveMiss = {};

  /// Notebooks this run followed to another name (another device renamed them): their files are moved by that device.
  final Set<String> _followed = {};

  /// Each notebook's folder (by notebook name) for this run: the folder's name, with a deterministic suffix when two names make one.
  Map<String, String> _dirs = {};

  List<SyncConflict> get conflicts => List.unmodifiable(_conflicts);

  bool get _logseq => kind == SyncKind.logseq || kind == SyncKind.logseqExport;

  /// Obsidian and Logseq: only Cache's own files and blocks are synced (see the class comment).
  bool get _ownFilesOnly => kind != SyncKind.share;
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
      _stopped
        ..clear()
        ..addAll([for (final x in (j['stopped'] as List? ?? const [])) '$x']);
      _idDirs = {for (final e in (j['id_dirs'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      _aliases = {for (final e in (j['aliases'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      _moveMiss = {for (final e in (j['move_miss'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()};
    } catch (e) {
      logError('Notebook sync: state unreadable', error: e);
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
        if (_stopped.isNotEmpty) 'stopped': [..._stopped],
        if (_idDirs.isNotEmpty) 'id_dirs': _idDirs,
        if (_aliases.isNotEmpty) 'aliases': _aliases,
        if (_moveMiss.isNotEmpty) 'move_miss': _moveMiss,
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

  static String _baseName(String path) {
    final n = path.split('/').last;
    return n.endsWith('.md') ? n.substring(0, n.length - 3) : n;
  }

  /// Entry [id] as its file or block holds it: an imported note in its own shape, else Cache's.
  String _renderFor(String id, EntryDoc d) {
    final it = _items[id];
    return switch (it?.imp) {
      'note' => renderObsidian(d, imported: true, skip: it!.uk.toSet(), titleDefault: it.ht ? null : _baseName(it.path), whenDefault: it.w0),
      'page' => renderLsPage(d, pageTitle: lsPageTitle(it!.path)),
      'block' => renderLsBlock(d),
      _ => _render(d),
    };
  }

  /// [text] (entry [id]'s file or block) read back; [when] is the entry's time now (an imported note that does not say its time
  /// keeps it).
  EntryDoc? _parseAs(String id, String text, Notebook book, {required String when}) {
    final it = _items[id];
    switch (it?.imp) {
      case 'note':
        return parseObsidian(text, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book), fallbackWhen: when, userKeys: it!.uk.toSet(), fallbackTitle: _baseName(it.path));
      case 'page':
        return parseLsPage(text, pageTitle: lsPageTitle(it!.path), when: when, notebook: book.name);
      case 'block':
        return parseLsBlock(splitPage(text).blocks.firstOrNull ?? lsBlockOf(text), when: when, notebook: book.name);
    }
    return _logseq
        ? parseLogseq(splitPage(text).blocks.firstOrNull ?? LsBlock([text]), day: when.substring(0, 10), fallbackNotebook: book.name, fieldProps: _propTypes(book))
        : parseObsidian(text, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book));
  }

  /// Records entry [id]'s state, keeping what it is (imported or Cache's own).
  void _rec(String id, String path, String base, int rev, {List<String>? extra}) {
    final old = _items[id];
    _items[id] = _Item(path, base, rev, extra: extra ?? old?.extra ?? const [], imp: old?.imp, w0: old?.w0, uk: old?.uk ?? const [], ht: old?.ht ?? false);
  }

  String get _nowWall => wallTime(_now().toIso8601String());

  bool _included(Notebook n, NbEntry e) => !e.draft && (includePrivate || !e.private || privateBooks.contains(n.id));

  // ---- the folder ----

  Future<Map<String, _Unit>> _scan(Map<String, Notebook> byName, List<_Unit> newOutside, List<SyncConflict> unreadable,
      {Map<String, (Notebook, NbEntry)> cache = const {}, List<_Cand>? candidates}) async {
    final out = <String, _Unit>{};
    if (kind == SyncKind.logseqExport) return out;
    // An imported note's notebook and time are its entry's (the note does not say them).
    String nbOf(String id) => cache[id]?.$1.name ?? '';
    String whenOf(String id) => cache[id] == null ? _nowWall : wallTime(cache[id]!.$2.occurredAt);
    final importing = _ownFilesOnly && candidates != null;
    if (_logseq) {
      for (final dir in [_journals, 'pages']) {
        for (final f in await folder.list(dir)) {
          if (!f.path.endsWith('.md')) continue;
          final text = await folder.readText(f.path);
          if (text == null) continue;
          final day = dayOfJournal(f.path.split('/').last, format: _format);
          final page = splitPage(text);
          final headId = lsPageId(text);
          if (headId != null && _items[headId]?.imp == 'page') {
            out.putIfAbsent(headId, () => _Unit(f.path, text, parseLsPage(text, pageTitle: lsPageTitle(f.path), when: whenOf(headId), notebook: nbOf(headId))));
            continue;
          }
          if (importing && dir == 'pages' && headId == null && !page.head.trimLeft().startsWith('---') && !page.blocks.any((b) => b.cacheId != null)) {
            final head = lsProps(page.head.split('\n'));
            final tag = lsSyncOff(head) ? null : importTagIn(lsTagValues(head['tags']), importTag);
            if (tag != null) {
              candidates.add(_Cand('page', f.path, text, tag.notebook, private: lsPrivate(head)));
              continue;
            }
          }
          for (final b in page.blocks) {
            final id = b.cacheId;
            if (id != null && _items[id]?.imp == 'block') {
              out.putIfAbsent(id, () => _Unit(f.path, b.text, parseLsBlock(b, when: whenOf(id), notebook: nbOf(id))));
              continue;
            }
            if (id == null && importing) {
              final bp = lsBlockProps(b);
              final tag = lsSyncOff(bp) ? null : importTagIn(lsBlockTags(b), importTag);
              if (tag != null) {
                candidates.add(_Cand('block', f.path, b.text, tag.notebook, private: lsPrivate(bp)));
                continue;
              }
            }
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
    void put(_Unit u) {
      final prev = out[u.doc.id];
      if (prev == null) {
        out[u.doc.id] = u;
      } else if (kind == SyncKind.share && _topDir(prev.path) != _topDir(u.path) && cache[u.doc.id] != null && [_topDir(prev.path), _topDir(u.path)].contains(_dirOf(cache[u.doc.id]!.$1))) {
        // The same entry in two folders after a notebook was renamed (the new file came before the old one went): the one in the
        // notebook's folder is the entry, the other is the old place, not a copy.
        if (_topDir(u.path) == _dirOf(cache[u.doc.id]!.$1)) out[u.doc.id] = u;
      } else {
        // A duplicated file: the one Cache knows keeps the id; the other becomes a new entry.
        final keep = _items[u.doc.id]?.path == prev.path ? prev : u;
        final other = identical(keep, prev) ? u : prev;
        out[u.doc.id] = keep;
        newOutside.add(_Unit(other.path, other.text, EntryDoc(id: '', notebook: other.doc.notebook, when: other.doc.when, title: other.doc.title, body: other.doc.body, place: other.doc.place, photos: other.doc.photos, fields: other.doc.fields, private: other.doc.private, extra: other.doc.extra)));
      }
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
        // A note that is not Cache's is never Cache's business, readable or not.
        if (_ownFilesOnly && known == null) continue;
        if (!_ignored.contains(f.path)) {
          unreadable.add(SyncConflict(entryId: known?.key ?? '', kind: ConflictKind.unreadable, title: f.path.split('/').last, path: f.path));
        }
        continue;
      }
      final it = probe.id.isEmpty ? null : _items[probe.id];
      if (it?.imp == 'note') {
        final c = cache[probe.id];
        final doc = parseObsidian(text,
            fallbackId: '', fallbackNotebook: nbOf(probe.id), fieldProps: c == null ? const {} : _propTypes(c.$1), fallbackWhen: whenOf(probe.id), userKeys: it!.uk.toSet(), fallbackTitle: _baseName(f.path))!;
        put(_Unit(f.path, text, doc));
        continue;
      }
      if (probe.id.isEmpty && _ownFilesOnly) {
        // The person's own note: imported when it has the import tag (and not `cachesync: off`), else never read.
        if (importing && kind == SyncKind.obsidian && !obsidianSyncOff(text)) {
          final tag = importTagIn(obsidianTags(text), importTag);
          if (tag != null) candidates.add(_Cand('note', f.path, text, tag.notebook, private: probe.private));
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
      put(u);
    }
    return out;
  }

  static String folderNameOf(Notebook n) => folderName(n.name);

  /// Each notebook's folder: its name's folder, and for the notebooks whose names make the same folder ("Trip: 2026", "Trip 2026"),
  /// the one with the lowest id keeps it and the others get their id's first characters added, so no two share a folder.
  static Map<String, String> folderNames(Iterable<Notebook> books) {
    final by = <String, List<Notebook>>{};
    for (final n in books) {
      by.putIfAbsent(folderNameOf(n), () => []).add(n);
    }
    final out = <String, String>{};
    for (final e in by.entries) {
      final l = e.value..sort((a, b) => a.id.compareTo(b.id));
      for (var i = 0; i < l.length; i++) {
        out[l[i].name] = i == 0 ? e.key : '${e.key} ${l[i].id.substring(0, l[i].id.length < 8 ? l[i].id.length : 8)}';
      }
    }
    return out;
  }

  static String _topDir(String path) => path.contains('/') ? path.substring(0, path.indexOf('/')) : '';

  String _dirOf(Notebook n) => _dirs[n.name] ?? folderNameOf(n);

  Future<String> _newPath(EntryDoc d, Notebook n) async {
    final dir = _dirOf(n);
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
    final it = _items[id];
    if (it?.imp == 'block') {
      // An imported block stays where the person wrote it.
      final cur = await folder.readText(it!.path) ?? '';
      final p = splitPage(cur);
      final at = p.blocks.indexWhere((b) => b.cacheId == id);
      final sep = cur.isEmpty || cur.endsWith('\n') ? '' : '\n';
      await folder.writeText(it.path, at >= 0 ? p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? text : p.blocks[i].text].join() : '$cur$sep$text');
      return it.path;
    }
    if (it?.imp == 'page') {
      await folder.writeText(it!.path, text);
      return it.path;
    }
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
    final al = kind == SyncKind.share ? _aliases[d.notebook] : null;
    final aliased = al == null ? null : notebook.notebook(al);
    if (aliased != null) return aliased;
    final shared = await _sharedBook(d.notebook);
    // The id the notebook has on the other devices (from its folder's notebook.json).
    var id = _idIn(jsonEncode({'id': shared?['id']}));
    final held = id == null ? null : notebook.notebook(id);
    if (held != null && held.name != d.notebook && kind == SyncKind.share) {
      // Another device renamed the notebook: the folder carries the same id, so the notebook here is renamed, not made again.
      final renamed = await notebook.saveNotebook(id: held.id, def: held.def.copyWith(name: d.notebook));
      byName.remove(held.name);
      byName[renamed.name] = renamed;
      return renamed;
    }
    // An id another notebook here already has is never taken (saving under it would change that notebook).
    if (held != null) id = null;
    final made = await notebook.saveNotebook(
      id: id,
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

  // ---- notebook ids between linked devices ----

  /// The id in a notebook's id file, or null when it is not one.
  static String? _idIn(String? text) {
    if (text == null) return null;
    try {
      final j = jsonDecode(text);
      final id = j is Map && j['deleted'] != true ? j['id'] : null;
      return id is String && RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(id) ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Linked devices that each made the same notebook must end with one id for it. Every notebook's folder carries a small
  /// `notebook.json` with its id (a file of its own, so there is no shared map for two devices to change at once). The lowest id
  /// found, in the folder's file and in the conflict copies that sync keeps when two devices wrote it at once, and this device's
  /// own, wins on every device; a device with another id takes the winner's through the re-id journal (its entries, private-sharing
  /// choice, shortcuts, Places link, map layer and field names follow) and writes it. An id another notebook here holds cannot be
  /// taken: the device keeps its own, and the file is never rewritten to a higher id than it has, so it cannot flip-flop. Notebooks
  /// left out of the sync (private ones not included) are not touched.
  ///
  /// A notebook that leaves the share loses its file: renamed or turned off, the old `<folder>/notebook.json` is removed (peers keep
  /// their copy; a rename shows as the same id in the new folder, and peers rename theirs); deleted, it is replaced by a tombstone
  /// `{"id", "deleted": true, "at": <ms>}` kept for [kTombstoneDays] days, for peers to act on.
  Future<void> _settleIds() async {
    if (kind != SyncKind.share) return;
    final copy = RegExp(r'^notebook \(conflict, .*\)\.json$');
    final now = <String, String>{};
    _dirs = folderNames(notebook.notebooks);
    await _followRenames();
    for (final n in [...notebook.notebooks]) {
      if (!(includePrivate || !n.private || privateBooks.contains(n.id))) continue;
      final dir = _dirOf(n);
      final path = '$dir/$kNotebookIdFile';
      final files = [
        for (final f in await folder.list(dir))
          if (f.path.startsWith('$dir/') && (f.path.substring(dir.length + 1) == kNotebookIdFile || copy.hasMatch(f.path.substring(dir.length + 1)))) f.path,
      ];
      var winner = n.id;
      for (final p in files) {
        final id = _idIn(await folder.readText(p));
        // an id another notebook here holds is not this one's to take
        if (id != null && id.compareTo(winner) < 0 && notebook.notebook(id) == null) winner = id;
      }
      var book = n;
      if (winner != n.id) {
        final old = n.id;
        // The field names are saved first, so the journal's step moves what is on disk; then they are read again.
        await _save();
        book = await notebook.reidNotebook(old, winner, also: {'share field names': (o, w) => moveProps(stateFile, o, w)});
        await _load();
        if (privateBooks.contains(old)) {
          privateBooks
            ..remove(old)
            ..add(winner);
        }
      }
      // The file also holds the notebook's definition as it was when the id was written, for a device that has not got the
      // notebook yet. It is written when the folder has no id file or one with a higher id; never rewritten after (two devices
      // editing it at once would conflict).
      final have = _idIn(await folder.readText(path));
      // A file that is gone where this device wrote it was taken away on purpose (the notebook was renamed, turned off or deleted
      // there): it is not written back.
      final taken = have == null && _idDirs[dir] == book.id && !files.any((p) => p != path);
      if (!taken && (have == null || have.compareTo(book.id) > 0)) {
        await folder.writeText(path, '${const JsonEncoder.withIndent(' ').convert(_bookJson(book))}\n');
      }
      for (final p in files) {
        if (p != path) await folder.delete(p);
      }
      now[dir] = book.id;
    }
    // Notebooks that left the share since the last run. Not when the list could not be read (everything would look deleted).
    if (notebook.error == null && notebook.notebooks.isNotEmpty) {
      final local = {for (final n in notebook.notebooks) n.id};
      for (final e in _idDirs.entries) {
        if (now.containsKey(e.key)) continue;
        final path = '${e.key}/$kNotebookIdFile';
        final text = await folder.readText(path);
        final j = _jsonMap(text);
        if (j != null && j['id'] != e.value) continue; // the folder's file is another notebook's now
        if (local.contains(e.value)) {
          // Renamed here: its entry files move to the new folder with it (a device that followed a rename here leaves that to
          // the one that made it).
          final book = notebook.notebook(e.value);
          if (book != null && now.containsValue(e.value) && !_followed.contains(e.value)) await _moveEntries(e.key, book);
          if (text != null) await folder.delete(path);
        } else {
          await folder.writeText(path, '${jsonEncode({'id': e.value, 'deleted': true, 'at': _now().millisecondsSinceEpoch})}\n');
        }
      }
      _idDirs = now;
    }
    // Old tombstones go.
    for (final f in await folder.list('')) {
      if (!RegExp('^[^/]+/$kNotebookIdFile\$').hasMatch(f.path)) continue;
      final j = _jsonMap(await folder.readText(f.path));
      final at = j?['at'];
      if (j?['deleted'] == true && at is num && _now().millisecondsSinceEpoch - at > kTombstoneDays * 86400000) await folder.delete(f.path);
    }
  }

  /// A notebook renamed here: each of its entry files goes to the new folder (written there, then taken out of the old one) and is
  /// read as the same entry from there. A file changed in the folder since the last sync stays where it is.
  Future<void> _moveEntries(String oldDir, Notebook book) async {
    final newDir = _dirOf(book);
    if (newDir == oldDir) return;
    for (final e in _items.entries.toList()) {
      final it = e.value;
      if (it.imp != null || !it.path.startsWith('$oldDir/') || !it.path.endsWith('.md')) continue;
      final entry = await notebook.entry(e.key);
      if (entry == null || entry.notebookId != book.id) continue;
      final text = await folder.readText(it.path);
      if (text == null || text != it.base) continue;
      var np = '$newDir/${it.path.substring(oldDir.length + 1)}';
      for (var i = 2; await folder.exists(np) || _items.values.any((x) => x.path == np); i++) {
        np = '$newDir/${_baseName(it.path)} $i.md';
      }
      final fresh = _render(_docOf(book, entry));
      await folder.writeText(np, fresh);
      await folder.delete(it.path);
      _rec(e.key, np, fresh, entry.rev);
    }
  }

  /// Another device renamed a notebook: its new folder has a `notebook.json` with the id of a notebook here, in a folder no notebook
  /// here has. The notebook here is renamed to the file's name (the same notebook, not a second one).
  Future<void> _followRenames() async {
    for (final f in await folder.list('')) {
      final m = RegExp('^([^/]+)/$kNotebookIdFile\$').firstMatch(f.path);
      if (m == null) continue;
      final dir = m.group(1)!;
      final j = _jsonMap(await folder.readText(f.path));
      final id = _idIn(j == null ? null : jsonEncode({'id': j['id']}));
      final name = j?['def'] is Map ? (j!['def'] as Map)['name'] : null;
      final mine = id == null ? null : notebook.notebook(id);
      if (mine == null || name is! String || name.trim().isEmpty) continue;
      // A file this device wrote for that id in that folder is the notebook's old place here (renamed on this device): not followed.
      if (_idDirs[dir] == mine.id) continue;
      if (_dirOf(mine) == dir || folderName(name) != dir || notebook.notebooks.any((n) => _dirOf(n) == dir) || notebook.nameTaken(name, exceptId: mine.id)) continue;
      _aliases[mine.name] = mine.id;
      _followed.add(mine.id);
      await notebook.saveNotebook(id: mine.id, def: mine.def.copyWith(name: name.trim()));
      _dirs = folderNames(notebook.notebooks);
    }
  }

  static Map<String, dynamic>? _jsonMap(String? text) {
    if (text == null) return null;
    try {
      final j = jsonDecode(text);
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// A notebook's field names (kept in a sync state file, by notebook id) move to its new id; saved at once, and running it
  /// again changes nothing. A step of the re-id journal.
  static Future<void> moveProps(File f, String oldId, String newId) async {
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString());
    final props = j is Map ? j['props'] : null;
    if (j is! Map || props is! Map || !props.containsKey(oldId)) return;
    final m = {...props};
    final moved = m.remove(oldId);
    m.putIfAbsent(newId, () => moved);
    await writeStringAtomic(f, jsonEncode({...j, 'props': m}));
  }

  Map<String, dynamic>? _sharedBooks;

  /// The notebook [name] as the other device made it: its folder's notebook.json (notebook sync), else the old map file.
  Future<Map<String, dynamic>?> _sharedBook(String name) async {
    if (kind == SyncKind.share) {
      // By the notebook's own file (its folder may carry a suffix): the one whose definition has this name; the folder the name
      // makes only when no file says it.
      for (final f in await folder.list('')) {
        if (!RegExp('^[^/]+/$kNotebookIdFile\$').hasMatch(f.path)) continue;
        final j = _jsonMap(await folder.readText(f.path));
        final n = j?['def'] is Map ? (j!['def'] as Map)['name'] : null;
        if (j != null && j['deleted'] != true && n is String && n.trim().toLowerCase() == name.trim().toLowerCase() && _idIn(jsonEncode({'id': j['id']})) != null) return j;
      }
      final j = _jsonMap(await folder.readText('${folderName(name)}/$kNotebookIdFile'));
      if (j != null && j['deleted'] != true && _idIn(jsonEncode({'id': j['id']})) != null) return j;
    }
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
      final again = _parseAs(id, text, book, when: d.when);
      if (again != null) d = again;
    }
    if (book.savedPlaces == false && kind == SyncKind.share) {
      final shared = await _sharedBook(d.notebook);
      if (shared?['saved_places'] == true) book = await notebook.ensureSavedPlaces();
    }
    final existing = await notebook.entry(id);
    // An imported note keeps in Cache what its file does not hold (a Logseq page or block holds only its title and text).
    final keep = _items[id]?.imp != null && existing != null;
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
      values: keep ? {...existing.values, ...values} : values,
      place: place ?? (keep ? existing.place : null),
      photos: keep && d.photos.isEmpty
          ? existing.photos
          : [
              for (final pid in d.photos)
                if (had[pid] != null) had[pid]! else if (await (await notebook.photoFile(pid)).exists()) NbPhoto(id: pid),
            ],
      files: existing?.files ?? const [],
      private: kind == SyncKind.share ? d.private : (existing?.private ?? d.private),
      props: existing?.props ?? const {},
    );
    _rec(id, _items[id]?.path ?? '', '', saved.rev, extra: extra);
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
    await _settleIds();
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
    final candidates = <_Cand>[];
    final outside = await _scan(byName, newOutside, unreadable, cache: cache, candidates: kind == SyncKind.share ? null : candidates);
    _stopped.removeWhere((id) => !cache.containsKey(id));
    // A Cache file removed outside is written back now (Obsidian and Logseq); a question kept from an older build is dropped.
    if (_ownFilesOnly) _conflicts = [for (final c in _conflicts) if (c.kind != ConflictKind.removedOutside) c];
    final open = {for (final c in _conflicts) c.entryId};
    final conflicts = <SyncConflict>[...unreadable];
    // A Cache file that is there but cannot be read (asked about, or ignored by the person's choice) is not missing: it is never
    // written over.
    final unreadableIds = {
      for (final c in unreadable) if (c.entryId.isNotEmpty) c.entryId,
      for (final e in _items.entries) if (_ignored.contains(e.value.path)) e.key,
    };
    final ids = {...cache.keys, ..._items.keys, ...outside.keys};
    // Notes whose id the person took out by hand in this run: never imported as new (see below).
    final held = <String>{};
    for (final id in ids) {
      if (_stopped.contains(id)) continue;
      if (open.contains(id)) {
        conflicts.addAll(_conflicts.where((c) => c.entryId == id));
        continue;
      }
      if (unreadableIds.contains(id) && !outside.containsKey(id)) continue;
      final c = cache[id];
      final s = _items[id];
      final f = outside[id];
      if (s != null && s.imp != null) {
        // An imported note moved or renamed outside: it is followed there.
        if (f != null && f.path != s.path) s.path = f.path;
        if (c == null) {
          // Its entry was deleted in Cache: the note stays, without Cache's id, and says `cachesync: off`.
          if (await notebook.entry(id) != null) continue;
          await _release(id, s);
          _items.remove(id);
          r.released++;
          continue;
        }
        if (f == null && await _takenOver(id, s)) {
          // The note is there but the person took Cache's id out of it by hand: the same as Stop syncing. The note says
          // `cachesync: off` (so it is not imported again, tag or not), the entry stays in Cache, unsynced. When the note
          // cannot be written, nothing changes and the note is not imported either (no duplicate); the next sync tries again.
          held.add(s.imp == 'block' ? '${s.path}\u0000${lsBlockKey(s.base.split('\n').first)}' : s.path);
          try {
            await _markOff(s);
          } catch (e) {
            logError('Notebook sync: could not mark a note', error: e, detail: s.path);
            continue;
          }
          _items.remove(id);
          _stopped.add(id);
          continue;
        }
      }
      final cacheChanged = c != null && (s == null || c.$2.rev != s.rev);
      final fileChanged = kind != SyncKind.logseqExport && f != null && s != null && f.text != s.base;
      final missing = kind != SyncKind.logseqExport && f == null && s != null;
      if (f != null) _moveMiss.remove(id);
      if (c != null) {
        final doc = _docOf(c.$1, c.$2);
        final text = _renderFor(id, doc);
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
          if (kind == SyncKind.share && !cacheChanged && _topDir(s.path) != _dirOf(c.$1) && (_moveMiss[id] ?? 0) < 3) {
            // The file is gone from the folder of the notebook's old name: the notebook was renamed and its new file may not have
            // come yet. Waited for (three runs), never deleted at once.
            _moveMiss[id] = (_moveMiss[id] ?? 0) + 1;
          } else if (kind == SyncKind.share && !cacheChanged) {
            _moveMiss.remove(id);
            await notebook.deleteEntry(id);
            _items.remove(id);
            r.deleted++;
          } else {
            // Notebook sync: changed here since, so written again. Obsidian and Logseq: Cache is the source of truth, so its
            // file or block is written back and the entry stays.
            _rec(id, await _write(id, doc, c.$1, text), text, c.$2.rev, extra: s.extra);
            r.written++;
          }
        } else if (cacheChanged && !fileChanged) {
          _rec(id, await _write(id, doc, c.$1, text), text, c.$2.rev, extra: s?.extra ?? const []);
          r.written++;
        } else if (!cacheChanged && fileChanged) {
          final saved = await _apply(id, f.doc, byName, text: f.text);
          _rec(id, f.path, f.text, saved.rev);
          r.read++;
        } else if (cacheChanged && fileChanged) {
          final m = merge3(s.base, text, f.text);
          if (m.clean) {
            final mergedDoc = _parseAs(id, m.text, c.$1, when: doc.when);
            if (mergedDoc == null) {
              conflicts.add(SyncConflict(entryId: id, kind: ConflictKind.bothChanged, title: doc.title ?? doc.when, path: f.path, cacheText: text, fileText: f.text));
              continue;
            }
            final saved = await _apply(id, mergedDoc, byName);
            final path = await _write(id, mergedDoc, c.$1, m.text);
            _rec(id, path, m.text, saved.rev);
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
          _rec(id, f.path, f.text, saved.rev);
          r.read++;
        }
      } else if (f != null && !_ownFilesOnly) {
        // A file or block with an id Cache does not know: read as that entry (notebook sync only; in Obsidian and Logseq a
        // file Cache has no record of is not Cache's).
        final saved = await _apply(id, f.doc, byName, text: f.text);
        _rec(id, f.path, f.text, saved.rev);
        r.read++;
      }
    }
    // Notes the person made with the import tag and no id: imported once, and Cache's id written into them.
    for (final u in candidates) {
      if (held.contains(u.kind == 'block' ? '${u.path}\u0000${lsBlockKey(u.text.split('\n').first)}' : u.path)) continue;
      await _import(u, byName, r);
    }
    // New notes and blocks written outside (no id yet): read as new entries, and the id written into them (notebook sync only;
    // Obsidian and Logseq notes the person made are left alone).
    for (final u in _ownFilesOnly ? const <_Unit>[] : newOutside) {
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
        if (includePrivate || !n.private || privateBooks.contains(n.id)) _bookJson(n),
    ];
    final text = '${const JsonEncoder.withIndent(' ').convert({'format': 'cache-notebooks', 'version': 1, 'notebooks': list})}\n';
    if (await folder.readText('.cache/notebooks.json') != text) await folder.writeText('.cache/notebooks.json', text);
  }

  Map<String, dynamic> _bookJson(Notebook n) =>
      {'id': n.id, 'template': n.template, 'def': n.def.toJson(), 'private': n.private, 'map': n.map, if (n.savedPlaces) 'saved_places': true, 'props': _fieldProps(n)};

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
        final text = _renderFor(c.entryId, doc);
        if (keepCache) {
          if (c.fileText != null) await _keepCopy(doc.title ?? doc.when, c.fileText!);
          _rec(c.entryId, await _write(c.entryId, doc, book, text), text, e.rev, extra: _items[c.entryId]?.extra ?? const []);
        } else {
          await _keepCopy(doc.title ?? doc.when, text);
          final fileDoc = c.fileText == null ? null : _parseAs(c.entryId, c.fileText!, book, when: doc.when);
          if (fileDoc != null) {
            final saved = await _apply(c.entryId, fileDoc, byName);
            _rec(c.entryId, c.path, c.fileText!, saved.rev);
          }
        }
    }
    _conflicts = [for (final x in _conflicts) if (!(x.entryId == c.entryId && x.path == c.path && x.kind == c.kind)) x];
    await _save();
  }

  // ---- import by tag ----

  /// The notebook a tagged note goes to: the one `#cachesync/<name>` names (by name or as a slug, `camping-trip` is "Camping
  /// trip"), made when there is none; the plain tag's is the Journal (Cache's default notebook), else "Notes".
  Future<Notebook> _importBook(String? name, Map<String, Notebook> byName) async {
    if (name == null) {
      final j = notebook.journal;
      if (j != null) return j;
      name = kImportFallbackNotebook;
    }
    final want = tagSlug(name);
    final have = byName.values.where((n) => !n.isPlaces && (n.name.toLowerCase() == name!.toLowerCase() || tagSlug(n.name) == want)).firstOrNull;
    if (have != null) return have;
    final shown = name.replaceAll(RegExp(r'[-_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final made = await notebook.saveNotebook(template: 'notes', def: NotebookDef(name: shown.isEmpty ? name : shown, fields: const [], sort: NotebookSort.recent));
    byName[made.name] = made;
    return made;
  }

  static final Random _rnd = Random.secure();

  String _freshId() {
    String hex(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(16).toRadixString(16)].join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  /// Imports one tagged note: Cache's id goes into the note first (nothing else in it changes), then the entry is made; when
  /// the id cannot be written (a read-only folder) nothing is made, and when the entry cannot be made the note is put back.
  Future<void> _import(_Cand u, Map<String, Notebook> byName, SyncReport r) async {
    final cur = await folder.readText(u.path);
    if (cur == null) return;
    final id = _freshId();
    final now = _nowWall;
    final String newText;
    final String unitText;
    final String w0;
    var uk = const <String>[];
    var ht = false;
    EntryDoc? doc;
    late final Notebook book;
    switch (u.kind) {
      case 'note':
        if (cur != u.text || obsidianSyncOff(cur)) return; // changed while syncing: the next sync
        final t = withCacheId(cur, id);
        final probe = parseObsidian(cur, fallbackId: '', fallbackNotebook: '', fieldProps: const {}, fallbackWhen: now);
        if (t == null || probe == null) return;
        book = await _importBook(u.notebook, byName);
        // The note's own properties stay its own; only a text `title` becomes the entry's title (Cache keeps it up to date).
        final fm = splitFrontMatter(cur);
        uk = [
          for (final (k, lines) in fm?.props ?? const <(String, List<String>)>[])
            if (k != 'cache_id' && !(k == 'title' && propValue(lines) is String)) k,
        ];
        ht = fm?.props.any((p) => p.$1 == 'title') ?? false;
        // The note's own date and time when it gives them as Obsidian writes them, else now.
        w0 = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$').hasMatch(probe.when) && DateTime.tryParse(probe.when) != null ? probe.when : now;
        newText = t;
        unitText = t;
        doc = parseObsidian(t, fallbackId: id, fallbackNotebook: book.name, fieldProps: _propTypes(book), fallbackWhen: w0, userKeys: uk.toSet(), fallbackTitle: _baseName(u.path));
      case 'page':
        if (cur != u.text || lsSyncOff(lsProps(splitPage(cur).head.split('\n')))) return;
        book = await _importBook(u.notebook, byName);
        w0 = now;
        newText = 'cache-id:: $id\n$cur';
        unitText = newText;
        doc = parseLsPage(newText, pageTitle: lsPageTitle(u.path), when: w0, notebook: book.name);
      default:
        final at = cur.indexOf(u.text);
        if (at < 0) return;
        book = await _importBook(u.notebook, byName);
        final day = dayOfJournal(u.path.split('/').last, format: _format);
        w0 = day == null ? now : '$day${now.substring(10)}';
        unitText = lsBlockWithId(lsBlockOf(u.text), id);
        newText = cur.replaceRange(at, at + u.text.length, unitText);
        doc = parseLsBlock(lsBlockOf(unitText), when: w0, notebook: book.name);
    }
    if (doc == null) return;
    doc = EntryDoc(
        id: id, notebook: book.name, when: doc.when, title: doc.title, body: doc.body, place: doc.place, photos: doc.photos, fields: doc.fields, private: u.private, extra: doc.extra);
    try {
      await folder.writeText(u.path, newText);
    } catch (e) {
      logError('Notebook sync: could not import a note', error: e, detail: u.path);
      r.notAdded++;
      return;
    }
    _items[id] = _Item(u.path, unitText, 0, extra: doc.extra, imp: u.kind, w0: w0, uk: uk, ht: ht);
    try {
      final saved = await _apply(id, doc, byName);
      _items[id] = _Item(u.path, unitText, saved.rev, extra: _items[id]?.extra ?? doc.extra, imp: u.kind, w0: w0, uk: uk, ht: ht);
    } catch (e) {
      _items.remove(id);
      try {
        if (await folder.readText(u.path) == newText) await folder.writeText(u.path, cur);
      } catch (_) {}
      logError('Notebook sync: could not import a note', error: e, detail: u.path);
      r.notAdded++;
      return;
    }
    r.imported.add((doc.title ?? '').trim().isEmpty ? _baseName(u.path) : doc.title!.trim());
    r.importedBooks.add(book.id);
    await _save();
  }

  /// The note or block that holds Cache's id [id] now: where it was, else found by its id (moved since).
  Future<String?> _pathOf(String id, _Item s) async {
    bool has(String t) => s.imp == 'note' ? parseObsidian(t, fallbackId: '', fallbackNotebook: '', fieldProps: const {})?.id == id : (s.imp == 'page' ? lsPageId(t) == id : splitPage(t).blocks.any((b) => b.cacheId == id));
    final at = await folder.readText(s.path);
    if (at != null && has(at)) return s.path;
    for (final dir in s.imp == 'note' ? [''] : [_journals, 'pages']) {
      for (final f in await folder.list(dir)) {
        if (!f.path.endsWith('.md')) continue;
        final t = await folder.readText(f.path);
        if (t != null && t.contains(id) && has(t)) return f.path;
      }
    }
    return null;
  }

  /// Takes Cache's id out of imported note [id] and writes `cachesync: off` in its place; its text and the file stay.
  Future<void> _release(String id, _Item s) async {
    final path = await _pathOf(id, s);
    if (path == null) return;
    final cur = (await folder.readText(path))!;
    final String? next;
    switch (s.imp) {
      case 'note':
        next = releasedObsidian(cur);
      case 'page':
        next = lsPageReleased(cur);
      default:
        final p = splitPage(cur);
        next = p.head + [for (final b in p.blocks) b.cacheId == id ? lsBlockReleased(b) : b.text].join();
    }
    if (next != null && next != cur) await folder.writeText(path, next);
  }

  /// An imported note that is still there without Cache's id (the person took it out): a file or page at its place, a block
  /// with the same first line (tags aside) on its page.
  Future<bool> _takenOver(String id, _Item s) async {
    final cur = await folder.readText(s.path);
    if (cur == null) return false;
    if (s.imp != 'block') return true;
    final key = lsBlockKey(s.base.split('\n').first);
    return splitPage(cur).blocks.any((b) => b.cacheId == null && lsBlockKey(b.lines.first) == key);
  }

  /// Writes `cachesync: off` into a note the person took Cache's id out of (its text and tags stay as they are).
  Future<void> _markOff(_Item s) async {
    final cur = await folder.readText(s.path);
    if (cur == null) return;
    final String? next;
    switch (s.imp) {
      case 'note':
        next = obsidianWithOff(cur);
      case 'page':
        next = lsPageWithOff(cur);
      default:
        final key = lsBlockKey(s.base.split('\n').first);
        final p = splitPage(cur);
        final at = p.blocks.indexWhere((b) => b.cacheId == null && lsBlockKey(b.lines.first) == key);
        next = at < 0 ? null : p.head + [for (var i = 0; i < p.blocks.length; i++) i == at ? lsBlockWithOff(p.blocks[i]) : p.blocks[i].text].join();
    }
    if (next != null && next != cur) await folder.writeText(s.path, next);
  }

  /// "Stop syncing this note" (an imported note): Cache's id goes out of the note, `cachesync: off` takes its place, and the
  /// entry stays in Cache as an entry of its own; neither changes the other again. False when the folder cannot be reached
  /// (nothing is changed).
  Future<bool> stopSyncing(String id) async {
    await _load();
    final s = _items[id];
    if (s == null || s.imp == null) return true;
    if (!await folder.reachable()) return false;
    await _release(id, s);
    _items.remove(id);
    _stopped.add(id);
    _conflicts = [for (final c in _conflicts) if (c.entryId != id) c];
    await _save();
    return true;
  }

  /// What a connection's record says of the entries: the ones imported by their tag and syncing, and the ones that stopped.
  static Future<({Set<String> imported, Set<String> stopped})> links(File stateFile) async {
    try {
      if (!await stateFile.exists()) return (imported: <String>{}, stopped: <String>{});
      final j = jsonDecode(await stateFile.readAsString()) as Map;
      return (
        imported: {for (final e in (j['items'] as Map? ?? const {}).entries) if ((e.value as Map)['imp'] != null) '${e.key}'},
        stopped: {for (final x in (j['stopped'] as List? ?? const [])) '$x'},
      );
    } catch (_) {
      return (imported: <String>{}, stopped: <String>{});
    }
  }

  /// Drops the record of what was synced (the folder was disconnected): the next connection starts fresh.
  Future<void> forget() async {
    try {
      if (await stateFile.exists()) await stateFile.delete();
    } catch (_) {}
  }
}
