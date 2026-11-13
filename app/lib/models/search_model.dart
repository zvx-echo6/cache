import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:http/http.dart' as http;

import '../app_state.dart';
import '../maps/ui/format.dart';
import '../platform.dart' as plat;
import '../platform/app_log.dart';
import '../platform/bench_options.dart' show benchEmbedThreads;
import '../platform/memory.dart';
import '../sources/sources_state.dart' show LibraryEmbedding;
import 'hf_hub.dart';
import 'model_downloads.dart';

/// A search model: an embedding GGUF pinned to one file on Hugging Face (repository, commit, path, size and SHA-256).
class SearchModelSpec {
  const SearchModelSpec({
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.repo,
    required this.path,
    required this.revision,
  });

  /// The name in the models folder, which is also the model id a query vector carries.
  final String fileName;
  final int size;
  final String sha256;
  final String repo;

  /// The file inside [repo].
  final String path;

  /// The commit of [repo] it is downloaded from.
  final String revision;

  /// The size as the app shows it next to the name, counted the way the download progress counts it ("605 MB").
  String get sizeLabel => formatBytes(size);

  HfFile get file => HfFile(repo: repo, path: path, size: size, sha256: sha256, revision: revision);
}

/// Cache's search model: bge-m3, Q8_0. The places packs' meaning vectors are made with it (`cache_embed::DECIDED_MODEL_*`),
/// and the same copy embeds the queries of the map search, the library search and the assistant's search tool. It is not a
/// chat model and is not part of any region download.
const SearchModelSpec kSearchModel = SearchModelSpec(
  fileName: 'bge-m3-Q8_0.gguf',
  size: 634553856,
  sha256: 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb',
  repo: 'lm-kit/bge-m3-gguf',
  path: 'bge-m3-Q8_0.gguf',
  revision: '9379ce497e8814b200f2dc0d18eb4045426dcb8c',
);

/// The search models the app knows. Their files are kept out of the chat model list.
const List<SearchModelSpec> kSearchModels = [kSearchModel];

/// True when [fileName] is a registered search model, not a chat model.
bool isSearchModelFile(String fileName) => kSearchModels.any((m) => m.fileName == fileName);

/// The words shown where meaning search is not possible because the search model is missing.
const String kNeedsSearchModel = 'Meaning search needs the search model.';

/// Embeds a query with one embedding GGUF in the models folder. The model loads on first use and goes again after a couple
/// of idle minutes; with no model file the answer is null, and the core searches by keywords.
///
/// In a browser (the web branch, [remote]) the model is the server's: the vectors come from its `POST /api/embed`, and there is
/// no models folder here. [serverReady] says whether the server has the model; while it has not, the answer is null (keywords).
class SearchEmbedder {
  SearchEmbedder({
    required this.modelsDir,
    this.fileName = 'bge-m3-Q8_0.gguf',
    CacheEmbedder Function(String path)? make,
    bool? remote,
    this.serverReady,
  }) : remote = remote ?? plat.isWeb,
       _make = make ?? ((p) => CacheEmbedder(modelPath: p, threads: benchEmbedThreads > 0 ? benchEmbedThreads : 4)..onTiming = logInfo);

  final Future<Directory> Function() modelsDir;
  final String fileName;

  /// Web: the vectors come from the server.
  final bool remote;

  /// Web: whether the server's search model is ready (null: ask the server and see).
  final bool Function()? serverReady;
  final CacheEmbedder Function(String path) _make;
  CacheEmbedder? _embedder;

  /// The model id and vector of [text], or null when the model file is not there.
  Future<(String, List<double>)?> embed(String text) async {
    var e = _embedder;
    if (remote) {
      if (serverReady != null && !serverReady!()) return null;
      e ??= _embedder = _make(fileName);
      try {
        return (e.modelId, await e.embed(text));
      } on EmbedRemoteException catch (err) {
        // The model is not on the server (its download has started): keywords, as a phone without the model.
        if (err.modelMissing) return null;
        rethrow;
      }
    }
    if (e == null) {
      final file = File('${(await modelsDir()).path}${Platform.pathSeparator}$fileName');
      if (!file.existsSync()) return null;
      e = _embedder = _make(file.path);
    }
    return (e.modelId, await e.embed(text));
  }

  /// True while the model is held warm ([warm] ran and [release] has not).
  bool get isWarm => _warm;
  bool _warm = false;

  /// Loads the model now and holds it (no idle release) until [release]. False when there is no model file here (nothing was
  /// loaded) or the browser holds the model on the server. A load that fails throws.
  Future<bool> warm() async {
    if (remote) return false;
    var e = _embedder;
    if (e == null) {
      final file = File('${(await modelsDir()).path}${Platform.pathSeparator}$fileName');
      if (!file.existsSync()) return false;
      e = _embedder ??= _make(file.path);
    }
    e.keepLoaded = true;
    _warm = true;
    await e.warm();
    return true;
  }

  /// Lets the model go from memory and goes back to loading on use and idling out. True when there was a model to let go.
  bool release() {
    final e = _embedder;
    _warm = false;
    if (e == null) return false;
    e.keepLoaded = false;
    e.free();
    return true;
  }

  /// The map search's query vector.
  Future<MapQueryVector?> call(String text) async {
    final v = await embed(text);
    return v == null ? null : MapQueryVector(v.$1, v.$2);
  }

  Future<void> dispose() async => _embedder?.dispose();
}

enum SearchModelState { missing, downloading, ready, failed }

/// The search model on this phone: whether it is there, its download (queued after the first chat model), the one-time offer
/// to existing installs, and the embedders. One [embedder] serves the map, the library search and the assistant; a library
/// whose settings name another embedding model gets that model's own embedder, when that file is in the models folder.
class SearchModel extends ChangeNotifier implements LibraryEmbedding {
  SearchModel({
    required this.app,
    required Future<Directory> Function() modelsDir,
    this.downloads,
    this.spec = kSearchModel,
    CacheEmbedder Function(String path)? make,
    bool? remote,
    EmbedHttp? serverHttp,
    this.pollInterval = const Duration(seconds: 2),
    Future<MemoryReading?> Function()? readMemoryNow,
    Map<String, int> Function()? readCounters,
  }) : _readMemory = readMemoryNow ?? readMemory,
       _readCounters = readCounters ?? _processCounters,
       _modelsDir = modelsDir,
       _make = make,
       remote = remote ?? plat.isWeb,
       _http = serverHttp ?? _serverHttp {
    embedder = SearchEmbedder(
      modelsDir: modelsDir,
      fileName: spec.fileName,
      make: make,
      remote: this.remote,
      serverReady: () => _server?.ready ?? false,
    );
    app.addListener(notifyListeners);
    downloads?.addListener(notifyListeners);
  }

  /// The app's search model (set up at start); null in tests that don't need it.
  static SearchModel? shared;

  final AppState app;
  final ModelDownloads? downloads;
  final SearchModelSpec spec;
  final Future<Directory> Function() _modelsDir;
  final CacheEmbedder Function(String path)? _make;

  /// The one shared embedder of the search model.
  late final SearchEmbedder embedder;

  /// Web: the model is the server's, not a file here; [state] and [has] follow `GET /api/models/embedder` ([refreshServer]).
  final bool remote;
  final EmbedHttp _http;

  final Future<MemoryReading?> Function() _readMemory;
  final Map<String, int> Function() _readCounters;

  /// How often [ensure] asks the server how its download goes.
  final Duration pollInterval;
  ServerEmbedderStatus? _server;
  bool _disposed = false;

  /// Web: what the server last said about its search model (null before the first answer).
  ServerEmbedderStatus? get serverStatus => _server;

  /// Web: asks the server whether it has the search model. An answer that cannot be had leaves the last one.
  Future<void> refreshServer() async {
    try {
      final r = await _http('GET', '/api/models/embedder', null);
      final st = r.status == 200 ? ServerEmbedderStatus.parse(r.body) : null;
      if (st != null) _setServer(st);
    } catch (e) {
      logInfo('The server\'s search model could not be read', detail: '$e');
    }
  }

  void _setServer(ServerEmbedderStatus st) {
    _server = st;
    if (!_disposed) notifyListeners();
  }

  /// Embedders of other models that libraries name, by model id, made on first use.
  final Map<String, SearchEmbedder> _others = {};

  SearchModelState get state {
    if (remote) {
      return switch (_server?.state) {
        ServerEmbedderState.ready => SearchModelState.ready,
        ServerEmbedderState.downloading => SearchModelState.downloading,
        ServerEmbedderState.error => SearchModelState.failed,
        _ => SearchModelState.missing,
      };
    }
    if (app.searchModel != null) return SearchModelState.ready;
    final d = downloads;
    if (d != null && d.searchModelQueued) return SearchModelState.downloading;
    if (d?.searchModelError != null) return SearchModelState.failed;
    return SearchModelState.missing;
  }

  /// Why the last download stopped, when [state] is failed.
  String? get failure => remote ? _server?.error : downloads?.searchModelError;

  /// Starts the download, or queues it after the one running. Completes when it has finished or stopped.
  Future<void> ensure({bool anyway = false}) async {
    if (remote) return _ensureOnServer();
    if (state == SearchModelState.ready || state == SearchModelState.downloading) return;
    final d = downloads;
    if (d == null) return;
    await d.start(d.searchModel ?? spec.file, anyway: anyway);
  }

  /// Web: has the server download its search model, and follows the download until it ends.
  Future<void> _ensureOnServer() async {
    if (state == SearchModelState.ready) return;
    try {
      final r = await _http('POST', '/api/models/embedder/download', '{}');
      final st = r.status == 200 ? ServerEmbedderStatus.parse(r.body) : null;
      if (st == null) {
        _setServer(ServerEmbedderStatus(ServerEmbedderState.error, error: 'The server could not start the download (HTTP ${r.status})'));
        return;
      }
      _setServer(st);
      while (!_disposed && _server?.state == ServerEmbedderState.downloading) {
        await Future<void>.delayed(pollInterval);
        if (!_disposed) await refreshServer();
      }
    } catch (e) {
      _setServer(ServerEmbedderStatus(ServerEmbedderState.error, error: 'The server could not be reached: $e'));
    }
  }

  // ---------------- warm while the person is in Ask or in search ----------------

  /// Memory kept free on top of the model's file before it is loaded ahead of use.
  static const int warmMargin = 512 << 20;

  /// True while the app is in front. Opening Cache or coming back to the front loads nothing: the model is loaded and held
  /// warm (no idle release) by [warmLoad], which runs when the person opens Ask or a search box ([aboutToSearch]).
  bool _foreground = true;
  bool _warmWanted = false;
  Future<void>? _warmRun;

  /// True while the model is loaded ahead of use and held.
  bool get isWarm => embedder.isWarm;

  /// The person opened Ask or put the cursor in a search box: the app's search model loads ahead of the search ([warmLoad]).
  static void aboutToSearch() => unawaited(shared?.warmLoad());

  /// Loads the search model in the background when it is installed and the phone has room for it (its file plus
  /// [warmMargin]); a search then finds it loaded. Never throws; call it without awaiting. Does nothing in a browser, where the
  /// server holds the model, when the model is not here, when memory is short or unknown, or when it is loaded or loading.
  Future<void> warmLoad() {
    if (remote || _disposed) return Future.value();
    // One load at a time: a call that comes while one runs (a resume right after a release) goes after it.
    final run = (_warmRun ?? Future<void>.value()).then((_) => _warmLoad());
    _warmRun = run;
    return run.whenComplete(() {
      if (identical(_warmRun, run)) _warmRun = null;
    });
  }

  Future<void> _warmLoad() async {
    _warmWanted = true;
    try {
      final entry = app.searchModel;
      if (entry == null || embedder.isWarm || !_foreground) return;
      final need = entry.size + warmMargin;
      final reading = await _readMemory();
      if (!_warmWanted || _disposed) return;
      if (reading == null || reading.avail < need) {
        logInfo('Search model: warm load skipped (${reading == null ? 'memory unknown' : 'available ${reading.avail >> 20} MB'}, needs ${need >> 20} MB)');
        return;
      }
      logInfo('Search model: warm load started');
      final before = _readCounters();
      final sw = Stopwatch()..start();
      final loaded = await embedder.warm();
      if (!loaded) return;
      final after = _readCounters();
      logInfo('Search model: loaded in ${sw.elapsedMilliseconds} ms (${_countersText(before, after)})');
      // Let go while it loaded (Cache went to the back, or memory ran short): the release came first and wins.
      if (!_warmWanted) embedder.release();
    } catch (e) {
      logError('Search model: warm load', error: e);
      embedder.release();
    }
  }

  /// The app's lifecycle: hidden, paused or detached lets the model go. Back in front (resumed) loads nothing: Ask or a
  /// search box opened again does ([aboutToSearch]), and a search before that loads it on use. Inactive (a dialog, the
  /// notification shade) changes nothing.
  void onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _release('background');
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Android's onTrimMemory at a level the app acts on ([releaseModelOn]): the model goes; the next search loads it again.
  void onTrim(int level) => _release('trim level $level');

  /// iOS's memory warning: the model goes; the next search loads it again.
  void onMemoryWarning() => _release('memory warning');

  void _release(String why) {
    _warmWanted = false;
    if (embedder.release()) logInfo('Search model: released ($why)');
  }

  static String _countersText(Map<String, int> a, Map<String, int> b) {
    String mb(Map<String, int> m, String k) => m[k] == null ? '?' : '${m[k]! ~/ 1024}';
    if (a.isEmpty && b.isEmpty) return 'memory unknown';
    return 'RSS ${mb(a, 'VmRSS_kb')}/${mb(b, 'VmRSS_kb')}, anon ${mb(a, 'RssAnon_kb')}/${mb(b, 'RssAnon_kb')}, '
        'file ${mb(a, 'RssFile_kb')}/${mb(b, 'RssFile_kb')} MB (before/after)';
  }

  @override
  String get defaultModel => spec.fileName;

  static bool _plainName(String model) => model.isNotEmpty && !model.contains('/') && !model.contains('\\') && model != '..';

  @override
  bool has(String model) {
    // The browser has only the server's search model.
    if (remote) return model == spec.fileName && (_server?.ready ?? false);
    if (model == spec.fileName) return app.searchModel != null;
    final dir = app.modelsDir;
    if (dir == null || !_plainName(model)) return false;
    return File('${dir.path}${Platform.pathSeparator}$model').existsSync();
  }

  @override
  Future<QueryVector?> vectorFor(String model, String text) async {
    final SearchEmbedder e;
    if (remote && model != spec.fileName) return null;
    if (model == spec.fileName) {
      e = embedder;
    } else {
      if (!_plainName(model)) return null;
      e = _others.putIfAbsent(model, () => SearchEmbedder(modelsDir: _modelsDir, fileName: model, make: _make));
    }
    final v = await e.embed(text);
    return v == null ? null : QueryVector(v.$1, v.$2);
  }

  @override
  void dispose() {
    _disposed = true;
    app.removeListener(notifyListeners);
    downloads?.removeListener(notifyListeners);
    embedder.dispose();
    for (final e in _others.values) {
      e.dispose();
    }
    super.dispose();
  }
}

/// This process's memory counters from /proc/self/status (Android and Linux); empty elsewhere.
Map<String, int> _processCounters() {
  try {
    if (!(Platform.isAndroid || Platform.isLinux)) return const {};
    return procMemoryCounters(File('/proc/self/status').readAsStringSync());
  } catch (_) {
    return const {};
  }
}

/// The server's embedder over package:http: same origin, so the page's session cookie goes along (the web build only).
Future<({int status, String body})> _serverHttp(String method, String path, String? body) async {
  final uri = Uri.parse(path);
  final r = method == 'GET' ? await http.get(uri) : await http.post(uri, headers: const {'Content-Type': 'application/json'}, body: body);
  return (status: r.statusCode, body: utf8.decode(r.bodyBytes));
}
