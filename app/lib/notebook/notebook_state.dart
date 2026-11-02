import 'dart:io';

import 'package:cache_search/cache_search.dart' show CacheSearchException, SearchCore;
import 'package:flutter/foundation.dart';

import 'notebook_model.dart';

/// The core's Notebook calls (cs_notebook): one op with its arguments, the answer as JSON. Tests use an in-memory one.
abstract class NotebookBackend {
  Future<Map<String, dynamic>> call(String op, [Map<String, dynamic> args = const {}]);
}

/// The Notebook in the search core.
class CoreNotebookBackend implements NotebookBackend {
  CoreNotebookBackend(this.core);

  /// The core once it has opened (null when it failed to).
  final Future<SearchCore?> Function() core;

  @override
  Future<Map<String, dynamic>> call(String op, [Map<String, dynamic> args = const {}]) async {
    final c = await core();
    if (c == null) throw const CacheSearchException('not_configured', 'The search core is not available');
    return c.notebook(op, args);
  }
}

/// A search hit: the entry, its notebook's name and the snippet with the matched words between U+0002 and U+0003.
class NbHit {
  const NbHit(this.entry, this.notebook, this.snippet);

  final NbEntry entry;
  final String notebook;
  final String snippet;
}

/// Which private notebooks go to sync and sharing anyway (each private notebook's "Include in sync and sharing", off by
/// default). Kept by notebook sync's connections.
abstract class PrivateSharing {
  bool included(String notebookId);
  Future<void> setIncluded(String notebookId, bool on);
}

/// What the Notebooks screens show: the notebooks, most recently used first. Every change goes through the core and the list is
/// read again; [revision] counts the changes (an open notebook reads its entries again), and [onChanged] runs after each one.
class NotebookState extends ChangeNotifier {
  NotebookState({required this.backend, required this.mediaDir});

  final NotebookBackend backend;

  /// The folder of `photos/`, `thumbs/` and `files/` (the core's `media_dir`).
  final Future<Directory> Function() mediaDir;

  /// After every change that went through.
  VoidCallback? onChanged;

  /// Private notebooks included in sync and sharing; null where there is no sync.
  PrivateSharing? privateSharing;

  List<Notebook> _notebooks = const [];
  bool _loading = true;
  Object? _error;
  bool _started = false;
  int _revision = 0;

  List<Notebook> get notebooks => _notebooks;
  bool get loading => _loading;

  /// The last read failed ("Notebooks could not open").
  Object? get error => _error;

  /// Goes up with every change.
  int get revision => _revision;

  /// The Log notebooks, most recently used first.
  List<Notebook> get logs => [for (final n in _notebooks) if (n.isLog) n];

  Notebook? notebook(String id) {
    for (final n in _notebooks) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The Places notebook of the saved places, once the core made it (see [ensureSavedPlaces]).
  Notebook? get savedPlaces {
    for (final n in _notebooks) {
      if (n.savedPlaces) return n;
    }
    return null;
  }

  /// The saved places' notebook, made by the core the first time.
  Future<Notebook> ensureSavedPlaces() async {
    final have = savedPlaces;
    if (have != null) return have;
    return _change(() async => Notebook.fromJson(await backend.call('saved_places')));
  }

  /// Reads a map layer file (KML, KMZ, GPX, GeoJSON) into a Places notebook ([notebookId], else a new one named after the
  /// file): its points become places. The core's answer: `{"notebook","places","lines","areas","skipped"}`.
  Future<Map<String, dynamic>> importPlaces(String path, {String? notebookId, required String now}) =>
      _change(() => backend.call('import', {'path': path, 'notebook_id': ?notebookId, 'now': now}));

  /// The notebook `notebook.add_journal_entry` writes to: the most recently used one of the Journal template.
  Notebook? get journal {
    for (final n in _notebooks) {
      if (n.template == 'journal') return n;
    }
    return null;
  }

  /// Reads the list the first time; later calls do nothing.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await reload();
  }

  Future<void> reload() async {
    try {
      final r = await backend.call('notebooks');
      _notebooks = [for (final n in r['notebooks'] as List) Notebook.fromJson(n as Map)];
      _error = null;
    } catch (e) {
      _error = e;
      debugPrint('cache notebooks: could not read ($e)');
    }
    _loading = false;
    notifyListeners();
  }

  Future<T> _change<T>(Future<T> Function() f) async {
    final r = await f();
    _revision++;
    await reload();
    onChanged?.call();
    return r;
  }

  // ---- notebooks ----

  /// Makes a notebook (no [id]) or replaces its definition and switches. A name another notebook has is refused by the core.
  Future<Notebook> saveNotebook({String? id, String? template, required NotebookDef def, bool? private, bool? map, String? templateRef}) =>
      _change(() async => Notebook.fromJson(await backend.call('notebook_save', {
            'id': ?id,
            'template': ?template,
            'def': def.toJson(),
            'private': ?private,
            'map': ?map,
            'template_ref': ?templateRef,
          })));

  Future<void> deleteNotebook(String id) => _change(() => backend.call('notebook_delete', {'id': id}));

  /// Shows or hides a notebook's entries on the map.
  Future<void> setOnMap(Notebook n, bool on) => saveNotebook(id: n.id, def: n.def, map: on);

  /// True when another notebook than [exceptId] is called [name] (ignoring case and spacing).
  bool nameTaken(String name, {String? exceptId}) {
    final n = name.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
    return _notebooks.any((x) => x.id != exceptId && x.name.toLowerCase() == n);
  }

  // ---- entries ----

  /// A notebook's entries, newest first, drafts included.
  Future<List<NbEntry>> entries(String notebookId) async =>
      [for (final e in (await backend.call('entries', {'notebook_id': notebookId}))['entries'] as List) NbEntry.fromJson(e as Map)];

  Future<NbEntry?> entry(String id) async {
    try {
      return NbEntry.fromJson(await backend.call('entry', {'id': id}));
    } on CacheSearchException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
  }

  /// Saves the whole entry (a new one when [id] is null) and returns it as stored.
  Future<NbEntry> saveEntry({
    String? id,
    required String notebookId,
    required String occurredAt,
    String? title,
    String? body,
    Map<String, dynamic> values = const {},
    NbPlace? place,
    List<NbPhoto> photos = const [],
    List<NbFile> files = const [],
    bool draft = false,
    bool private = false,
    Map<String, dynamic> props = const {},
  }) =>
      _change(() async => NbEntry.fromJson(await backend.call('entry_save', {
            'id': ?id,
            'notebook_id': notebookId,
            'occurred_at': occurredAt,
            'title': ?title,
            'body': ?body,
            'values': values,
            'place': place?.toJson(),
            'photos': [for (final p in photos) p.toJson()],
            'files': [for (final f in files) f.toJson()],
            'draft': draft,
            'private': private,
            if (props.isNotEmpty) 'props': props,
          })));

  final Set<String> _hidden = {};

  /// Entries deleted with an Undo still on screen: the lists leave them out until the delete is done or undone.
  bool isHidden(String entryId) => _hidden.contains(entryId);

  void hide(String entryId) {
    if (_hidden.add(entryId)) notifyListeners();
  }

  void unhide(String entryId) {
    if (_hidden.remove(entryId)) notifyListeners();
  }

  Future<void> deleteEntry(String id) => _change(() => backend.call('entry_delete', {'id': id}));

  // ---- search and map ----

  Future<List<NbHit>> search(String query, {String? notebookId}) async {
    if (query.trim().isEmpty) return const [];
    final r = await backend.call('search', {'query': query, 'notebook_id': ?notebookId});
    return [
      for (final h in r['hits'] as List) NbHit(NbEntry.fromJson((h as Map)['entry'] as Map), '${h['notebook'] ?? ''}', '${h['snippet'] ?? ''}'),
    ];
  }

  /// The entries with a place of the notebooks on the map (or of [notebookId]).
  Future<List<NbEntry>> pins({String? notebookId}) async =>
      [for (final e in (await backend.call('pins', {'notebook_id': ?notebookId}))['entries'] as List) NbEntry.fromJson(e as Map)];

  // ---- photos and files ----

  Future<File> photoFile(String id) async => File('${(await mediaDir()).path}/photos/$id.jpg');
  Future<File> thumbFile(String id) async => File('${(await mediaDir()).path}/thumbs/$id.jpg');
  Future<File> attachedFile(String id) async => File('${(await mediaDir()).path}/files/$id');
}
