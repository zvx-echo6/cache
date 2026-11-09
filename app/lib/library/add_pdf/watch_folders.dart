import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:saf_util/saf_util.dart';

import '../../notebook/sync/folder.dart' show FolderFile, IoFolder;
import '../../notebook/sync/folder_access.dart' show openSyncFolder;
import '../../notebook/sync/saf_stream_shim.dart';
import '../../platform/app_log.dart';
import '../../search/index_scheduler.dart';
import '../../search/index_throttle.dart' show IndexDuty;
import 'add_pdf_state.dart';

/// The kind of a watched folders check in the index scheduler, before the "/" of its key.
const String kWatchCheckKind = 'watch-check';

/// How often Android checks the watched folders by itself (as index work: it follows the indexing rules).
const Duration kWatchEvery = Duration(minutes: 30);

/// The app's watched folders, set at start; null in tests that do not need them and on the web.
WatchFoldersState? watchFoldersShared;

/// A PDF a watched folder found that could not be added (damaged, locked, no readable text): skipped, counted on the folder's
/// card ("1 couldn't be added", Try again), and never tried again by a check by itself.
class WatchSkip {
  const WatchSkip({required this.path, required this.name, required this.hash, this.jobId, this.bytes = 0});

  /// Its path inside the folder.
  final String path;
  final String name;
  final String hash;
  final int bytes;

  /// The Add PDF job that stopped (it may since have been put away on the progress page).
  final String? jobId;

  Map<String, dynamic> toJson() => {'path': path, 'name': name, 'hash': hash, 'bytes': bytes, 'job': ?jobId};

  static WatchSkip fromJson(Map<String, dynamic> j) => WatchSkip(
    path: (j['path'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    hash: (j['hash'] ?? '') as String,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    jobId: j['job'] as String?,
  );
}

/// A file a check has seen: its size and time (a file unchanged since is not read again) and its content hash.
typedef WatchKnown = ({int size, int mtime, String hash});

/// One watched folder: where it is (an Android tree URI with a kept permission, an iOS security-scoped bookmark, else a path), the
/// library its PDFs go to, and what its checks have seen. A file is known by its content (SHA-256), not its path: a renamed or
/// moved PDF is not added again, and a PDF removed from the folder stays in Cache.
class WatchedFolder {
  WatchedFolder({
    required this.id,
    required this.root,
    required this.name,
    required this.where,
    required this.libraryTitle,
    this.libraryPath,
    required this.since,
  });

  final String id;
  String root;
  String name;

  /// Where it is, as the list says it: "Download/Manuals".
  String where;
  String? libraryPath;
  String libraryTitle;
  final DateTime since;

  /// The last check that reached the folder.
  DateTime? lastCheck;

  /// PDFs added from it so far.
  int added = 0;

  /// The last check could not reach it (moved, renamed, access turned off): checks for it are paused until Choose again.
  bool unreachable = false;

  /// Files seen at the last check, by path inside the folder.
  final Map<String, WatchKnown> files = {};

  /// Every content hash this folder has had: added, skipped, or there when it was watched for new PDFs only.
  final Set<String> hashes = {};

  /// Add PDF jobs queued from it and not finished yet.
  final List<String> pending = [];

  /// PDFs that could not be added.
  final List<WatchSkip> skipped = [];

  /// A check is running now, and how far it is (0 to 1).
  bool checking = false;
  double? checkProgress;

  Map<String, dynamic> toJson() => {
    'id': id,
    'root': root,
    'name': name,
    'where': where,
    'library_path': ?libraryPath,
    'library_title': libraryTitle,
    'since': since.toIso8601String(),
    'last_check': ?lastCheck?.toIso8601String(),
    'added': added,
    'unreachable': unreachable,
    'files': {for (final e in files.entries) e.key: {'size': e.value.size, 'mtime': e.value.mtime, 'hash': e.value.hash}},
    'hashes': hashes.toList(),
    'pending': pending,
    'skipped': [for (final s in skipped) s.toJson()],
  };

  static WatchedFolder fromJson(Map<String, dynamic> j) {
    final f = WatchedFolder(
      id: j['id'] as String,
      root: j['root'] as String,
      name: (j['name'] ?? 'Folder') as String,
      where: (j['where'] ?? '') as String,
      libraryTitle: (j['library_title'] ?? 'My books') as String,
      libraryPath: j['library_path'] as String?,
      since: DateTime.tryParse((j['since'] ?? '') as String) ?? DateTime.now(),
    );
    f
      ..lastCheck = DateTime.tryParse((j['last_check'] ?? '') as String)
      ..added = (j['added'] as num?)?.toInt() ?? 0
      ..unreachable = j['unreachable'] == true;
    for (final e in ((j['files'] as Map?) ?? const {}).entries) {
      final v = e.value;
      if (v is Map && v['hash'] is String) {
        f.files[e.key as String] = (size: (v['size'] as num?)?.toInt() ?? 0, mtime: (v['mtime'] as num?)?.toInt() ?? 0, hash: v['hash'] as String);
      }
    }
    f.hashes.addAll([for (final h in (j['hashes'] as List? ?? const [])) if (h is String) h]);
    f.pending.addAll([for (final p in (j['pending'] as List? ?? const [])) if (p is String) p]);
    f.skipped.addAll([for (final s in (j['skipped'] as List? ?? const [])) if (s is Map) WatchSkip.fromJson(s.cast<String, dynamic>())]);
    return f;
  }
}

/// "Download/Manuals": where a picked folder is, from its stored form (an Android tree URI's document id after the volume, else
/// the name the picker gave, else a path).
String watchWhere(String root, String name) {
  if (root.startsWith('content://')) {
    final last = Uri.decodeComponent(root.split('/').last);
    final at = last.indexOf(':');
    final path = at >= 0 ? last.substring(at + 1) : last;
    return path.isEmpty ? name : path;
  }
  if (root.startsWith('bookmark:')) return name;
  return root;
}

/// How Cache reaches a watched folder's files: the folder access Add a folder and the notebooks use (saf_util and saf_stream for
/// an Android tree, the iOS bookmark resolved to a path, else the path). Tests give plain paths.
class WatchFolderAccess {
  const WatchFolderAccess();

  static List<String> _parts(String rel) => [for (final p in rel.split('/')) if (p.isNotEmpty) p];

  /// Whether the folder can be reached now: on Android it also needs the kept permission.
  Future<bool> reachable(String root) async {
    try {
      if (root.startsWith('content://')) {
        final util = SafUtil();
        if (!await util.hasPersistedPermission(root)) return false;
        return await util.exists(root, true);
      }
      return await (await openSyncFolder(root)).reachable();
    } catch (_) {
      return false;
    }
  }

  /// Every file in it and its subfolders.
  Future<List<FolderFile>> list(String root) async => (await openSyncFolder(root)).list('');

  /// One file now (null when it is gone).
  Future<FolderFile?> stat(String root, String rel) async {
    if (root.startsWith('content://')) {
      final f = await SafUtil().child(root, _parts(rel));
      return f == null || f.isDir ? null : FolderFile(rel, f.lastModified, f.length);
    }
    final folder = await openSyncFolder(root);
    if (folder is! IoFolder) return null;
    final file = File('${folder.root}/$rel');
    if (!await file.exists()) return null;
    final st = await file.stat();
    return FolderFile(rel, st.modified.millisecondsSinceEpoch, st.size);
  }

  /// The file's content hash (SHA-256, hex), read as a stream.
  Future<String> hash(String root, String rel) async {
    if (root.startsWith('content://')) {
      final f = await SafUtil().child(root, _parts(rel));
      if (f == null || f.isDir) throw FileSystemException('The PDF is no longer in the folder', rel);
      final bytes = await SafStream().readFileStream(f.uri, bufferSize: 1 << 20);
      return (await sha256.bind(bytes).first).toString();
    }
    final folder = await openSyncFolder(root);
    if (folder is! IoFolder) throw FileSystemException("Can't reach the folder", root);
    return (await sha256.bind(File('${folder.root}/$rel').openRead()).first).toString();
  }
}

/// A PDF of a folder, by its path inside it: not hidden (no part starts with "."), ending in .pdf.
bool isWatchedPdf(String rel) {
  final parts = rel.split('/');
  if (parts.any((p) => p.startsWith('.'))) return false;
  return rel.toLowerCase().endsWith('.pdf');
}

String _titleOf(String name) => name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');

/// Watched folders: what each holds, its checks, and the Add PDF jobs its new PDFs became. A check lists the folder, reads (hashes)
/// only files it has not seen with that size and time, and queues each PDF whose content is new through Add PDF, one at a time,
/// tagged with the folder. Checks run when Cache opens, on Check now, and on Android every [every] as index work (charging,
/// battery and heat, like every index job). A PDF that could not be added is skipped and counted, not tried again by itself.
class WatchFoldersState extends ChangeNotifier implements IndexWorkSource {
  WatchFoldersState({required this.addPdf, required this.dir, this.access = const WatchFolderAccess(), this.every, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    addPdf.addListener(_onJobs);
  }

  final AddPdfState addPdf;

  /// Where `watched.json` lives (`<support>/ingest`); null when there is none.
  final Future<Directory?> Function() dir;
  final WatchFolderAccess access;

  /// How often a check is due as index work; null where folders are checked only on open (iOS).
  final Duration? every;
  final DateTime Function() _clock;

  final List<WatchedFolder> _folders = [];
  bool _loaded = false;
  int _lastId = 0;
  bool _disposed = false;

  /// One check at a time (two would read the same files twice).
  Future<void> _lock = Future.value();

  /// The index work's check asked to stop (Cache went to the background, the battery ran low).
  bool _stopRun = false;

  List<WatchedFolder> get folders => List.unmodifiable(_folders);
  WatchedFolder? byId(String id) => _folders.where((f) => f.id == id).firstOrNull;

  /// The folders that can't be reached.
  int get unreachable => _folders.where((f) => f.unreachable).length;

  /// The most recent check of any folder.
  DateTime? get lastCheck {
    DateTime? t;
    for (final f in _folders) {
      final c = f.lastCheck;
      if (c != null && (t == null || c.isAfter(t))) t = c;
    }
    return t;
  }

  DateTime get now => _clock();

  /// Tests and renders: the folders are [folders], as they are.
  @visibleForTesting
  void debugSet(List<WatchedFolder> folders) {
    _loaded = true;
    _folders
      ..clear()
      ..addAll(folders);
    notifyListeners();
  }

  Future<File?> _file() async {
    final d = await dir();
    return d == null ? null : File('${d.path}${Platform.pathSeparator}watched.json');
  }

  /// Reads the folders kept on disk (once), and the Add PDF jobs, so a job that ended while Cache was closed is counted.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (f != null && f.existsSync()) {
        final j = jsonDecode(await f.readAsString()) as Map;
        for (final e in (j['folders'] as List? ?? const [])) {
          try {
            _folders.add(WatchedFolder.fromJson((e as Map).cast<String, dynamic>()));
          } catch (e) {
            logError('Watch a folder: a kept folder could not be read', error: e);
          }
        }
      }
    } catch (e) {
      logError('Watch a folder: the list could not be read', error: e);
    }
    await addPdf.load();
    _onJobs();
    notifyListeners();
  }

  /// Reads the folders from disk again (a background run changed them while Cache was in the background). Only while no check runs.
  Future<void> reload() async {
    if (_folders.any((f) => f.checking)) return;
    _loaded = false;
    _folders.clear();
    await load();
  }

  Future<void>? _saving;
  bool _saveAgain = false;

  /// Writes the list (one write at a time; a change during it writes once more after it).
  Future<void> save() {
    if (_saving != null) {
      _saveAgain = true;
      return _saving!;
    }
    return _saving = () async {
      try {
        do {
          _saveAgain = false;
          final f = await _file();
          if (f == null) return;
          await f.parent.create(recursive: true);
          final tmp = File('${f.path}.tmp');
          await tmp.writeAsString(jsonEncode({'folders': [for (final w in _folders) w.toJson()]}), flush: true);
          await tmp.rename(f.path);
        } while (_saveAgain);
      } catch (e) {
        logError('Watch a folder: the list could not be written', error: e);
      } finally {
        _saving = null;
      }
    }();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String _newId() {
    final t = _clock().microsecondsSinceEpoch;
    _lastId = t > _lastId ? t : _lastId + 1;
    return _lastId.toRadixString(36);
  }

  /// The jobs the folders queued, as they end: added (counted), stopped (skipped and counted), put away while being added (the
  /// person cancelled it: not counted, not tried again), or tried again on the progress page (pending again).
  void _onJobs() {
    if (!_loaded) return;
    var changed = false;
    for (final f in _folders) {
      for (final id in f.pending.toList()) {
        final j = addPdf.byId(id);
        if (j == null) {
          f.pending.remove(id);
          changed = true;
        } else if (j.status == AddPdfStatus.done) {
          f.pending.remove(id);
          f.added++;
          if (f.libraryPath == null) {
            f.libraryPath = j.libraryPath;
            f.libraryTitle = j.libraryTitle;
          }
          changed = true;
        } else if (j.status == AddPdfStatus.failed) {
          f.pending.remove(id);
          f.skipped.add(WatchSkip(path: j.sourcePath ?? j.fileName, name: j.fileName, hash: j.watchHash ?? '', jobId: j.id, bytes: j.bytes));
          logInfo('Watch a folder: a PDF could not be added (${j.errorCode}); skipped', job: j.key);
          changed = true;
        }
      }
      // a stopped job tried again on the progress page is pending again
      for (final s in f.skipped.toList()) {
        final j = s.jobId == null ? null : addPdf.byId(s.jobId!);
        if (j != null && j.status == AddPdfStatus.active) {
          f.skipped.remove(s);
          f.pending.add(j.id);
          changed = true;
        }
      }
    }
    if (changed) {
      unawaited(save());
      _changed();
    }
  }

  /// Starts watching the folder the person chose ([root], named [name]) for [target]. [addExisting]: the PDFs in it now are added
  /// too ("Watch and add 12 PDFs"); else they are only noted, and only PDFs that come later are added ("Watch new PDFs only").
  /// The first check runs at once.
  Future<WatchedFolder> watch({required String root, required String name, required AddPdfTarget target, required bool addExisting}) async {
    await load();
    final f = WatchedFolder(
      id: _newId(),
      root: root,
      name: name,
      where: watchWhere(root, name),
      libraryTitle: target.title,
      libraryPath: target.path,
      since: _clock(),
    );
    _folders.add(f);
    await save();
    logInfo('Watch a folder: watching a folder (${addExisting ? 'adding what is in it' : 'new PDFs only'})');
    _changed();
    unawaited(check(f, addExisting: addExisting));
    return f;
  }

  /// Stop watching: the folder is forgotten; what was added from it stays, and PDFs already queued from it are still added.
  Future<void> stop(WatchedFolder f) async {
    _folders.remove(f);
    _changed();
    logInfo('Watch a folder: stopped watching a folder');
    await save();
  }

  /// Choose again: the same folder picked again, or another. Its library, count and history are kept; what it already added is not
  /// added again (known by content); the check runs at once and adds what is new.
  Future<void> chooseAgain(WatchedFolder f, {required String root, required String name}) async {
    f
      ..root = root
      ..name = name
      ..where = watchWhere(root, name)
      ..unreachable = false;
    // paths are inside the folder: a new pick starts its paths afresh (the hashes stay)
    f.files.clear();
    await save();
    _changed();
    await check(f);
  }

  /// Try again for the PDFs a folder could not add: each is queued once more (its stopped job tried again, or a new job when that was
  /// put away).
  Future<void> tryAgain(WatchedFolder f) async {
    final skips = f.skipped.toList();
    f.skipped.clear();
    final checkId = _newId();
    for (final s in skips) {
      final j = s.jobId == null ? null : addPdf.byId(s.jobId!);
      if (j != null && j.status == AddPdfStatus.failed) {
        f.pending.add(j.id);
        await addPdf.retry(j);
      } else {
        await _queue(f, FolderFile(s.path, 0, s.bytes), s.hash, checkId);
      }
    }
    await save();
    _changed();
  }

  /// Checks every folder that can be reached (when Cache opens). [minGap]: a folder checked more recently than that is left.
  Future<void> checkAll({Duration? minGap}) async {
    await load();
    for (final f in _folders.toList()) {
      if (f.unreachable) continue;
      final last = f.lastCheck;
      if (minGap != null && last != null && _clock().difference(last) < minGap) continue;
      await check(f);
    }
  }

  /// Checks [f] now (Check now, when Cache opens, the index work): new PDFs are queued as they are found. [addExisting] false
  /// only for the first check of "Watch new PDFs only".
  Future<void> check(WatchedFolder f, {bool addExisting = true}) {
    final run = _lock.then((_) => _check(f, addExisting: addExisting));
    _lock = run.catchError((_) {});
    return run;
  }

  Future<void> _check(WatchedFolder f, {required bool addExisting}) async {
    if (!_folders.contains(f) || _disposed) return;
    f
      ..checking = true
      ..checkProgress = 0;
    _changed();
    var found = 0;
    try {
      if (!await access.reachable(f.root)) {
        if (!f.unreachable) logInfo("Watch a folder: a folder can't be reached; checks for it are paused");
        f.unreachable = true;
        return;
      }
      final listed = [for (final x in await access.list(f.root)) if (isWatchedPdf(x.path)) x];
      f.unreachable = false;
      final listedPaths = {for (final x in listed) x.path};
      // only what is new or changed since the last check is read
      final toRead = <FolderFile>[];
      for (final x in listed) {
        final k = f.files[x.path];
        if (k == null || k.size != x.size || k.mtime != x.mtime) toRead.add(x);
      }
      final checkId = _newId();
      var done = 0;
      for (final x in toRead) {
        if (_disposed || !_folders.contains(f)) return;
        String hash;
        try {
          hash = await access.hash(f.root, x.path);
          // still being written (a download, a copy): left for the next check
          final again = await access.stat(f.root, x.path);
          if (again == null || again.size != x.size || again.mtime != x.mtime) continue;
        } catch (e) {
          logError('Watch a folder: a file could not be read', error: e);
          continue;
        } finally {
          done++;
          f.checkProgress = done / toRead.length;
          _changed();
        }
        f.files[x.path] = (size: x.size, mtime: x.mtime, hash: hash);
        // known by content: a renamed or moved PDF, or a second copy in the folder, is not added again
        if (f.hashes.add(hash) && addExisting) {
          await _queue(f, x, hash, checkId);
          found++;
        }
      }
      // a PDF removed from the folder stays in Cache; only its path is forgotten (its hash stays known)
      f.files.removeWhere((k, _) => !listedPaths.contains(k));
      f.lastCheck = _clock();
    } catch (e) {
      // the folder could not be listed (access turned off since)
      logError("Watch a folder: a folder can't be reached", error: e);
      f.unreachable = true;
    } finally {
      f
        ..checking = false
        ..checkProgress = null;
      if (found > 0) logInfo('Watch a folder: a check found $found new PDFs');
      await save();
      _changed();
    }
  }

  Future<void> _queue(WatchedFolder f, FolderFile x, String hash, String checkId) async {
    final name = x.path.split('/').last;
    final job = await addPdf.add(
      pdfPath: x.path,
      fileName: name,
      bytes: x.size,
      title: _titleOf(name),
      target: AddPdfTarget(title: f.libraryTitle, path: f.libraryPath, isDefault: f.libraryPath == null),
      ownsFile: true,
      folderRoot: f.root,
      watchId: f.id,
      watchName: f.name,
      checkId: checkId,
      watchHash: hash,
    );
    if (f.libraryPath == null) {
      f.libraryPath = job.libraryPath;
      f.libraryTitle = job.libraryTitle;
    }
    f.pending.add(job.id);
  }

  // ---- the index work (Android): a check every [every], under the indexing rules

  /// The folders a check is due for: reachable, not checking, not checked within [every].
  List<WatchedFolder> get due {
    final e = every;
    if (e == null) return const [];
    final t = _clock();
    return [
      for (final f in _folders)
        if (!f.unreachable && !f.checking && (f.lastCheck == null || t.difference(f.lastCheck!) >= e)) f,
    ];
  }

  @override
  Future<List<IndexTask>> pending() async {
    await load();
    final d = due;
    if (d.isEmpty) return const [];
    return [
      IndexTask(
        key: '$kWatchCheckKind/folders',
        title: 'Watched folders',
        // long work: it waits for charging (or more than half a battery), pauses when the battery is low or the phone is warm
        long: true,
        // before the PDFs it may queue
        uses: 1 << 31,
        progress: () {
          final c = _folders.where((f) => f.checking).firstOrNull;
          return c == null ? null : (((c.checkProgress ?? 0) * 1000).round(), 1000);
        },
        pulse: () => [for (final f in _folders) (f.checking, f.checkProgress)].toString(),
        step: () => 'Checking for new PDFs',
        start: () async => _WatchCheckRun(this, d),
      ),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    addPdf.removeListener(_onJobs);
    super.dispose();
  }
}

/// The index work's check: each due folder in turn; it stops between folders when the scheduler pauses it.
class _WatchCheckRun implements IndexRun {
  _WatchCheckRun(this.state, this.folders) {
    state._stopRun = false;
    unawaited(_go());
  }

  final WatchFoldersState state;
  final List<WatchedFolder> folders;
  final Completer<bool> _done = Completer<bool>();

  @override
  Future<bool> get finished => _done.future;

  Future<void> _go() async {
    try {
      for (final f in folders) {
        if (state._stopRun) break;
        await state.check(f);
      }
    } catch (e) {
      logError('Watch a folder: the check broke', error: e);
    }
    if (!_done.isCompleted) _done.complete(!state._stopRun);
  }

  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    state._stopRun = true;
    await _done.future;
  }

  @override
  void setDuty(IndexDuty duty) {}
}
