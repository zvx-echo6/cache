import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../chat/tool.dart';
import '../search/search_access.dart';

/// One ZIM file in the sources folder.
class ZimFile {
  ZimFile({required this.path, required this.size});

  final String path;
  final int size;

  String get fileName => path.split(RegExp(r'[\\/]')).last;
  String get name => fileName.replaceFirst(RegExp(r'\.zim$', caseSensitive: false), '');
}

/// Where a ZIM stands: its index is made on the phone, slowly, in the background.
enum ZimPhase { waiting, indexing, ready, failed }

/// The sources the user added (today: ZIM files) and the search core that reads them. Owns the core,
/// starts the index job of every new ZIM, and answers the assistant's search and read calls.
class SourcesState extends ChangeNotifier implements SearchAccess {
  SourcesState({this.zimsDirOverride, this.indexesDirOverride, this.nativeFactory, this.extraConfig});

  /// Test hooks.
  final Directory? zimsDirOverride;
  final Directory? indexesDirOverride;
  final CsNativeFactory? nativeFactory;

  /// The other sections of the core's config (places, routing, saved places), found when the app starts: the map's search and
  /// routing read them. Null for none.
  final Future<Map<String, dynamic>> Function()? extraConfig;

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

  /// The search core, for the map's calls. Null until it is open (or when this device cannot open it).
  SearchCore? get core => _core;

  /// The sections of the config beyond the sources, as they were when the core was opened.
  Map<String, dynamic> openedExtra = const {};

  Future<void> init() async {
    zimsDir = zimsDirOverride ?? await _defaultZimsDir();
    indexesDir = indexesDirOverride ?? Directory('${(await getApplicationSupportDirectory()).path}/indexes');
    await zimsDir!.create(recursive: true);
    await indexesDir!.create(recursive: true);
    _scan();
    notifyListeners();
    try {
      openedExtra = await extraConfig?.call() ?? const {};
      _core = await SearchCore.open(_configs(), native: nativeFactory ?? _defaultNative, extraConfig: openedExtra);
    } catch (e) {
      unavailable = e is CacheSearchException ? e.message : 'Search is not available on this device';
      notifyListeners();
      return;
    }
    await refresh();
  }

  static CsNative _defaultNative() => FfiCsNative.open();

  Future<Directory> _defaultZimsDir() async {
    final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
    return Directory('${base.path}/zims');
  }

  String _indexDir(ZimFile z) => '${indexesDir!.path}/${z.fileName}.idx';

  List<SourceConfig> _configs() => [for (final z in zims) SourceConfig.zim(path: z.path, indexDir: _indexDir(z))];

  void _scan() {
    final found = <ZimFile>[];
    for (final f in zimsDir!.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.zim')) found.add(ZimFile(path: f.path, size: f.lengthSync()));
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
  String? failureOf(ZimFile z) => _failed[z.path] ?? _status[z.path]?.error?.message;

  /// Articles the ZIM's index holds, once ready.
  int docsOf(ZimFile z) => _status[z.path]?.docs ?? 0;

  /// The line for Home's Reading card.
  String get summary {
    if (unavailable != null) return 'Not available';
    if (zims.isEmpty) return 'No sources yet';
    final ready = zims.where((z) => phaseOf(z) == ZimPhase.ready).length;
    final indexing = zims.where((z) => phaseOf(z) == ZimPhase.indexing).toList();
    if (indexing.isNotEmpty) {
      final f = indexFraction(indexing.first);
      return f == null ? 'Indexing…' : 'Indexing ${(f * 100).toStringAsFixed(0)}%';
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
        if (s == null || s.error != null || s.searchable || s.building || _jobs.containsKey(z.path) || _failed.containsKey(z.path)) continue;
        await _startIndex(core, z);
      }
    } catch (e) {
      error = _words(e);
    } finally {
      _busyRefresh = false;
      notifyListeners();
    }
  }

  Future<void> _readStatus(SearchCore core) async {
    _status
      ..clear()
      ..addEntries([for (final s in await core.status()) MapEntry(s.path, s)]);
  }

  Future<void> _startIndex(SearchCore core, ZimFile z) async {
    try {
      _jobs[z.path] = await core.startJob('index_zim', {'zim_path': z.path, 'index_dir': _indexDir(z), 'heap_mb': 200});
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
        if (p.state == JobState.failed) _failed[entry.key] = p.errorMessage ?? 'Indexing failed';
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
      final idx = Directory(_indexDir(z));
      if (idx.existsSync()) idx.deleteSync(recursive: true);
    } catch (e) {
      error = 'Could not remove the file: $e';
    }
    await refresh();
  }

  String _words(Object e) => e is CacheSearchException ? e.message : e.toString().replaceFirst('Bad state: ', '');

  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async {
    final core = _core ?? (throw StateError(unavailable ?? 'Search is not ready yet'));
    final ready = [for (final s in _status.values) if (s.searchable) s.id!];
    if (ready.isEmpty) {
      throw StateError(zims.isEmpty ? 'No sources have been added to this phone yet' : 'The sources are still being indexed');
    }
    final r = await core.search(query, k: k);
    return [for (final h in r.results) SourceResult(title: h.title, snippet: h.snippet, address: h.address)];
  }

  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) async {
    final core = _core ?? (throw StateError(unavailable ?? 'Search is not ready yet'));
    final r = await core.read(address, maxChars: maxChars);
    return ReadPage(title: r.title, text: r.text, truncated: r.truncated);
  }

  /// Makes the numbering of a new chat in the core, or null when there is no core (then the loop counts itself).
  Future<CoreConversation> newConversation() async =>
      (_core ?? (throw StateError(unavailable ?? 'Search is not ready yet'))).newConversation();

  @override
  void dispose() {
    _poll?.cancel();
    _core?.close();
    super.dispose();
  }
}
