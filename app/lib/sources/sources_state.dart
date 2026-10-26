import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../browse/opds.dart';
import '../chat/system_prompt.dart';
import '../chat/tool.dart';
import '../maps/layers/starter_defs.dart';
import '../search/core_config.dart';
import '../search/icu_data.dart';
import '../search/search_access.dart';

/// One ZIM file in the sources folder.
class ZimFile {
  ZimFile({required this.path, required this.size});

  final String path;
  final int size;

  String get fileName => path.split(RegExp(r'[\\/]')).last;
  String get name =>
      fileName.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');

  /// The catalogue identity from the file name (Kiwix's naming), or null.
  ZimOrigin? get nameOrigin => ZimOrigin.fromFileName(fileName);
}

/// Where a ZIM stands: its index is made on the phone, slowly, in the background.
enum ZimPhase { waiting, indexing, ready, failed }

/// The sources the user added (today: ZIM files) and the search core that reads them. Owns the core,
/// starts the index job of every new ZIM, and answers the assistant's search and read calls.
class SourcesState extends ChangeNotifier implements SearchAccess {
  SourcesState({
    this.zimsDirOverride,
    this.indexesDirOverride,
    this.nativeFactory,
    this.coreExtras,
  });

  /// Test hooks.
  final Directory? zimsDirOverride;
  final Directory? indexesDirOverride;
  final CsNativeFactory? nativeFactory;

  /// Test hook: the cs_open sections besides the sources. By default they are built from the app's folders ([buildCoreExtras]).
  final Map<String, dynamic>? coreExtras;

  Directory? zimsDir;
  Directory? indexesDir;
  List<ZimFile> zims = [];

  SearchCore? _core;

  /// Why search cannot be used on this device, or null.
  String? unavailable;

  /// The last problem to show on the Sources screen (copy or index failure).
  String? error;

  /// 0..1 while a file is being copied in, else null.
  double? copyProgress;
  String? copyName;

  final Map<String, SourceStatus> _status = {};
  final Map<String, CoreJobHandle> _jobs = {};
  final Map<String, JobProgress> _progress = {};
  final Map<String, String> _failed = {};
  Timer? _poll;
  bool _busyRefresh = false;

  bool get coreReady => _core != null;

  final Completer<SearchCore?> _coreOpened = Completer<SearchCore?>();

  /// The core once startup has finished (null when it could not open). The map's layer engine waits for it.
  Future<SearchCore?> whenCoreReady() => _coreOpened.future;

  Map<String, dynamic> _extra = const {};

  /// The "layers" section of the core's config, which a layer download job takes along.
  Map<String, dynamic> get layersSection => ((_extra['layers'] as Map?) ?? const {}).cast<String, dynamic>();

  /// The sections of the config beyond the sources, as they were when the core was opened (the map's search and routing
  /// look for `places` and `routing` here).
  Map<String, dynamic> get openedExtra => _extra;

  Future<void> init() async {
    zimsDir = zimsDirOverride ?? await _defaultZimsDir();
    indexesDir =
        indexesDirOverride ??
        Directory('${(await getApplicationSupportDirectory()).path}/indexes');
    await zimsDir!.create(recursive: true);
    await indexesDir!.create(recursive: true);
    _scan();
    notifyListeners();
    try {
      final extra = _extra = coreExtras ?? await _defaultExtras();
      _core = await SearchCore.open(
        _configs(),
        extra: extra,
        native: nativeFactory ?? _defaultNative,
      );
    } catch (e, stack) {
      debugPrint('Search core startup failed: $e');
      debugPrintStack(stackTrace: stack);
      unavailable = e is CacheSearchException
          ? e.message
          : 'Search is not available on this device';
      notifyListeners();
      if (!_coreOpened.isCompleted) _coreOpened.complete(null);
      return;
    }
    if (!_coreOpened.isCompleted) _coreOpened.complete(_core);
    await _applyFix();
    await refresh();
  }

  static CsNative _defaultNative() => FfiCsNative.open();

  Future<Map<String, dynamic>> _defaultExtras() async {
    final files =
        (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
        await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    // libzim reads its ICU data from the folder ICU_DATA names, so this comes before the first cs_open.
    try {
      await installIcuData(supportDir: support);
    } catch (e) {
      debugPrint('ICU data: $e');
    }
    final defs = Directory('${support.path}/layer-defs');
    await installStarterLayers(defs);
    return buildCoreExtras(
      filesDir: files,
      supportDir: support,
      layerDefsDir: defs,
      shim: shimPath(Platform.isAndroid ? nativeLibraryDir() : null),
    );
  }

  /// The core, for the tools and the host that feed it (null until it is open).
  SearchCore? get core => _core;

  /// The phone's GPS fix for the tools that default to "where I am"; null forgets it.
  Future<void> setLocation(
    double? lat,
    double? lon, {
    double accuracyM = -1,
    DateTime? at,
  }) async {
    _fix = lat == null || lon == null
        ? null
        : (lat, lon, accuracyM, at ?? DateTime.now());
    await _applyFix();
  }

  (double, double, double, DateTime)? _fix;

  /// Sends the latest fix to the core; also done once the core is open, for a fix that came before it.
  Future<void> _applyFix() async {
    final core = _core;
    if (core == null) return;
    final f = _fix;
    try {
      if (f == null) {
        await core.clearLocation();
      } else {
        await core.setLocation(
          f.$1,
          f.$2,
          accuracyM: f.$3,
          fixedAt: isoWithOffset(f.$4),
        );
      }
    } catch (_) {
      // A bad or late fix is not a reason to stop the app; the tools answer no_location.
    }
  }

  Future<Directory> _defaultZimsDir() async {
    final base =
        (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
        await getApplicationDocumentsDirectory();
    return Directory('${base.path}/zims');
  }

  String _indexDir(ZimFile z) => '${indexesDir!.path}/${z.fileName}.idx';

  List<SourceConfig> _configs() => [
    for (final z in zims)
      SourceConfig.zim(path: z.path, indexDir: _indexDir(z)),
  ];

  /// Where unfinished downloads wait, on the same file system as the ZIMs so finishing is a rename.
  Directory get partialDir => Directory('${zimsDir!.path}/.partial');

  File _originFile(String zimPath) => File('$zimPath.origin.json');
  File _iconFile(String zimPath) => File('$zimPath.icon.png');

  /// The icon saved when the ZIM came from the catalogue, or null.
  File? iconOf(ZimFile z) {
    final f = _iconFile(z.path);
    return f.existsSync() ? f : null;
  }

  /// What this ZIM is in the catalogue's terms: the record saved at install, else the file name's.
  ZimOrigin? originOf(ZimFile z) {
    try {
      final f = _originFile(z.path);
      if (f.existsSync()) {
        return ZimOrigin.fromJson(
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>(),
        );
      }
    } catch (_) {}
    return z.nameOrigin;
  }

  /// The ZIM's own title from its metadata (the file name until the core has opened it).
  String titleOf(ZimFile z) {
    final t = _status[z.path]?.title;
    if (t != null && t.isNotEmpty) return t;
    final o = originOf(z);
    if (o != null && o.title.isNotEmpty) return o.title;
    return z.name;
  }

  /// The ZIM's UUID (the id its addresses use), or null until the core has opened it.
  String? idOf(ZimFile z) => _status[z.path]?.id;

  ZimFile? zimById(String id) {
    for (final z in zims) {
      if (idOf(z) == id) return z;
    }
    return null;
  }

  void _scan() {
    final found = <ZimFile>[];
    for (final f in zimsDir!.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.zim')) {
        found.add(ZimFile(path: f.path, size: f.lengthSync()));
      }
    }
    found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    zims = found;
  }

  ZimPhase phaseOf(ZimFile z) {
    if (_failed.containsKey(z.path)) return ZimPhase.failed;
    final s = _status[z.path];
    if (s == null) return ZimPhase.waiting;
    if (s.error != null) return ZimPhase.failed;
    if (s.searchable) return ZimPhase.ready;
    if (_jobs.containsKey(z.path) || s.building) return ZimPhase.indexing;
    return ZimPhase.waiting;
  }

  /// Indexing progress 0..1, or null if not known.
  double? indexFraction(ZimFile z) => _progress[z.path]?.fraction;

  /// Why a ZIM failed, in words for people.
  String? failureOf(ZimFile z) =>
      _failed[z.path] ?? _status[z.path]?.error?.message;

  /// Articles the ZIM's index holds, once ready.
  int docsOf(ZimFile z) => _status[z.path]?.docs ?? 0;

  /// The line for Home's Reading card.
  String get summary {
    if (unavailable != null) return 'Not available';
    if (zims.isEmpty) return 'No sources yet';
    final ready = zims.where((z) => phaseOf(z) == ZimPhase.ready).length;
    final indexing = zims
        .where((z) => phaseOf(z) == ZimPhase.indexing)
        .toList();
    if (indexing.isNotEmpty) {
      final f = indexFraction(indexing.first);
      return f == null
          ? 'Indexing…'
          : 'Indexing ${(f * 100).toStringAsFixed(0)}%';
    }
    return ready == 1 ? '1 source' : '$ready sources';
  }

  /// Scans the folder again, hands the list to the core and starts the index job of every ZIM that has none.
  Future<void> refresh() async {
    if (_busyRefresh) return;
    _busyRefresh = true;
    try {
      _scan();
      final core = _core;
      if (core == null) return;
      await core.setSources(_configs());
      await _readStatus(core);
      for (final z in zims) {
        final s = _status[z.path];
        if (s == null ||
            s.error != null ||
            s.searchable ||
            s.building ||
            _jobs.containsKey(z.path) ||
            _failed.containsKey(z.path)) {
          continue;
        }
        await _startIndex(core, z);
      }
    } catch (e) {
      error = _words(e);
    } finally {
      _busyRefresh = false;
      notifyListeners();
    }
  }

  final Set<String> _loggedStatus = {};

  Future<void> _readStatus(SearchCore core) async {
    _status
      ..clear()
      ..addEntries([for (final s in await core.status()) MapEntry(s.path, s)]);
    // One line per change, for logcat: where each source's keyword search comes from (the ZIM's own Xapian index through libzim).
    for (final s in _status.values) {
      final line = 'cache source ${s.title}: indexed=${s.indexed} keyword_source=${s.keywordSource} docs=${s.docs}';
      if (_loggedStatus.add(line)) debugPrint(line);
    }
  }

  Future<void> _startIndex(SearchCore core, ZimFile z) async {
    try {
      _jobs[z.path] = await core.startJob('index_zim', {
        'zim_path': z.path,
        'index_dir': _indexDir(z),
        'heap_mb': 200,
      });
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _pollJobs());
    } on CacheSearchException catch (e) {
      if (e.code != 'busy') _failed[z.path] = e.message;
    }
  }

  bool _polling = false;

  Future<void> _pollJobs() async {
    if (_polling) return;
    _polling = true;
    try {
      var finished = false;
      for (final entry in _jobs.entries.toList()) {
        final p = await entry.value.progress();
        _progress[entry.key] = p;
        if (!p.isFinished) continue;
        finished = true;
        await entry.value.free();
        _jobs.remove(entry.key);
        _progress.remove(entry.key);
        if (p.state == JobState.failed) {
          _failed[entry.key] = p.errorMessage ?? 'Indexing failed';
        }
      }
      if (_jobs.isEmpty) {
        _poll?.cancel();
        _poll = null;
      }
      final core = _core;
      if (finished && core != null) {
        // A source whose index was being built is picked up again when the list is set again.
        await core.setSources(_configs());
        await _readStatus(core);
      }
    } catch (e) {
      error = _words(e);
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  /// Lets the user pick a .zim file and copies it into the sources folder (like a model), then indexes it.
  Future<void> pickAndAddZim() async {
    final picked = await FilePicker.pickFile();
    if (picked == null || picked.path == null) return;
    await addZim(File(picked.path!), name: picked.name);
  }

  Future<void> addZim(File src, {String? name}) async {
    final fileName = name ?? src.path.split(RegExp(r'[\\/]')).last;
    if (!fileName.toLowerCase().endsWith('.zim')) {
      error = 'That is not a .zim file.';
      notifyListeners();
      return;
    }
    error = null;
    final dest = File('${zimsDir!.path}/$fileName');
    final total = await src.length();
    copyName = fileName;
    copyProgress = 0;
    notifyListeners();
    try {
      final sink = dest.openWrite();
      var done = 0;
      var lastReport = 0.0;
      await for (final chunk in src.openRead()) {
        sink.add(chunk);
        done += chunk.length;
        final p = total == 0 ? 1.0 : done / total;
        if (p - lastReport >= 0.005) {
          lastReport = p;
          copyProgress = p;
          notifyListeners();
        }
        // Do not let the sink buffer gigabytes in memory.
        if (done % (64 * 1024 * 1024) < chunk.length) await sink.flush();
      }
      await sink.close();
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    } catch (e) {
      if (dest.existsSync()) dest.deleteSync();
      error = 'Could not copy the file: $e';
      copyProgress = null;
      copyName = null;
      notifyListeners();
      return;
    }
    copyProgress = null;
    copyName = null;
    _failed.remove(dest.path);
    await refresh();
  }

  /// Moves a finished download into the sources folder, records where it came from, and indexes it.
  /// [entry] is the catalogue entry it came from; [icon] the entry's icon bytes if they were fetched.
  Future<ZimFile> installDownloaded(
    File finished, {
    CatalogEntry? entry,
    Uint8List? icon,
    String? fileName,
  }) async {
    final name =
        fileName ??
        finished.path
            .split(RegExp(r'[\\/]'))
            .last
            .replaceFirst(RegExp(r'\.part$'), '');
    final dest = File('${zimsDir!.path}/$name');
    if (dest.existsSync()) dest.deleteSync();
    try {
      finished.renameSync(dest.path);
    } on FileSystemException {
      // Another file system: copy, then drop the original.
      await finished.copy(dest.path);
      finished.deleteSync();
    }
    if (entry != null) {
      await _originFile(
        dest.path,
      ).writeAsString(jsonEncode(ZimOrigin.fromEntry(entry).toJson()));
      if (icon != null && icon.isNotEmpty) {
        await _iconFile(dest.path).writeAsBytes(icon);
      }
    }
    _failed.remove(dest.path);
    await refresh();
    return zims.firstWhere(
      (z) => z.path == dest.path,
      orElse: () => ZimFile(path: dest.path, size: dest.lengthSync()),
    );
  }

  /// True when the ZIM at [path] can be searched.
  bool isReadyPath(String path) {
    final s = _status[path];
    return s != null && s.searchable;
  }

  /// Raw bytes of an entry (the reader serves them to its page).
  Future<ZimBytes> zimGet(String address) async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet')))
          .zimGet(address);

  Future<String> zimMainPage(String zimId) async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet')))
          .zimMainPage(zimId);

  Future<List<Suggestion>> suggest(
    String prefix, {
    int k = 10,
    List<String>? zimIds,
  }) async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet')))
          .suggest(prefix, k: k, sources: zimIds);

  /// Full-text search, optionally limited to some ZIMs.
  Future<SearchResponse> searchIn(
    String query, {
    List<String>? zimIds,
    int k = 20,
    int offset = 0,
  }) async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet')))
          .search(query, k: k, offset: offset, sources: zimIds);

  /// Removes a ZIM and its index from the phone.
  Future<void> remove(ZimFile z) async {
    final job = _jobs.remove(z.path);
    if (job != null) {
      try {
        await job.cancel();
        // The job stops at its next checkpoint; it is freed once it says so.
        for (var i = 0; i < 50; i++) {
          if ((await job.progress()).isFinished) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await job.free();
      } catch (_) {}
    }
    _progress.remove(z.path);
    _failed.remove(z.path);
    try {
      final f = File(z.path);
      if (f.existsSync()) f.deleteSync();
      for (final side in [_originFile(z.path), _iconFile(z.path)]) {
        if (side.existsSync()) side.deleteSync();
      }
      final idx = Directory(_indexDir(z));
      if (idx.existsSync()) idx.deleteSync(recursive: true);
    } catch (e) {
      error = 'Could not remove the file: $e';
    }
    await refresh();
  }

  String _words(Object e) => e is CacheSearchException
      ? e.message
      : e.toString().replaceFirst('Bad state: ', '');

  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async {
    final core =
        _core ?? (throw StateError(unavailable ?? 'Search is not ready yet'));
    final ready = [
      for (final s in _status.values)
        if (s.searchable) s.id!,
    ];
    if (ready.isEmpty) {
      throw StateError(
        zims.isEmpty
            ? 'No sources have been added to this phone yet'
            : 'The sources are still being indexed',
      );
    }
    final r = await core.search(query, k: k);
    return [
      for (final h in r.results)
        SourceResult(title: h.title, snippet: h.snippet, address: h.address),
    ];
  }

  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) async {
    final core =
        _core ?? (throw StateError(unavailable ?? 'Search is not ready yet'));
    final r = await core.read(address, maxChars: maxChars);
    return ReadPage(title: r.title, text: r.text, truncated: r.truncated);
  }

  /// Makes the numbering of a new chat in the core, or null when there is no core (then the loop counts itself).
  Future<CoreConversation> newConversation() async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet')))
          .newConversation();

  @override
  void dispose() {
    _poll?.cancel();
    _core?.close();
    super.dispose();
  }
}
