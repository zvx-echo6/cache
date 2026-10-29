import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../browse/zim_download.dart';
import '../files.dart';
import '../settings/data_policy.dart';
import 'sources_state.dart';

/// The settings file of a library (docs/LIBRARY-FORMAT.md): inside a .cache-library archive, and beside the library here.
const String kLibrarySettingsFile = 'cache-library.json';

/// The name the blank template is saved under.
const String kLibraryTemplateName = 'cache-library-template.tar';

/// One library on the device: a folder in the libraries folder holding `shard/` (the unpacked Qdrant shard), `index/` (its
/// keyword index, when one is built on the device) and `cache-library.json` (its settings, when it came with them; without
/// it the core works them out each time it opens the library).
class LibraryItem {
  LibraryItem({required this.dir, this.settings, this.size = 0});

  final Directory dir;
  final Map<String, dynamic>? settings;

  /// Bytes on the disk, shard and index together.
  int size;

  String get shardPath => '${dir.path}${Platform.pathSeparator}shard';
  String get indexPath => '${dir.path}${Platform.pathSeparator}index';
  String get folderName => dir.path.split(RegExp(r'[\\/]')).last;

  /// The source the core is given for this library.
  SourceConfig get config => SourceConfig.library(path: shardPath, indexDir: indexPath, settings: settings);
}

/// Where a library stands.
enum LibraryPhase { waiting, opening, indexing, ready, failed }

/// What the add (or update) under way is doing.
enum AddStep { downloading, unpacking, checking, indexing, swapping }

/// The library being added, shown on the Libraries screen while it runs, and after it failed.
class AddTask {
  AddTask(this.name);

  final String name;
  AddStep step = AddStep.unpacking;
  double? fraction;
  String? error;

  /// Downloads only: the phone is on mobile data and downloads on it are off. "Download anyway" repeats the add.
  bool blockedByMobileData = false;
  String? link;
  bool cancelled = false;
  CancelToken? token;
  CoreJobHandle? job;
  bool get running => error == null;
}

/// Picks a file on the device and returns its path (or null when the person cancelled).
typedef PickPath = Future<String?> Function();

/// Hands the bytes of a file to the system's save dialog; true when it was saved.
typedef SaveBytes = Future<bool> Function(String fileName, Uint8List bytes);

/// Asks whether to update the library [name] from version [from] to version [to] (either may be null).
typedef ConfirmUpdate = Future<bool> Function(String name, String? from, String? to);

/// Asks for the settings file of a library that came without one; returns its path, or null to stop.
typedef AskSettings = Future<String?> Function(String reason);

/// The libraries on this device (Qdrant collections Cache searches, docs/LIBRARY-FORMAT.md): added from a file or a download
/// link, replaced by a newer copy of the same library, removed, and the blank template. The search core that reads them is
/// [sources]'s; this class gives it the libraries' source entries and runs the core's library jobs.
class LibrariesState extends ChangeNotifier {
  LibrariesState({
    required this.sources,
    this.policy,
    ZimDownloader? downloader,
    this.dirOverride,
    this.tempDirOverride,
    PickPath? pickFile,
    SaveBytes? saveBytes,
    this.pollInterval = const Duration(milliseconds: 250),
  })  : downloader = downloader ?? ZimDownloader(),
        _pickFile = pickFile ?? _pickWithPicker,
        _saveBytes = saveBytes ?? _saveWithPicker {
    sources.librarySources = () => [
          for (final l in libraries)
            if (!_closed.contains(l.dir.path)) l.config,
        ];
    sources.addListener(_onSources);
  }

  final SourcesState sources;

  /// The mobile data rule for downloads; null: no rule.
  final DataPolicy? policy;
  final ZimDownloader downloader;
  final Directory? dirOverride;
  final Directory? tempDirOverride;
  final PickPath _pickFile;
  final SaveBytes _saveBytes;
  final Duration pollInterval;

  /// The libraries folder (null until [init]).
  Directory? dir;
  List<LibraryItem> libraries = [];

  /// The add under way, or the last one that failed (until dismissed).
  AddTask? task;

  /// The last problem to show (remove or template), or null.
  String? error;

  /// True while the template is being made and saved.
  bool makingTemplate = false;

  /// Libraries taken out of the core's list for a moment (while one is swapped or removed), by folder path.
  final Set<String> _closed = {};

  /// Keyword index jobs of installed libraries (one whose index was not finished, for example when the app was closed).
  final Map<String, CoreJobHandle> _indexJobs = {};
  final Map<String, double?> _indexProgress = {};
  final Map<String, String> _indexFailed = {};

  /// The index builds [_resumeIndexes] started, until they end.
  final Set<Future<void>> _pending = {};
  bool _disposed = false;

  /// Ends when the index builds started at start have ended (for tests).
  Future<void> whenIdle() => Future.wait(_pending.toList());

  Future<void> init() async {
    final base = dirOverride ??
        Directory(
          '${((Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}libraries',
        );
    await base.create(recursive: true);
    dir = base;
    _recoverLeftovers();
    await _scan();
    notifyListeners();
    final core = await sources.whenCoreReady();
    if (core == null) return;
    await sources.refresh();
    _resumeIndexes();
  }

  Directory get _partialDir => Directory('${dir!.path}${Platform.pathSeparator}.partial');

  String _child(String name) => '${dir!.path}${Platform.pathSeparator}$name';

  /// What an add or a swap that was cut off (the app closed or crashed) left in the folder: a half-made new library is
  /// deleted; the old copy of a library being swapped comes back if the new one did not get into place, else it is deleted.
  void _recoverLeftovers() {
    try {
      for (final d in dir!.listSync().whereType<Directory>()) {
        final name = d.path.split(RegExp(r'[\\/]')).last;
        if (name.startsWith('.add-')) {
          _deleteQuietly(d);
        } else if (name.startsWith('.') && name.endsWith('.old')) {
          final real = Directory(_child(name.substring(1, name.length - 4)));
          if (real.existsSync()) {
            _deleteQuietly(d);
          } else {
            try {
              d.renameSync(real.path);
            } catch (e) {
              debugPrint('Could not restore ${d.path}: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Libraries folder: $e');
    }
  }

  static void _deleteQuietly(FileSystemEntity e) {
    try {
      if (e.existsSync()) e.deleteSync(recursive: true);
    } catch (err) {
      debugPrint('Could not remove ${e.path}: $err');
    }
  }

  Future<void> _scan() async {
    final found = <LibraryItem>[];
    for (final d in dir!.listSync().whereType<Directory>()) {
      final name = d.path.split(RegExp(r'[\\/]')).last;
      if (name.startsWith('.') || !Directory('${d.path}${Platform.pathSeparator}shard').existsSync()) continue;
      Map<String, dynamic>? settings;
      try {
        final f = File('${d.path}${Platform.pathSeparator}$kLibrarySettingsFile');
        if (f.existsSync()) settings = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      } catch (e) {
        debugPrint('Library settings of $name: $e');
      }
      found.add(LibraryItem(dir: d, settings: settings, size: await _treeSize(d)));
    }
    found.sort((a, b) => titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase()));
    libraries = found;
  }

  static Future<int> _treeSize(Directory d) async {
    var n = 0;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) n += await e.length();
      }
    } catch (_) {}
    return n;
  }

  void _onSources() => notifyListeners();

  SourceStatus? statusOf(LibraryItem l) => sources.statusAt(l.shardPath);

  /// The library's own name: the core's, else its settings', else its folder's.
  String titleOf(LibraryItem l) {
    final t = statusOf(l)?.title;
    if (t != null && t.isNotEmpty && statusOf(l)?.id != null) return t;
    final s = l.settings?['title'];
    if (s is String && s.isNotEmpty) return s;
    return l.folderName;
  }

  /// The library's id (cache-library.json's library_id): the core's, else its settings'.
  String? idOf(LibraryItem l) => statusOf(l)?.id ?? (l.settings?['library_id'] as String?);

  /// The builder's version label of this copy, or null.
  String? versionOf(LibraryItem l) => _version(l.settings);

  static String? _version(Map<String, dynamic>? settings) {
    final v = settings?['version'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is int) return '$v';
    return null;
  }

  /// Entries (points) in the library, once it is open.
  int docsOf(LibraryItem l) => statusOf(l)?.docs ?? 0;

  /// True when the library can only be updated as a whole (its entries carry no document ids); null until it is open.
  bool? wholeLibraryOnly(LibraryItem l) => statusOf(l)?.wholeLibraryOnly;

  /// The embedding model its settings name, or null.
  String? modelOf(LibraryItem l) {
    final e = l.settings?['embedding'];
    final m = e is Map ? e['model'] : null;
    return m is String && m.isNotEmpty ? m : null;
  }

  bool _keywordOff(LibraryItem l) => (l.settings?['keyword_index'] ?? 'auto') == 'off';

  LibraryPhase phaseOf(LibraryItem l) {
    if (_indexFailed.containsKey(l.dir.path)) return LibraryPhase.failed;
    final s = statusOf(l);
    if (s == null) return LibraryPhase.waiting;
    if (s.error != null) return LibraryPhase.failed;
    if (s.opening || s.updating) return LibraryPhase.opening;
    if (_indexJobs.containsKey(l.dir.path) || s.building) return LibraryPhase.indexing;
    if (s.indexed || _keywordOff(l)) return LibraryPhase.ready;
    return LibraryPhase.waiting;
  }

  double? indexFraction(LibraryItem l) => _indexProgress[l.dir.path];

  /// Why the library cannot be used, in words for people.
  String? failureOf(LibraryItem l) => _indexFailed[l.dir.path] ?? statusOf(l)?.error?.message;

  /// The line for the Library screen's Libraries row.
  String get summary {
    final n = libraries.length;
    if (task != null && task!.running) return 'Adding ${task!.name}…';
    if (n == 0) return 'None yet';
    return n == 1 ? '1 library' : '$n libraries';
  }

  /// Starts the keyword index of every installed library that should have one and has not (the app was closed while it was
  /// being built, or the index was removed).
  void _resumeIndexes() {
    final core = sources.core;
    if (core == null) return;
    for (final l in libraries) {
      final s = statusOf(l);
      if (s == null || s.id == null || s.error != null || s.opening || s.updating || s.indexed || s.building) continue;
      if (_keywordOff(l) || _indexJobs.containsKey(l.dir.path) || _indexFailed.containsKey(l.dir.path)) continue;
      final f = _indexInstalled(core, l);
      _pending.add(f);
      unawaited(f.whenComplete(() => _pending.remove(f)));
    }
  }

  Future<void> _indexInstalled(SearchCore core, LibraryItem l) async {
    try {
      final job = await core.startJob('index_library', _indexParams(l.shardPath, l.indexPath, l.settings));
      _indexJobs[l.dir.path] = job;
      _indexProgress[l.dir.path] = null;
      notifyListeners();
      final p = await _wait(job, (f) {
        _indexProgress[l.dir.path] = f;
        notifyListeners();
      });
      if (p.state == JobState.failed) _indexFailed[l.dir.path] = p.errorMessage ?? 'The search index could not be built';
    } on CacheSearchException catch (e) {
      if (e.code != 'busy') _indexFailed[l.dir.path] = e.message;
    } finally {
      _indexJobs.remove(l.dir.path);
      _indexProgress.remove(l.dir.path);
      if (!_disposed) {
        await sources.refresh();
        notifyListeners();
      }
    }
  }

  static Map<String, dynamic> _indexParams(String shard, String index, Map<String, dynamic>? settings) => {
        'library_path': shard,
        'index_dir': index,
        'heap_mb': 200,
        'settings': ?settings,
      };

  /// Polls [job] until it ends, reporting its fraction, then frees it.
  Future<JobProgress> _wait(CoreJobHandle job, void Function(double?) onProgress) async {
    try {
      while (true) {
        final p = await job.progress();
        if (p.isFinished) return p;
        onProgress(p.fraction);
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      try {
        await job.free();
      } catch (_) {}
    }
  }

  // ---- adding

  /// Lets the person pick a library file (a .cache-library archive, or a plain Qdrant snapshot) and adds it.
  Future<void> pickAndAdd({required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    if (task != null && task!.running) return;
    final path = await _pickFile();
    if (path == null) return;
    try {
      await addFile(File(path), confirmUpdate: confirmUpdate, askSettings: askSettings);
    } finally {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    }
  }

  static Future<String?> _pickWithPicker() async => (await FilePicker.pickFile())?.path;

  static Future<bool> _saveWithPicker(String fileName, Uint8List bytes) async =>
      await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: 'application/x-tar') != null;

  static String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Adds the library in [file] (the file itself is left where it is).
  Future<void> addFile(File file, {required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    final t = task = AddTask(_nameOf(file.path));
    notifyListeners();
    await _install(t, file, confirmUpdate: confirmUpdate, askSettings: askSettings);
  }

  /// Downloads the library at [link] (https only), then adds it. A download cut off is continued by adding the same link
  /// again; the partly downloaded file is hidden in the libraries folder. [anyway] is the person's "Download anyway" when the
  /// phone is on mobile data and downloads on it are switched off.
  Future<void> addLink(
    String link, {
    required ConfirmUpdate confirmUpdate,
    required AskSettings askSettings,
    bool anyway = false,
  }) async {
    if (task != null && task!.running) return;
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      task = AddTask(link.trim())
        ..link = link.trim()
        ..error = 'Use a link that starts with https://';
      notifyListeners();
      return;
    }
    final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.host;
    final t = task = AddTask(name)
      ..link = uri.toString()
      ..step = AddStep.downloading;
    notifyListeners();
    try {
      await policy?.checkDownload(anyway: anyway);
    } on MobileDataBlocked catch (e) {
      t
        ..blockedByMobileData = true
        ..error = e.message;
      notifyListeners();
      return;
    }
    await _partialDir.create(recursive: true);
    final part = File('${_partialDir.path}${Platform.pathSeparator}${sha256.convert(utf8.encode(uri.toString())).toString().substring(0, 16)}.part');
    final token = t.token = CancelToken();
    try {
      await downloader.download(
        url: uri,
        part: part,
        cancel: token,
        onProgress: (done, total) {
          t.fraction = total <= 0 ? null : done / total;
          notifyListeners();
        },
      );
    } on DownloadException catch (e) {
      if (e.code == 'cancelled') {
        task = null;
      } else {
        t.error = e.message;
      }
      notifyListeners();
      return;
    }
    final ok = await _install(t, part, confirmUpdate: confirmUpdate, askSettings: askSettings);
    // A file that turned out not to be a library is not kept; one added (or not wanted) is not needed any more.
    if (ok || t.error == null || !t.error!.startsWith('Not enough free space')) _deleteQuietly(part);
  }

  /// Stops the add under way: a download keeps what it has (the same link continues it), anything after it is undone.
  Future<void> cancelAdd() async {
    final t = task;
    if (t == null) return;
    t.cancelled = true;
    t.token?.cancel();
    try {
      await t.job?.cancel();
    } catch (_) {}
    notifyListeners();
  }

  /// Forgets a failed add.
  void dismissTask() {
    if (task != null && !task!.running) {
      task = null;
      notifyListeners();
    }
  }

  /// Plain words for a core error; the core's own text (paths, library internals) goes to the log only.
  String _words(Object e) {
    if (e is CacheSearchException) {
      debugPrint('Libraries: ${e.code}: ${e.message}');
      switch (e.code) {
        case 'no_space':
          return 'Not enough free space on this device for the library.';
        case 'io':
          return 'Could not read or write the file.';
        case 'unsupported':
          return kNotALibrary;
        case 'bad_json':
          return 'Its settings file could not be read.';
        case 'not_found':
          return 'The file could not be found.';
      }
      return 'That did not work.';
    }
    return e.toString().replaceFirst('Bad state: ', '');
  }

  /// Why [archive] could not be unpacked, in plain words: the blank template (which has no entries yet), or a file that is
  /// not a library (not a tar, or a tar that is not a library snapshot). Running out of space says so.
  String _unpackWords(File archive, CacheSearchException e) {
    final names = tarEntryNames(archive);
    if (names != null && names.contains(kTemplateSnapshotName)) return kEmptyTemplate;
    if (e.code == 'unsupported' || e.code == 'io') {
      debugPrint('Libraries: ${e.code}: ${e.message}');
      return kNotALibrary;
    }
    return _words(e);
  }

  /// Unpacks [archive] into a hidden new folder, works out its settings (asking only for a settings file the core cannot do
  /// without), offers an update when a library with the same id is here, builds its keyword index and puts it in place.
  /// Nothing installed is touched until the new copy has opened and its index is built. True when it was added.
  Future<bool> _install(AddTask t, File archive, {required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    final core = sources.core;
    if (core == null) {
      t.error = sources.unavailable ?? 'Search is not ready yet. Try again in a moment.';
      notifyListeners();
      return false;
    }
    final stage = Directory(_child('.add-${DateTime.now().microsecondsSinceEpoch}'));
    final shard = '${stage.path}${Platform.pathSeparator}shard';
    final index = '${stage.path}${Platform.pathSeparator}index';
    var installed = false;
    try {
      await stage.create(recursive: true);
      t
        ..step = AddStep.unpacking
        ..fraction = 0;
      notifyListeners();
      JobProgress? p;
      try {
        p = await _job(t, core, 'unpack_library', {'snapshot_path': archive.path, 'dir': shard},
            words: (e) => _unpackWords(archive, e));
      } on CacheSearchException catch (e) {
        t.error = _unpackWords(archive, e);
        return false;
      }
      if (p == null) return false;
      var detail = p.detail ?? const {};
      var settings = (detail['settings'] as Map?)?.cast<String, dynamic>();
      // Only what the core cannot work out is asked: a settings file, when guessing from the entries did not work.
      while (detail['settings_error'] != null) {
        final reason = ((detail['settings_error'] as Map)['message'] ?? '') as String;
        final path = await askSettings(reason);
        if (path == null) {
          task = null;
          return false;
        }
        try {
          settings = (jsonDecode(await File(path).readAsString()) as Map).cast<String, dynamic>();
        } catch (e) {
          t.error = 'That settings file could not be read: $e';
          return false;
        }
        t
          ..step = AddStep.checking
          ..fraction = null;
        notifyListeners();
        p = await _job(t, core, 'check_library', {'library_path': shard, 'settings': settings});
        if (p == null) return false;
        detail = p.detail ?? const {};
      }
      final resolved = ((detail['resolved'] as Map?) ?? const {}).cast<String, dynamic>();
      final id = (resolved['library_id'] ?? '') as String;
      final title = (resolved['title'] ?? id) as String;
      LibraryItem? existing;
      for (final l in libraries) {
        if (idOf(l) == id) existing = l;
      }
      if (existing != null) {
        final yes = await confirmUpdate(titleOf(existing), versionOf(existing), _version(settings) ?? _version(resolved));
        if (!yes) {
          task = null;
          return false;
        }
      }
      final keyword = (resolved['keyword_index'] ?? 'auto') as String;
      final needsIndex = keyword == 'on' || (keyword == 'auto' && detail['own_text_index'] != true);
      if (needsIndex) {
        t
          ..step = AddStep.indexing
          ..fraction = 0;
        notifyListeners();
        p = await _job(t, core, 'index_library', _indexParams(shard, index, settings));
        if (p == null) return false;
      }
      if (settings != null) {
        await writeStringAtomic(File('${stage.path}${Platform.pathSeparator}$kLibrarySettingsFile'), const JsonEncoder.withIndent('  ').convert(settings));
      }
      t
        ..step = AddStep.swapping
        ..fraction = null;
      notifyListeners();
      if (existing == null) {
        await stage.rename(_child(await _freeFolderName(id.isEmpty ? title : id)));
      } else {
        final err = await _swap(existing, stage);
        if (err != null) {
          t.error = err;
          return false;
        }
      }
      installed = true;
      await _scan();
      await sources.refresh();
      task = null;
      return true;
    } on CacheSearchException catch (e) {
      t.error = _words(e);
      return false;
    } on FileSystemException catch (e) {
      t.error = 'Could not write the library: ${e.message}';
      return false;
    } finally {
      if (!installed) _deleteQuietly(stage);
      if (t.cancelled && !installed) task = null;
      notifyListeners();
    }
  }

  /// Runs a core job for [t], showing its progress; null when it was cancelled or failed (then [t] says why).
  Future<JobProgress?> _job(AddTask t, SearchCore core, String kind, Map<String, dynamic> params,
      {String Function(CacheSearchException e)? words}) async {
    if (t.cancelled) return null;
    final job = t.job = await core.startJob(kind, params);
    final p = await _wait(job, (f) {
      t.fraction = f;
      notifyListeners();
    });
    t.job = null;
    if (p.state == JobState.done) return p;
    if (p.state == JobState.failed) {
      final e = CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? 'It did not work');
      t.error = words == null ? _words(e) : words(e);
    }
    return null;
  }

  /// A folder name for a new library from its id: letters, digits, '-' and '_', unique in the folder.
  Future<String> _freeFolderName(String id) async {
    var base = id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (base.isEmpty) base = 'library';
    var name = base;
    for (var i = 2; Directory(_child(name)).existsSync(); i++) {
      name = '$base-$i';
    }
    return name;
  }

  /// Swaps the checked new copy [stage] in for [old]: the old one is closed and moved aside, the new one put in its place
  /// and opened; if it does not open, the old one is put back. Null when it worked, else what went wrong.
  Future<String?> _swap(LibraryItem old, Directory stage) async {
    final path = old.dir.path;
    final aside = Directory(_child('.${old.folderName}.old'));
    _deleteQuietly(aside);
    _closed.add(path);
    try {
      await sources.refresh();
      await _renameRetry(old.dir, aside.path);
      try {
        await _renameRetry(stage, path);
      } catch (e) {
        await _renameRetry(aside, path);
        return 'Could not put the new copy in place, so ${titleOf(old)} was kept as it was.';
      }
      _closed.remove(path);
      await _scan();
      await sources.refresh();
      final s = await _whenOpened(LibraryItem(dir: Directory(path)).shardPath);
      if (s == null || s.error != null) {
        _closed.add(path);
        await sources.refresh();
        await _renameRetry(Directory(path), stage.path);
        await _renameRetry(aside, path);
        _closed.remove(path);
        await _scan();
        await sources.refresh();
        return 'The new copy could not be opened, so the library was kept as it was.';
      }
      _deleteQuietly(aside);
      return null;
    } finally {
      _closed.remove(path);
    }
  }

  /// The library's status once the core has finished opening it (null after ten minutes).
  Future<SourceStatus?> _whenOpened(String shardPath) async {
    for (var i = 0; i < 2400; i++) {
      await sources.reloadStatus();
      final s = sources.statusAt(shardPath);
      if (s != null && !s.opening) return s;
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  /// Windows can refuse a rename for a moment while a just-closed library's files are still held.
  static Future<void> _renameRetry(Directory from, String to) async {
    for (var i = 0;; i++) {
      try {
        await from.rename(to);
        return;
      } on FileSystemException {
        if (i >= 20) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
      }
    }
  }

  // ---- removing

  /// Removes the library and its index from the device.
  Future<void> remove(LibraryItem l) async {
    error = null;
    final job = _indexJobs.remove(l.dir.path);
    if (job != null) {
      try {
        await job.cancel();
      } catch (_) {}
    }
    _indexFailed.remove(l.dir.path);
    _closed.add(l.dir.path);
    try {
      await sources.refresh();
      for (var i = 0;; i++) {
        try {
          if (l.dir.existsSync()) l.dir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          if (i >= 20) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
        }
      }
    } catch (e) {
      error = 'Could not remove the library: $e';
    } finally {
      _closed.remove(l.dir.path);
      await _scan();
      await sources.refresh();
      notifyListeners();
    }
  }

  // ---- the blank template

  /// Makes the blank library template on the device and hands it to the system's save dialog. True when it was saved.
  Future<bool> saveTemplate() async {
    final core = sources.core;
    if (core == null || makingTemplate) return false;
    makingTemplate = true;
    error = null;
    notifyListeners();
    final tmp = await (tempDirOverride ?? await getTemporaryDirectory()).createTemp('template');
    try {
      final out = File('${tmp.path}${Platform.pathSeparator}$kLibraryTemplateName');
      final p = await _wait(await core.startJob('library_template', {'out_path': out.path}), (_) {});
      if (p.state != JobState.done) {
        error = 'Could not make the template: ${_words(CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? ''))}';
        return false;
      }
      return await _saveBytes(kLibraryTemplateName, await out.readAsBytes());
    } catch (e) {
      error = 'Could not make the template: ${_words(e)}';
      return false;
    } finally {
      _deleteQuietly(tmp);
      makingTemplate = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    sources.removeListener(_onSources);
    super.dispose();
  }
}

/// What adding a file that is not a library says.
const String kNotALibrary = "This file isn't a Cache library.";

/// What adding the blank template says: it has no entries until it is filled.
const String kEmptyTemplate = 'This is an empty library template. Fill it with your own entries first (see the README inside).';

/// The snapshot file inside the blank template (TEMPLATE_SNAPSHOT in the core's libadd.rs).
const String kTemplateSnapshotName = 'blank-library.snapshot';

/// The names of the first entries of a tar file (at most [max]), or null when [f] is not a tar or cannot be read. Reads
/// only the headers.
@visibleForTesting
List<String>? tarEntryNames(File f, {int max = 16}) {
  RandomAccessFile? r;
  try {
    r = f.openSync();
    final length = r.lengthSync();
    final names = <String>[];
    var at = 0;
    while (names.length < max && at + 512 <= length) {
      r.setPositionSync(at);
      final h = r.readSync(512);
      if (h.length < 512) break;
      if (h.every((b) => b == 0)) break; // the end of the archive
      // The header checksum: the sum of the header's bytes with the checksum field read as spaces.
      var sum = 0;
      for (var i = 0; i < 512; i++) {
        sum += (i >= 148 && i < 156) ? 32 : h[i];
      }
      final stored = int.tryParse(String.fromCharCodes(h.sublist(148, 156)).replaceAll('\x00', '').trim(), radix: 8);
      if (stored != sum) return names.isEmpty ? null : names;
      final end = h.indexOf(0);
      names.add(String.fromCharCodes(h.sublist(0, end < 0 || end > 100 ? 100 : end)));
      final size = int.tryParse(String.fromCharCodes(h.sublist(124, 136)).replaceAll('\x00', '').trim(), radix: 8) ?? 0;
      at += 512 + (size + 511) ~/ 512 * 512;
    }
    return names.isEmpty ? null : names;
  } catch (_) {
    return null;
  } finally {
    r?.closeSync();
  }
}
