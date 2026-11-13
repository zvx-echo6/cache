import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:cache_search/cache_search.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../app_fs.dart';
import '../browse/web/device_api.dart' show DeviceException;
import '../browse/web/device_files.dart';
import '../browse/web/device_library.dart';
import '../browse/web/local_files.dart' show pickLocalFile;
import '../browse/zim_download.dart';
import '../files.dart';
import '../settings/data_policy.dart';
import 'sources_state.dart';
import '../platform/app_log.dart';
import '../platform.dart' as plat;

/// The settings file of a library (docs/LIBRARY-FORMAT.md): inside a .cache-library archive, and beside the library here.
const String kLibrarySettingsFile = 'cache-library.json';

/// The name the blank template is saved under.
const String kLibraryTemplateName = 'cache-library-template.tar.gz';

/// The library id of the setup guide that ships inside the app (assets/guide): installed on first launch, always present, never
/// offered for delete.
const String kGuideLibraryId = 'cache-guide';

/// The version of the guide in the assets (its cache-library.json `version`); a different copy on the phone is replaced by it.
const String kGuideVersion = '2026-11-12';

/// What a library folder holds that never syncs with the libraries folder (see DataKind.notShared): its old keyword index
/// ([LibraryItem.indexPath]). Library indexes now build into the indexes folder and sync from there as snapshots
/// (search/indexes_share.dart); this version only reads an old index/ until the core seals it into a snapshot and empties it,
/// and only Cache 1.0.29 and earlier still write here, so it stays out (a file the core moved away would otherwise go out as a
/// delete and remove an older device's own index).
const List<String> kLibraryNotShared = ['*/index', '*/index-snapshots'];

/// One library on the device: a folder in the libraries folder holding `shard/` (the unpacked Qdrant shard), `index/` (its
/// keyword index, when one is built on the device) and `cache-library.json` (its settings, when it came with them; without
/// it the core works them out each time it opens the library).
class LibraryItem {
  LibraryItem({required Directory dir, this.settings, this.size = 0}) : path = dir.path;

  /// A library in a browser, which has no Directory: only the path of its folder on the device.
  LibraryItem.at({required this.path, this.settings, this.size = 0});

  /// The library's folder (on the device, for a browser).
  final String path;

  /// The folder as a Directory (a phone; not in a browser).
  Directory get dir => Directory(path);
  final Map<String, dynamic>? settings;

  /// Bytes on the disk, shard and index together.
  int size;

  String get shardPath => '$path${_pathSep}shard';
  String get indexPath => '$path${_pathSep}index';
  String get folderName => path.split(RegExp(r'[\\/]')).last;

  /// The source the core is given for this library.
  SourceConfig get config => SourceConfig.library(path: shardPath, indexDir: indexPath, settings: settings);
}

/// The path separator of the machine that holds the files. A browser has none of its own, and the device's paths are joined with '/'.
String get _pathSep => plat.isWeb ? '/' : Platform.pathSeparator;

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

  /// Downloads only: the bytes so far and in all (0 when not known).
  int done = 0;
  int total = 0;

  /// Downloads only: paused by the person (the partly downloaded file stays; [LibrariesState.resumeAdd] continues it).
  bool paused = false;

  /// Remove was tapped: the partly downloaded file goes once the download has stopped.
  bool removing = false;

  /// Starts this add again the way it was started (Resume, Try again).
  Future<void> Function()? again;
  bool get running => error == null && !paused;
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
    this.bundledGuide,
    this.device,
    AppFs? appFs,
  })  : downloader = downloader ?? ZimDownloader(),
        _pickFile = pickFile ?? _pickWithPicker,
        _saveBytes = saveBytes ?? _saveWithPicker,
        _dev = device == null ? null : DeviceFiles(appFs ?? createAppFs()) {
    sources.librarySources = () => [
          for (final l in libraries)
            if (!_closed.contains(l.path)) l.config,
        ];
    sources.addListener(_onSources);
    device?.addListener(_onDeviceChanged);
  }

  /// In a browser: the Library on the device. The app runs its own install procedure against the device's files and search core
  /// (with the same prompts as on a phone), and what is installed is listed from the device. Null on a phone.
  final DeviceLibrary? device;
  final DeviceFiles? _dev;

  /// The libraries folder on the device (a browser), once known.
  String? _devBase;

  final SourcesState sources;

  /// The mobile data rule for downloads; null: no rule.
  final DataPolicy? policy;
  final ZimDownloader downloader;
  final Directory? dirOverride;
  final Directory? tempDirOverride;
  final PickPath _pickFile;
  final SaveBytes _saveBytes;
  final Duration pollInterval;

  /// The guide library shipped in the app, as a file to add (copied out of the assets); null leaves it out (tests).
  final Future<File?> Function()? bundledGuide;

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

  /// Ends when the index builds started at start, and the reading of a library still opening, have ended (for tests).
  Future<void> whenIdle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  Future<void> init() async {
    if (plat.isWeb || _dev != null) {
      // In a browser the device owns the libraries' folders: nothing is scanned or created here, and there is no guide to copy out.
      if (_dev != null) {
        await _devRecoverLeftovers();
        await device!.refresh();
        await _devScan();
      }
      notifyListeners();
      final core = await sources.whenCoreReady();
      if (core == null) {
        unawaited(sources.whenCoreOpen().then((_) => sources.refresh()));
        return;
      }
      await sources.refresh();
      return;
    }
    final base = dirOverride ??
        Directory(
          '${await appFilesPath()}'
          '${Platform.pathSeparator}libraries',
        );
    await base.create(recursive: true);
    dir = base;
    _recoverLeftovers();
    await _scan();
    notifyListeners();
    final core = await sources.whenCoreReady();
    if (core == null) {
      // A core started again later (Try again in Ask) picks up the libraries then.
      unawaited(sources.whenCoreOpen().then((_) => _afterCore()));
      return;
    }
    await _afterCore();
  }

  /// Reads the libraries folder (and the ZIM folder, through [SourcesState.refresh]) again after something outside an add or a
  /// remove changed it: a device-to-device sync that brought, updated or removed a library. The list, the core and the
  /// keyword indexes follow at once.
  Future<void> rescan() async {
    if (dir == null || _disposed) return;
    _recoverLeftovers();
    await _scan();
    notifyListeners();
    await sources.refresh();
    _resumeIndexes();
    notifyListeners();
    // a library the sync brought is opened by the core on its own thread: follow it until it is open
    _settleOpening();
  }

  Future<void> _afterCore() async {
    await sources.refresh();
    _resumeIndexes();
    await ensureGuide();
    await _whileOpening();
    _resumeIndexes();
  }

  /// The core opens each library on a background thread after cs_open, so the first list can show a library as still opening.
  /// Nothing else reads the list again on its own, so the row stayed on its opening badge and its index was never resumed: the
  /// status is read again until no library is opening (for at most ten minutes, like an add).
  Future<void> _whileOpening() async {
    for (var i = 0; i < 2400 && !_disposed; i++) {
      if (!libraries.any((l) => statusOf(l)?.opening ?? false)) return;
      await Future<void>.delayed(pollInterval);
      if (_disposed) return;
      await sources.reloadStatus();
    }
  }

  /// True for the guide that ships in the app (it is never offered for delete).
  bool isGuide(LibraryItem l) => idOf(l) == kGuideLibraryId;

  /// Installs the bundled guide when it is not on the phone (first launch, or after it was removed by hand) or when the app carries a
  /// newer copy, like any library added from a file.
  Future<void> ensureGuide() async {
    final source = bundledGuide;
    if (source == null || (task != null && task!.running)) return;
    final have = libraries.where(isGuide).firstOrNull;
    if (have != null && versionOf(have) == kGuideVersion) return;
    final file = await source();
    if (file == null) return;
    try {
      await addFile(file, confirmUpdate: (_, from, to) async => from != to, askSettings: (_) async => null);
      // An add that only found the same copy is not a problem to show.
      if (task != null && !task!.running) task = null;
      notifyListeners();
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Directory get _partialDir => Directory('${dir!.path}${Platform.pathSeparator}.partial');

  String _child(String name) => '${_devBase ?? dir!.path}$_pathSep$name';

  // ---- the same file steps, on the device in a browser (they are the phone's own steps on a phone)

  Future<void> _mkdirs(String path) async {
    if (_dev != null) return _dev.mkdirs(path);
    await Directory(path).create(recursive: true);
  }

  Future<bool> _dirExists(String path) async {
    if (_dev != null) return _dev.exists(path);
    return Directory(path).existsSync();
  }

  Future<void> _deleteQuietlyPath(String path) async {
    if (_dev != null) return _dev.deleteQuietly(path);
    _deleteQuietly(Directory(path));
  }

  Future<String> _readText(String path) async {
    if (_dev != null) return await _dev.readText(path) ?? (throw const CacheSearchException('not_found', 'The file could not be found'));
    return File(path).readAsString();
  }

  Future<void> _writeText(String path, String text) async {
    if (_dev != null) return _dev.writeText(path, text);
    await writeStringAtomic(File(path), text);
  }

  /// What a change in the libraries folder needs: the phone reads the folder and gives the core the list; the device's core is told
  /// to read the folders (a browser may not hand it a list) and the list is read from the device.
  Future<void> _afterChange() async {
    if (_dev != null) {
      await _syncSources();
      return;
    }
    await _scan();
    await sources.refresh();
    _settleOpening();
  }

  Future<void>? _settling;
  bool _settleAgain = false;

  /// After a change the core opens a new or swapped-in library on its own thread, so the list right after it can still say it is
  /// opening. Nothing else read the status again, so a library just added stayed on "Getting ready" until a restart or the next
  /// library change (found on a Pixel): the status is read again until no library is opening, then any index left to build is
  /// resumed. One poll at a time; a change during it polls once more after it.
  void _settleOpening() {
    if (_disposed) return;
    if (_settling != null) {
      _settleAgain = true;
      return;
    }
    final f = () async {
      do {
        _settleAgain = false;
        await _whileOpening();
      } while (_settleAgain && !_disposed);
      if (_disposed) return;
      _resumeIndexes();
      notifyListeners();
    }();
    _settling = f;
    _pending.add(f);
    unawaited(f.whenComplete(() {
      _pending.remove(f);
      _settling = null;
    }));
  }

  /// A browser: the device's core reads the library folders again, then this list and the sources' status follow.
  Future<void> _syncSources() async {
    await device!.rescan();
    await device!.refresh();
    await _devScan();
    await sources.refresh();
  }

  String _devSignature = '';

  void _onDeviceChanged() {
    final sig = [for (final i in device!.items) if (i.kind == 'library') '${i.name}:${i.bytes}'].join('|');
    if (sig == _devSignature) return;
    unawaited(_devScan());
  }

  /// A browser: the libraries are the device's library items; their settings are read from their folders.
  Future<void> _devScan() async {
    final d = device!;
    final base = _devBase = await _dev!.librariesBase();
    _devSignature = [for (final i in d.items) if (i.kind == 'library') '${i.name}:${i.bytes}'].join('|');
    final found = <LibraryItem>[];
    for (final it in d.items.where((i) => i.kind == 'library')) {
      Map<String, dynamic>? settings;
      try {
        final text = await _dev.readText('$base/${it.name}/$kLibrarySettingsFile');
        if (text != null) settings = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (e) {
        debugPrint('Library settings of ${it.name}: $e');
      }
      found.add(LibraryItem.at(path: '$base/${it.name}', settings: settings, size: it.bytes));
    }
    found.sort((a, b) => titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase()));
    if (_disposed) return;
    libraries = found;
    notifyListeners();
  }

  /// What an add or a swap that was cut off left on the device (the same recovery as [_recoverLeftovers]).
  Future<void> _devRecoverLeftovers() async {
    try {
      final base = _devBase = await _dev!.librariesBase();
      for (final name in await _dev.folderNames(base)) {
        if (name.startsWith('.add-')) {
          await _dev.deleteQuietly('$base/$name');
        } else if (name.startsWith('.') && name.endsWith('.old')) {
          final real = '$base/${name.substring(1, name.length - 4)}';
          if (await _dev.exists(real)) {
            await _dev.deleteQuietly('$base/$name');
          } else {
            try {
              await _dev.rename('$base/$name', real);
            } catch (e) {
              debugPrint('Could not restore $base/$name: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Libraries folder: $e');
    }
  }

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
              logError('Could not restore a library', error: e, detail: d.path);
            }
          }
        }
      }
    } catch (e) {
      logError('Libraries folder', error: e);
    }
  }

  static void _deleteQuietly(FileSystemEntity e) {
    try {
      if (e.existsSync()) e.deleteSync(recursive: true);
    } catch (err) {
      logError('Could not remove a library folder', error: err, detail: e.path);
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
        logError('Library settings', error: e, detail: name);
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

  /// Whether the library in the folder [libraryPath] has points its keyword index lacks (see SourceStatus.keywordPending); null when
  /// not known.
  bool? wordsPendingAt(String libraryPath) {
    for (final l in libraries) {
      if (l.path == libraryPath) return statusOf(l)?.keywordPending;
    }
    return null;
  }

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
    if (_indexFailed.containsKey(l.path)) return LibraryPhase.failed;
    final s = statusOf(l);
    if (s == null) return LibraryPhase.waiting;
    if (s.error != null) return LibraryPhase.failed;
    if (s.opening || s.updating) return LibraryPhase.opening;
    if (_indexJobs.containsKey(l.path) || s.building) return LibraryPhase.indexing;
    if (s.indexed || _keywordOff(l)) return LibraryPhase.ready;
    return LibraryPhase.waiting;
  }

  double? indexFraction(LibraryItem l) => _indexProgress[l.path];

  /// Why the library cannot be used, in words for people.
  String? failureOf(LibraryItem l) => _indexFailed[l.path] ?? statusOf(l)?.error?.message;

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
      if (_keywordOff(l) || _indexJobs.containsKey(l.path) || _indexFailed.containsKey(l.path)) continue;
      final f = _indexInstalled(core, l);
      _pending.add(f);
      unawaited(f.whenComplete(() => _pending.remove(f)));
    }
  }

  Future<void> _indexInstalled(SearchCore core, LibraryItem l) async {
    try {
      final job = await core.startJob('index_library', _indexParams(l.shardPath, l.indexPath, l.settings));
      _indexJobs[l.path] = job;
      _indexProgress[l.path] = null;
      notifyListeners();
      final p = await _wait(job, (f) {
        _indexProgress[l.path] = f;
        notifyListeners();
      });
      if (p.state == JobState.failed) _indexFailed[l.path] = p.errorMessage ?? 'The search index could not be built';
    } on CacheSearchException catch (e) {
      if (e.code != 'busy') _indexFailed[l.path] = e.message;
    } finally {
      _indexJobs.remove(l.path);
      _indexProgress.remove(l.path);
      if (!_disposed) {
        await sources.refresh();
        notifyListeners();
      }
    }
  }

  /// index_library's parameters: into the device's indexes folder when there is one ([SourcesState.syncIndexesDir]: a snapshot of
  /// `library/<library_id[@version]>`, which syncs to every device with the library), else into the library's own index/.
  Map<String, dynamic> _indexParams(String shard, String index, Map<String, dynamic>? settings) {
    final shared = sources.syncIndexesDir;
    return {
      'library_path': shard,
      if (shared != null) 'indexes_dir': shared else 'index_dir': index,
      'heap_mb': 200,
      'settings': ?settings,
    };
  }

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

  /// Lets the person pick a file and adds it: a .cache-library archive or a plain Qdrant snapshot as a library, a .zim as a ZIM
  /// (copied in and indexed like a downloaded one), so one "From a file" adds either.
  Future<void> pickAndAdd({required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    if (task != null && task!.running) return;
    final path = await _pickFile();
    if (path == null) return;
    try {
      if (path.toLowerCase().endsWith('.zim')) {
        await sources.addZim(File(path));
        return;
      }
      await addFile(File(path), confirmUpdate: confirmUpdate, askSettings: askSettings);
    } finally {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    }
  }

  static Future<String?> _pickWithPicker() async => (await FilePicker.pickFile())?.path;

  static Future<bool> _saveWithPicker(String fileName, Uint8List bytes) async =>
      await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: 'application/gzip') != null;

  static String _nameOf(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Adds the library in [file] (the file itself is left where it is).
  Future<void> addFile(File file, {required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    final t = task = AddTask(_nameOf(file.path));
    notifyListeners();
    await _install(t, file.path, confirmUpdate: confirmUpdate, askSettings: askSettings);
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
    if (_dev != null) return _addLinkOnDevice(link);
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
    t.again = () => addLink(link, confirmUpdate: confirmUpdate, askSettings: askSettings, anyway: anyway);
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
          t
            ..done = done
            ..total = total;
          notifyListeners();
        },
      );
    } on DownloadException catch (e) {
      if (e.code == 'cancelled') {
        if (t.removing) _deleteQuietly(part);
        // A paused add stays, to resume; a stopped one is gone.
        if (!t.paused && task == t) task = null;
      } else {
        t.error = e.message;
      }
      notifyListeners();
      return;
    }
    final ok = await _install(t, part.path, confirmUpdate: confirmUpdate, askSettings: askSettings);
    // A file that turned out not to be a library is not kept; one added (or not wanted) is not needed any more.
    if (ok || t.error == null || !t.error!.startsWith('Not enough free space')) _deleteQuietly(part);
  }

  /// A browser: adds the library package that waits on the device as `incoming/<name>` in the documents folder (it was uploaded from
  /// this computer or downloaded from a link). The app runs the install itself, with the same prompts as on a phone; the package is
  /// deleted afterwards unless the device ran out of space (then it waits for another try, as a partly downloaded file does on a phone).
  Future<void> addDeviceFile(String name, {required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    final dev = _dev;
    if (dev == null || (task != null && task!.running)) return;
    _devBase = await dev.librariesBase();
    final archive = '${await dev.docsRoot()}/incoming/$name';
    final t = task = AddTask(name);
    notifyListeners();
    final ok = await _install(t, archive, confirmUpdate: confirmUpdate, askSettings: askSettings);
    if (ok || t.error == null || !t.error!.startsWith('Not enough free space')) await dev.deleteQuietly(archive);
    final settings = _devSettingsFile;
    if (settings != null) {
      _devSettingsFile = null;
      await dev.deleteQuietly(settings);
    }
  }

  /// The settings file waiting on the device, from [pickSettingsOnDevice].
  String? _devSettingsFile;

  /// A browser: lets the person choose the settings file (cache-library.json) on this computer, puts it on the device and returns
  /// its path there (null when nothing was chosen). Call it straight from a tap.
  Future<String?> pickSettingsOnDevice() async {
    final dev = _dev;
    if (dev == null) return null;
    final file = await pickLocalFile(accept: const ['.json']);
    if (file == null) return null;
    if (file.size > 4 << 20) return null;
    final path = '${await dev.docsRoot()}/incoming/.settings-${DateTime.now().microsecondsSinceEpoch}.json';
    await dev.writeBytes(path, await file.readAll());
    _devSettingsFile = path;
    return path;
  }

  /// A browser: the device downloads the library package at [link] (it keeps going with the tab closed) and keeps it, ready to add.
  Future<void> _addLinkOnDevice(String link) async {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      task = AddTask(link.trim())
        ..link = link.trim()
        ..error = 'Use a link that starts with https://';
      notifyListeners();
      return;
    }
    try {
      await device!.downloadLibrary(uri.toString());
    } on DeviceException catch (e) {
      debugPrint('Libraries: ${e.code}: ${e.message}');
      task = AddTask(uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.host)
        ..link = uri.toString()
        ..error = e.code == 'invalid_name' ? 'That link does not give a usable file name.' : 'The download could not be started. Try again.';
      notifyListeners();
    }
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

  /// Pauses the download of the add under way: it stops and keeps what it has; [resumeAdd] continues it.
  void pauseAdd() {
    final t = task;
    if (t == null || t.step != AddStep.downloading || !t.running) return;
    t.paused = true;
    t.token?.cancel();
    notifyListeners();
  }

  /// Continues a paused or failed add from what it has.
  Future<void> resumeAdd() async {
    final again = task?.again;
    if (again == null) return;
    task = null;
    notifyListeners();
    await again();
  }

  /// Removes the add under way, or a paused or failed one, and the partly downloaded file.
  Future<void> removeAdd() async {
    final t = task;
    if (t == null) return;
    if (t.running && t.step == AddStep.downloading) {
      t.removing = true;
      await cancelAdd();
      return;
    }
    if (t.running) {
      await cancelAdd();
      return;
    }
    final link = t.link;
    task = null;
    if (link != null) {
      final uri = Uri.tryParse(link);
      if (uri != null) _deleteQuietly(File('${_partialDir.path}${Platform.pathSeparator}${sha256.convert(utf8.encode(uri.toString())).toString().substring(0, 16)}.part'));
    }
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
      logError('Libraries (${e.code})', error: e.message);
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

  /// Why the archive at [archivePath] could not be unpacked, in plain words: the blank template (which has no entries yet), or a file
  /// that is not a library (not a tar, or a tar that is not a library snapshot). Running out of space says so.
  String _unpackWords(String archivePath, CacheSearchException e) {
    if (_dev != null) {
      // The browser cannot read the archive's inside; the blank template is known by the name it is saved under.
      if (_nameOf(archivePath) == kLibraryTemplateName) return kEmptyTemplate;
      if (e.code == 'unsupported' || e.code == 'io') {
        debugPrint('Libraries: ${e.code}: ${e.message}');
        return kNotALibrary;
      }
      return _words(e);
    }
    final archive = File(archivePath);
    final names = tarEntryNames(archive);
    if (names != null && names.contains(kTemplateSnapshotName)) return kEmptyTemplate;
    if (e.code == 'unsupported' || e.code == 'io') {
      logError('Libraries (${e.code})', error: e.message);
      return kNotALibrary;
    }
    return _words(e);
  }

  /// Unpacks the archive at [archivePath] into a hidden new folder, works out its settings (asking only for a settings file the core
  /// cannot do without), offers an update when a library with the same id is here, builds its keyword index and puts it in place.
  /// Nothing installed is touched until the new copy has opened and its index is built. True when it was added. In a browser the
  /// paths are paths on the device, and the files are changed through [AppFs].
  Future<bool> _install(AddTask t, String archivePath, {required ConfirmUpdate confirmUpdate, required AskSettings askSettings}) async {
    final core = sources.core;
    if (core == null) {
      t.error = sources.unavailable ?? 'Search is not ready yet. Try again in a moment.';
      notifyListeners();
      return false;
    }
    final stagePath = _child('.add-${DateTime.now().microsecondsSinceEpoch}');
    final shard = '$stagePath${_pathSep}shard';
    final index = '$stagePath${_pathSep}index';
    var installed = false;
    try {
      await _mkdirs(stagePath);
      t
        ..step = AddStep.unpacking
        ..fraction = 0;
      notifyListeners();
      JobProgress? p;
      try {
        p = await _job(t, core, 'unpack_library', {'snapshot_path': archivePath, 'dir': shard},
            words: (e) => _unpackWords(archivePath, e));
      } on CacheSearchException catch (e) {
        t.error = _unpackWords(archivePath, e);
        return false;
      }
      if (p == null) return false;
      // Snapshot metadata is unpacked into shard/; keep the catalog, its aliases and the copies' facts (copies.jsonl, which the
      // Bookshelves read in place of packs) at the library root.
      for (final name in ['documents.tsv', 'source-identities.json', 'copies.jsonl']) {
        final from = '$shard$_pathSep$name';
        final to = '$stagePath$_pathSep$name';
        final dev = _dev;
        if (dev != null) {
          if (await dev.exists(from)) await dev.rename(from, to);
        } else {
          final file = File(from);
          if (await file.exists()) await file.rename(to);
        }
      }
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
          settings = (jsonDecode(await _readText(path)) as Map).cast<String, dynamic>();
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
        // A library that was exported from the person's own one keeps `own` (restoring or moving it must leave it writable: Add PDF
        // targets it and its keyword snapshot grows by generations). `own_default` (My books) is kept only when this device has no other
        // own library, as creating one would; otherwise two libraries would both claim to be the default.
        await _writeText(
          '$stagePath$_pathSep$kLibrarySettingsFile',
          const JsonEncoder.withIndent('  ').convert(settingsForImport(settings, deviceHasOtherOwn: ownLibraries.any((l) => l != existing))),
        );
      }
      t
        ..step = AddStep.swapping
        ..fraction = null;
      notifyListeners();
      if (existing == null) {
        await _renameRetry(stagePath, _child(await _freeFolderName(id.isEmpty ? title : id)), once: true);
      } else {
        final err = await _swap(existing, stagePath);
        if (err != null) {
          t.error = err;
          return false;
        }
      }
      installed = true;
      await _afterChange();
      task = null;
      return true;
    } on CacheSearchException catch (e) {
      t.error = _words(e);
      return false;
    } on FileSystemException catch (e) {
      t.error = 'Could not write the library: ${e.message}';
      return false;
    } on DeviceException catch (e) {
      debugPrint('Libraries: ${e.code}: ${e.message}');
      t.error = 'This device could not be reached. Try again.';
      return false;
    } finally {
      if (!installed) await _deleteQuietlyPath(stagePath);
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
    for (var i = 2; await _dirExists(_child(name)); i++) {
      name = '$base-$i';
    }
    return name;
  }

  /// Swaps the checked new copy at [stagePath] in for [old]: the old one is closed and moved aside, the new one put in its place
  /// and opened; if it does not open, the old one is put back. Null when it worked, else what went wrong. In a browser the old
  /// copy is closed by moving it out of the libraries folder and telling the device's core to read the folders again.
  Future<String?> _swap(LibraryItem old, String stagePath) async {
    final path = old.path;
    final asidePath = _child('.${old.folderName}.old');
    await _deleteQuietlyPath(asidePath);
    _closed.add(path);
    try {
      if (_dev == null) await sources.refresh();
      await _renameRetry(path, asidePath);
      if (_dev != null) await _syncSources();
      try {
        await _renameRetry(stagePath, path);
      } catch (e) {
        await _renameRetry(asidePath, path);
        if (_dev != null) await _syncSources();
        return 'Could not put the new copy in place, so ${titleOf(old)} was kept as it was.';
      }
      _closed.remove(path);
      await _afterChange();
      final s = await _whenOpened(LibraryItem.at(path: path).shardPath);
      if (s == null || s.error != null) {
        _closed.add(path);
        if (_dev == null) await sources.refresh();
        await _renameRetry(path, stagePath);
        if (_dev != null) await _syncSources();
        await _renameRetry(asidePath, path);
        _closed.remove(path);
        await _afterChange();
        return 'The new copy could not be opened, so the library was kept as it was.';
      }
      await _deleteQuietlyPath(asidePath);
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

  /// Windows can refuse a rename for a moment while a just-closed library's files are still held. [once]: no second try.
  Future<void> _renameRetry(String from, String to, {bool once = false}) async {
    if (_dev != null) return _dev.rename(from, to);
    for (var i = 0;; i++) {
      try {
        await Directory(from).rename(to);
        return;
      } on FileSystemException {
        if (once || i >= 20) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
      }
    }
  }

  // ---- removing

  /// Removes the library and its index from the device.
  Future<void> remove(LibraryItem l) async {
    error = null;
    if (_dev != null) return _removeOnDevice(l);
    final job = _indexJobs.remove(l.path);
    if (job != null) {
      try {
        await job.cancel();
      } catch (_) {}
    }
    _indexFailed.remove(l.path);
    _closed.add(l.path);
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
      _closed.remove(l.path);
      await _scan();
      await sources.refresh();
      notifyListeners();
    }
  }

  /// A browser: the device removes the library's files and index and reads its folders again.
  Future<void> _removeOnDevice(LibraryItem l) async {
    try {
      await device!.remove('library', l.folderName);
    } on DeviceException catch (e) {
      debugPrint('Libraries: ${e.code}: ${e.message}');
      error = 'Could not remove the library.';
    } finally {
      await _devScan();
      await sources.refresh();
      notifyListeners();
    }
  }

  // ---- the blank template

  // ---- libraries the person made (Add PDF)

  /// The libraries the person made on this device or another of theirs (Add PDF's "My books" and any other they made): their
  /// settings say `"own": true`. Ready-made libraries are never theirs to write to.
  List<LibraryItem> get ownLibraries => [for (final l in libraries) if (l.settings?['own'] == true) l];

  /// The default personal library, "My books" (`"own_default": true`), when it exists.
  LibraryItem? get defaultOwnLibrary => ownLibraries.where((l) => l.settings?['own_default'] == true).firstOrNull;

  Future<LibraryItem>? _makingOwn;

  /// The default personal library, made the first time it is needed (no setup step): an empty library from the core's blank
  /// template (one 1024-dimension Cosine vector, bge-m3), titled [title], with its own id, in the libraries folder like any
  /// other, so it syncs like any library.
  Future<LibraryItem> ensureOwnLibrary({String title = 'My books'}) =>
      defaultOwnLibrary != null ? Future.value(defaultOwnLibrary!) : (_makingOwn ??= _makeOwn(title).whenComplete(() => _makingOwn = null));

  Future<LibraryItem> _makeOwn(String title) async {
    final core = sources.core ?? await sources.whenCoreReady();
    if (core == null || dir == null || _dev != null) throw StateError(sources.unavailable ?? 'Search is not ready yet. Try again in a moment.');
    final tmp = await (tempDirOverride ?? Directory(await appTempPath())).createTemp('own-library');
    final stagePath = _child('.add-${DateTime.now().microsecondsSinceEpoch}');
    var installed = false;
    try {
      final settings = ownLibrarySettings(title: title, id: 'my-books-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}', isDefault: true);
      // its keyword index in its own index/ folder: the Add PDF job extends that one as it adds each book
      await makeBlankLibrary(core, stagePath, settings, tmp, poll: pollInterval);
      final folder = _child(await _freeFolderName('my-books'));
      await _renameRetry(stagePath, folder, once: true);
      installed = true;
      await _afterChange();
      notifyListeners();
      return libraries.firstWhere((l) => l.path == folder, orElse: () => LibraryItem.at(path: folder, settings: settings));
    } finally {
      if (!installed) await _deleteQuietlyPath(stagePath);
      _deleteQuietly(tmp);
    }
  }

  /// Makes the blank library template on the device and hands it to the system's save dialog. True when it was saved.
  Future<bool> saveTemplate() async {
    final core = sources.core;
    if (core == null || makingTemplate) return false;
    makingTemplate = true;
    error = null;
    notifyListeners();
    if (_dev != null) return _saveTemplateOnDevice(core);
    final tmp = await (tempDirOverride ?? Directory(await appTempPath())).createTemp('template');
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

  /// A browser: the device makes the template in its documents folder; the app reads it and hands it to the browser's save.
  Future<bool> _saveTemplateOnDevice(SearchCore core) async {
    final dev = _dev!;
    final folder = '${await dev.docsRoot()}/incoming/.template-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await dev.mkdirs(folder);
      final out = '$folder/$kLibraryTemplateName';
      final p = await _wait(await core.startJob('library_template', {'out_path': out}), (_) {});
      if (p.state != JobState.done) {
        error = 'Could not make the template: ${_words(CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? ''))}';
        return false;
      }
      final bytes = await dev.readBytes(out);
      if (bytes == null) {
        error = 'Could not make the template.';
        return false;
      }
      return await _saveBytes(kLibraryTemplateName, bytes);
    } catch (e) {
      error = 'Could not make the template: ${_words(e)}';
      return false;
    } finally {
      await dev.deleteQuietly(folder);
      makingTemplate = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    device?.removeListener(_onDeviceChanged);
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
    final magic = r.readSync(2);
    // A compressed archive (small ones only: the template, a library file that turned out not to be one) is read unpacked.
    if (magic.length == 2 && magic[0] == 0x1f && magic[1] == 0x8b) {
      if (length > 32 << 20) return null;
      final bytes = gzip.decode(f.readAsBytesSync());
      return _tarNames((at) => at + 512 <= bytes.length ? bytes.sublist(at, at + 512) : const [], bytes.length, max);
    }
    final raf = r;
    return _tarNames((at) {
      raf.setPositionSync(at);
      return raf.readSync(512);
    }, length, max);
  } catch (_) {
    return null;
  } finally {
    r?.closeSync();
  }
}

List<String>? _tarNames(List<int> Function(int at) header, int length, int max) {
  final names = <String>[];
  var at = 0;
  while (names.length < max && at + 512 <= length) {
    final h = header(at);
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
}

/// Copies the member [name] of the tar file [tarFile] (gzip-compressed when [gzipped]) to [out], reading it as a stream, so a
/// large member is never held in memory whole. Throws [FileSystemException] when the member is not there.
Future<void> extractTarMember(File tarFile, String name, File out, {bool gzipped = false}) async {
  Stream<List<int>> input = tarFile.openRead();
  if (gzipped) input = input.transform(gzip.decoder);
  final buf = BytesBuilder(copy: false);
  IOSink? sink;
  var left = 0; // bytes of the current member still to come (with its padding: [pad])
  var pad = 0;
  var found = false;
  var ended = false;
  await for (final chunk in input) {
    if (ended) break;
    buf.add(chunk);
    var bytes = buf.takeBytes();
    var at = 0;
    while (true) {
      if (left > 0 || pad > 0) {
        final n = left > 0 ? (bytes.length - at < left ? bytes.length - at : left) : 0;
        if (n > 0) {
          sink?.add(Uint8List.sublistView(bytes, at, at + n));
          at += n;
          left -= n;
        }
        if (left == 0 && pad > 0) {
          final p = bytes.length - at < pad ? bytes.length - at : pad;
          at += p;
          pad -= p;
        }
        if (left == 0 && pad == 0 && sink != null) {
          await sink.close();
          sink = null;
          ended = true;
          break;
        }
        if (at >= bytes.length) break;
        continue;
      }
      if (bytes.length - at < 512) break;
      final h = Uint8List.sublistView(bytes, at, at + 512);
      at += 512;
      if (h.every((b) => b == 0)) {
        ended = true;
        break;
      }
      var end = 0;
      while (end < 100 && h[end] != 0) {
        end++;
      }
      final member = utf8.decode(h.sublist(0, end), allowMalformed: true);
      final sizeText = String.fromCharCodes(h.sublist(124, 136)).replaceAll(RegExp(r'[^0-7]'), '');
      final size = sizeText.isEmpty ? 0 : int.parse(sizeText, radix: 8);
      left = size;
      pad = (512 - size % 512) % 512;
      if (member == name) {
        found = true;
        sink = out.openWrite();
        if (size == 0) {
          await sink.close();
          sink = null;
          ended = true;
          break;
        }
      }
    }
    if (!ended && at < bytes.length) buf.add(Uint8List.sublistView(bytes, at));
  }
  await sink?.close();
  if (!found) throw FileSystemException('$name is not in the archive', tarFile.path);
}

/// [settings] as they are written for a library that came from elsewhere (an archive, a settings file the person picked): `own` is kept,
/// so an exported own library stays theirs to write to; `own_default` is removed when the device already has [deviceHasOtherOwn]
/// another own library. Only [ownLibrarySettings] makes a new one.
Map<String, dynamic> settingsForImport(Map<String, dynamic> settings, {required bool deviceHasOtherOwn}) {
  final s = {...settings};
  if (deviceHasOtherOwn) s.remove('own_default');
  return s;
}

/// The settings of a library the person makes on the device (Add PDF's My books): the blank template's (bge-m3, the usual
/// fields) with its own id and title, and `"own": true` (`"own_default"` for My books) so it is listed as theirs.
Map<String, dynamic> ownLibrarySettings({required String title, required String id, bool isDefault = false}) => {
  'format': 1,
  'library_id': id,
  'version': '1',
  'title': title,
  'fields': {'title': 'title', 'text': 'text', 'page': 'page', 'source_type': 'source', 'link': 'link', 'document': 'doc_id'},
  'leave_out': <String>[],
  'embedding': {
    'vector': '',
    'model': 'bge-m3-Q8_0.gguf',
    'sha256': 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb',
    'dims': 1024,
    'repo': 'lm-kit/bge-m3-gguf',
    'revision': '9379ce497e8814b200f2dc0d18eb4045426dcb8c',
    'path': 'bge-m3-Q8_0.gguf',
    'size': 634553856,
  },
  'keyword_index': 'auto',
  'own': true,
  if (isDefault) 'own_default': true,
};

/// Makes an empty library at [folder] (which must not exist) with [settings]: the core's blank template (library_template),
/// its shard snapshot unpacked (unpack_library), the keyword index when the settings want one (index_library, with [index]'s
/// parameters for the shard and index folders), and cache-library.json beside it. [tmp] holds the template meanwhile.
Future<void> makeBlankLibrary(
  SearchCore core,
  String folder,
  Map<String, dynamic> settings,
  Directory tmp, {
  Map<String, dynamic> Function(String shard, String index)? index,
  Duration poll = const Duration(milliseconds: 250),
}) async {
  final sep = Platform.pathSeparator;
  Future<JobProgress> run(String kind, Map<String, dynamic> params) async {
    final job = await core.startJob(kind, params);
    try {
      while (true) {
        final p = await job.progress();
        if (p.isFinished) {
          if (p.state != JobState.done) throw CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? 'The library could not be made');
          return p;
        }
        await Future<void>.delayed(poll);
      }
    } finally {
      try {
        await job.free();
      } catch (_) {}
    }
  }

  final template = '${tmp.path}$sep$kLibraryTemplateName';
  await run('library_template', {'out_path': template});
  // the template is a gzip'd tar holding the blank shard snapshot, the settings and a README: the snapshot is what unpacks
  final snapshot = '${tmp.path}${sep}blank-library.snapshot';
  await extractTarMember(File(template), 'blank-library.snapshot', File(snapshot), gzipped: true);
  await Directory(folder).create(recursive: true);
  final shard = '$folder${sep}shard';
  final p = await run('unpack_library', {'snapshot_path': snapshot, 'dir': shard, 'settings': settings});
  final detail = p.detail ?? const {};
  final keyword = (settings['keyword_index'] ?? 'auto') as String;
  if (keyword == 'on' || (keyword == 'auto' && detail['own_text_index'] != true)) {
    final indexDir = '$folder${sep}index';
    await run('index_library', index?.call(shard, indexDir) ?? {'library_path': shard, 'index_dir': indexDir, 'heap_mb': 200, 'settings': settings});
  }
  await File('$folder$sep$kLibrarySettingsFile').writeAsString(const JsonEncoder.withIndent('  ').convert(settings), flush: true);
}
