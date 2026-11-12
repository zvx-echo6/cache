import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart' show CacheSearchException, SearchCore;
import 'package:flutter/foundation.dart';

import '../files.dart';
import 'notebook_model.dart';
import '../app_fs.dart';
import '../platform.dart' as plat;
import '../platform/app_log.dart';

/// One step of moving what is kept under a notebook's old id to its new id (see [NotebookState.reidNotebook]); it can run again.
typedef ReidStep = Future<void> Function(String oldId, String newId);

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

  /// A notebook got another id (linked devices settling on one): what is kept under the old id moves to the new one.
  Future<void> notebookReid(String oldId, String newId);
}

/// What the Notebooks screens show: the notebooks, most recently used first. Every change goes through the core and the list is
/// read again; [revision] counts the changes (an open notebook reads its entries again), and [onChanged] runs after each one.
class NotebookState extends ChangeNotifier {
  NotebookState({required this.backend, required this.mediaDir, AppFs? fs}) : _fsOverride = fs;

  final AppFs? _fsOverride;

  /// How a browser reaches the media folder on Cache Server (`<support>/notebook`, the same folder the core and sync use).
  late final AppFs webFs = _fsOverride ?? createAppFs();

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
      logError('Notebooks could not be read', error: e);
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
  ///
  /// [fromSync] is notebook sync applying what another device did: the store then lifts the cap of 12 visible fields and the one-label
  /// rule, and lets a field's type change when no entry holds a value for it.
  Future<Notebook> saveNotebook({String? id, String? template, required NotebookDef def, bool? private, bool? map, String? templateRef, bool fromSync = false}) =>
      _change(() async => Notebook.fromJson(await backend.call('notebook_save', {
            'id': ?id,
            if (fromSync) 'from_sync': true,
            'template': ?template,
            'def': def.toJson(),
            'private': ?private,
            'map': ?map,
            'template_ref': ?templateRef,
          })));

  // ---- a notebook's id changes ----

  /// Where the re-id journal is kept (app support); null where there is no sync (tests set it).
  File? reidJournal;

  /// What else keeps notebook ids, in the order it is moved to the new id after the core has it: each step saves what it holds
  /// and can be run again. Registered by the app (shortcuts, the sync connections' field names).
  final Map<String, ReidStep> reidSteps = {};

  final StreamController<({String oldId, String newId})> _reids = StreamController.broadcast();

  /// A notebook has another id now (open screens and editors follow).
  Stream<({String oldId, String newId})> get reids => _reids.stream;

  /// Gives a notebook another id. Linked devices that each made the same notebook settle on one id this way, so it runs on every
  /// upgrade and whenever a device with a lower id joins; it is a journaled, resumable path. The journal (`reid-journal.json`) is a
  /// queue: this change is added to it (old, new, step names) and the queue is worked through in order. Each change runs its steps,
  /// each able to run again: the core (the notebook, its entries, the Places link and the map layer), private sharing, the
  /// registered [reidSteps], and [also] (steps only this call knows). A change leaves the queue only after every step saved, and
  /// the file goes when the queue is empty. A failure, here or at start, keeps the queue, sets [replayError] (notebook sync waits
  /// and says so) and is thrown; [replayReid] finishes the queue, so a change that failed and the next one both complete.
  Future<Notebook> reidNotebook(String id, String newId, {Map<String, ReidStep> also = const {}}) async {
    if (id == newId) return notebook(id)!;
    final q = await _readQueue();
    final item = {'old': id, 'new': newId, 'steps': ['core', 'private sharing', ...reidSteps.keys, ...also.keys]};
    q.add(item);
    await _writeQueue(q);
    _alsoFor[newId] = also;
    await _drain();
    return notebook(newId)!;
  }

  /// Set when a notebook id change could not be finished (at start or while the app runs): the queue is kept, notebook sync waits
  /// (a state is shown) and the change is tried again at the next sync. Null when nothing waits.
  Object? replayError;

  final Map<String, Map<String, ReidStep>> _alsoFor = {};
  List<Map<String, dynamic>> _memQueue = [];

  /// Finishes the notebook id changes a kill or a failure left half done. Called at start, after what keeps ids is wired (private
  /// sharing, the registered steps) and before any notebook sync. A journal that cannot be read is never dropped: the error is kept
  /// in [replayError] and thrown.
  Future<void> replayReid() async {
    final f = reidJournal;
    if (f != null && !await f.exists() && _memQueue.isEmpty) {
      replayError = null;
      return;
    }
    await _drain();
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    final f = reidJournal;
    if (f == null) return [..._memQueue];
    if (!await f.exists()) return [];
    final Object? j;
    try {
      j = jsonDecode(await f.readAsString());
    } on FormatException catch (e) {
      throw StateError('the re-id journal could not be read: ${e.message}');
    }
    // The queue; or the single change an earlier build wrote.
    final list = j is Map && j['items'] is List ? j['items'] as List : (j is Map && j['old'] is String ? [j] : null);
    if (list == null) throw StateError('the re-id journal is not one');
    return [
      for (final x in list)
        if (x is Map && x['old'] is String && x['new'] is String) x.cast<String, dynamic>() else throw StateError('the re-id journal is not one'),
    ];
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> q) async {
    final f = reidJournal;
    if (f == null) {
      _memQueue = [...q];
      return;
    }
    if (q.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await writeStringAtomic(f, jsonEncode({'items': q}));
  }

  /// Runs the queue in order. Any failure keeps what is left, records [replayError] and is thrown.
  Future<void> _drain() async {
    try {
      var q = await _readQueue();
      while (q.isNotEmpty) {
        final item = q.first;
        await _reidRun(item['old'] as String, item['new'] as String, _alsoFor[item['new']] ?? const {});
        q = await _readQueue();
        if (q.isNotEmpty && q.first['old'] == item['old'] && q.first['new'] == item['new']) q.removeAt(0);
        await _writeQueue(q);
        _alsoFor.remove(item['new']);
      }
      replayError = null;
    } catch (e) {
      replayError = e;
      logError('A notebook id change could not be finished; it is kept to be finished', error: e);
      rethrow;
    }
  }

  Future<Notebook> _reidRun(String id, String newId, Map<String, ReidStep> also) async {
    final n = await _change(() async => Notebook.fromJson(await backend.call('notebook_reid', {'id': id, 'new_id': newId})));
    _reids.add((oldId: id, newId: newId));
    await privateSharing?.notebookReid(id, newId);
    for (final s in [...reidSteps.values, ...also.values]) {
      await s(id, newId);
    }
    return n;
  }

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
  /// The ~1600 px local preview of a photo (kept on this device only; a photo may not have one).
  Future<File> previewFile(String id) async => File('${(await mediaDir()).path}/previews/$id.jpg');
  Future<File> thumbFile(String id) async => File('${(await mediaDir()).path}/thumbs/$id.jpg');
  Future<File> attachedFile(String id) async => File('${(await mediaDir()).path}/files/$id');

  // A browser cannot open a File of the server; it reads the same media folder (`notebook/` under the support root) as bytes.
  static String photoRel(String id) => 'notebook/photos/$id.jpg';
  static String thumbRel(String id) => 'notebook/thumbs/$id.jpg';
  static String attachedRel(String id) => 'notebook/files/$id';

  /// A photo's thumbnail bytes, null when it is not there. Phone: the file; browser: the server's media folder.
  Future<Uint8List?> thumbBytes(String id) async {
    if (plat.isWeb) return webFs.readBytes(AppRoot.support, thumbRel(id));
    final f = await thumbFile(id);
    return f.existsSync() ? f.readAsBytes() : null;
  }

  /// An attached file's bytes, null when it is not there.
  Future<Uint8List?> attachedBytes(String id) async {
    if (plat.isWeb) return webFs.readBytes(AppRoot.support, attachedRel(id));
    final f = await attachedFile(id);
    return f.existsSync() ? f.readAsBytes() : null;
  }
}
