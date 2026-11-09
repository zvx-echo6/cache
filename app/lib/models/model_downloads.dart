import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../browse/zim_download.dart';
import '../downloads/download_row.dart';
import '../files.dart';
import '../settings/data_policy.dart';
import '../settings/space.dart';
import '../platform/memory.dart' show modelMemoryNeed, readMemory;
import 'device_memory.dart';
import 'hf_hub.dart';
import 'server_models.dart';
import '../platform.dart' as plat;

/// The phone's total memory in bytes, when it can be read: Android and Linux from /proc/meminfo, iPhone (and Mac) from the
/// system's hw.memsize.
Future<int?> totalMemoryBytes() async {
  // A browser: the memory of the server that runs the model.
  if (plat.isWeb) return (await readMemory())?.total;
  if (plat.isIOS || plat.isMacOS) return sysctlMemsize();
  if (!(plat.isAndroid || plat.isLinux)) return null;
  try {
    for (final line in await File('/proc/meminfo').readAsLines()) {
      final m = RegExp(r'^MemTotal:\s+(\d+)\s+kB').firstMatch(line);
      if (m != null) return int.parse(m.group(1)!) * 1024;
    }
  } catch (_) {}
  return null;
}

/// How well a model file of a given size suits a phone with [memory] bytes. The model's file is about what it needs in
/// memory, plus room for its working memory (context) and the rest of the app and phone.
enum ModelFit {
  fits('Fits device RAM'),
  tight('May be tight on RAM'),
  tooBig('Too large for device RAM'),
  unknown('');

  const ModelFit(this.label);
  final String label;

  /// [room]: the memory free now for a model (see [MemoryReading.room], with the model Cache holds counted as free): a model
  /// that fits the phone but not what is free now is tight.
  static ModelFit of(int fileBytes, int? memory, {int? room}) {
    if (memory == null || memory <= 0) return ModelFit.unknown;
    final need = fileBytes + (768 << 20);
    if (need <= memory * 0.55) return room != null && modelMemoryNeed(fileBytes) > room ? ModelFit.tight : ModelFit.fits;
    if (need <= memory * 0.75) return ModelFit.tight;
    return ModelFit.tooBig;
  }
}

/// One model download at a time into the models folder: resumable (a ".part" file in models/.partial that continues where it stopped),
/// checked against Hugging Face's SHA-256, asking the mobile-data switch first. When it finishes the file appears in the
/// model list. When a chat model is downloaded and the search model is missing, the search model is queued to follow it.
/// "Downloading Gemma 4 E2B · 40%" while a chat model downloads (the Settings lines when no model is chosen yet); null when none
/// does.
String? modelDownloadLine() {
  final d = ModelDownloads.shared;
  final f = d?.current;
  if (d == null || f == null || d.isSearchModel(f)) return null;
  final pct = d.total > 0 ? ' · ${(100 * d.done / d.total).floor()}%' : '';
  return 'Downloading ${d.nameOf(f)}$pct';
}

class ModelDownloads extends ChangeNotifier {
  ModelDownloads({required this.app, this.policy, HfHub? hub, ZimDownloader? downloader, this.searchModel, ServerModels? server})
    : hub = hub ?? HfHub(),
      _server = server ?? (plat.isWeb ? ServerModels() : null),
      _downloader = downloader ?? ZimDownloader(freeSpace: usableBytesOnDisk) {
    // In a browser the server runs the downloads: see what it is doing now (a tab opened while one runs shows it).
    if (_server != null) unawaited(refreshRemote());
    // A download waiting for Wi-Fi starts by itself once the connection allows it.
    _net = policy?.probe.changes.listen((_) => _startWaiting());
    policy?.settings.addListener(_startWaiting);
  }

  StreamSubscription<ConnectionKind>? _net;

  /// A chat model the person chose to download once on Wi-Fi ("Wait for Wi-Fi").
  HfFile? waiting;

  Future<void> _startWaiting() async {
    final w = waiting;
    if (w == null || busy || policy == null || await policy!.blocksDownload()) return;
    waiting = null;
    await start(w);
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _net?.cancel();
    policy?.settings.removeListener(_startWaiting);
    super.dispose();
  }

  /// The app's downloads (set up at start); null in tests that don't need it.
  static ModelDownloads? shared;

  final AppState app;
  final DataPolicy? policy;
  final HfHub hub;
  final ZimDownloader _downloader;

  HfFile? current;
  int done = 0;
  int total = 0;
  bool verifying = false;

  /// Why the last download stopped, in words, or null.
  String? error;

  /// Set while the download waits for Wi-Fi (mobile data downloads are off); it starts by itself on Wi-Fi.
  MobileDataBlocked? blocked;

  /// The last file that finished, so the screen can offer "Use this model".
  ModelEntry? finished;

  /// The search model's file, which follows the first chat model; null leaves it out (tests of chat downloads alone).
  final HfFile? searchModel;

  /// Downloads waiting for the one running (today only the search model).
  final List<HfFile> queue = [];

  /// Why the search model's last download stopped, or null. Kept apart from [error], which is about the chat model.
  String? searchModelError;

  CancelToken? _cancel;

  /// Files whose download was tapped and has not begun yet (the mobile-data check, the folder): their rows say "Starting…" at once.
  final Set<String> _starting = {};

  /// The file being paused (its row says "Pausing…" until the download has stopped).
  String? _pausing;

  /// The file to throw away once its download has stopped (Remove while it runs).
  String? _discardAfter;

  /// Files paused by the person: the partly downloaded file stays and Resume continues it.
  final Set<String> paused = {};

  /// Files whose download stopped on its own, with why (Resume continues it).
  final Map<String, String> failed = {};

  /// The running download has received bytes (until then its row says "Starting…").
  bool _gotBytes = false;

  bool get busy => current != null;

  bool isSearchModel(HfFile f) => searchModel != null && f.fileName == searchModel!.fileName;

  /// The search model is downloading now or waiting its turn.
  bool get searchModelQueued => queue.any(isSearchModel) || (current != null && isSearchModel(current!));

  /// The name a download is shown under.
  String labelOf(HfFile f) => isSearchModel(f) ? 'Search model' : f.fileName;

  /// Where an unfinished download of [f] waits: a hidden folder in the models folder, so the sync leaves it alone and
  /// finishing is a rename on the same file system.
  File _partFor(HfFile f) {
    final sep = Platform.pathSeparator;
    return File('${app.modelsDir!.path}$sep.partial$sep${f.fileName}.part');
  }

  /// Where earlier versions kept it: next to the models, where the sync sent it to the other devices.
  File _oldPartFor(HfFile f) => File('${app.modelsDir!.path}${Platform.pathSeparator}${f.fileName}.part');

  /// Moves a partial file of [f] from an earlier version into the hidden folder, so the download continues from it.
  Future<void> _moveOldPart(HfFile f) async {
    try {
      final old = _oldPartFor(f);
      final part = _partFor(f);
      if (!old.existsSync() || part.existsSync()) return;
      await part.parent.create(recursive: true);
      await old.rename(part.path);
    } catch (_) {}
  }

  /// Bytes already downloaded for [f] in an earlier, stopped try.
  int partBytes(HfFile f) {
    if (_server != null) return _remote[f.fileName]?.done ?? 0;
    try {
      for (final p in [_partFor(f), _oldPartFor(f)]) {
        if (p.existsSync()) return p.lengthSync();
      }
    } catch (_) {}
    return 0;
  }

  /// True when the file is already in the models folder.
  bool isInstalled(HfFile f) =>
      (_server != null && isSearchModel(f) && _searchReady) ||
      app.models.any((m) => m.fileName == f.fileName && m.size == f.size) ||
      (app.searchModel?.fileName == f.fileName && app.searchModel?.size == f.size);

  /// Downloads [f], continuing a partly downloaded file. While another download runs, [f] waits its turn in the queue (its row says
  /// "Waiting for (the running one) to finish"). A chat model brings the search model after it when that is missing; it starts once
  /// the chat model has finished.
  Future<void> start(HfFile f, {bool anyway = false}) async {
    if (_server != null) return _startRemote(f, anyway: anyway);
    if (app.modelsDir == null) return;
    final search = isSearchModel(f);
    paused.remove(f.fileName);
    failed.remove(f.fileName);
    if (busy) {
      if (current!.fileName != f.fileName && !queue.any((q) => q.fileName == f.fileName)) {
        queue.add(f);
        notifyListeners();
      }
      return;
    }
    // The row changes on the frame of the tap, before the mobile-data check and the folder.
    _starting.add(f.fileName);
    notifyListeners();
    if (search) {
      searchModelError = null;
    } else {
      error = null;
      blocked = null;
      finished = null;
    }
    try {
      await policy?.checkDownload(anyway: anyway);
    } on MobileDataBlocked catch (b) {
      _starting.remove(f.fileName);
      // The search model may start on its own, with no screen to ask: the reason is shown as its stop.
      if (search) {
        searchModelError = b.message;
      } else {
        blocked = b;
        waiting = f;
      }
      notifyListeners();
      return;
    }
    final sm = searchModel;
    if (!search && sm != null && app.searchModel == null && !searchModelQueued) queue.add(sm);
    final ok = await _run(f, search: search);
    // A paused or failed download holds what waits after it: the queue goes on when it has finished.
    final next = ok && queue.isNotEmpty ? queue.removeAt(0) : null;
    notifyListeners();
    if (next != null) unawaited(start(next, anyway: anyway));
  }

  /// Runs one download; true when the file is in place.
  Future<bool> _run(HfFile f, {required bool search}) async {
    var ok = false;
    _starting.remove(f.fileName);
    _gotBytes = false;
    DlMeter.reset(_meterKey(f));
    current = f;
    await _moveOldPart(f);
    done = partBytes(f);
    total = f.size;
    verifying = false;
    _cancel = CancelToken();
    notifyListeners();
    final part = _partFor(f);
    try {
      await part.parent.create(recursive: true);
      await _downloader.download(
        url: hub.downloadUrl(f),
        part: part,
        expectedSha256: f.sha256,
        cancel: _cancel,
        onProgress: (d, t) {
          done = d;
          total = t;
          _gotBytes = true;
          notifyListeners();
        },
        onVerifying: () {
          verifying = true;
          notifyListeners();
        },
      );
      final dest = File('${app.modelsDir!.path}${Platform.pathSeparator}${f.fileName}');
      await renameOver(part, dest.path);
      await app.refreshModels();
      if (!search) {
        for (final m in app.models) {
          if (m.path == dest.path) finished = m;
        }
      }
      ok = true;
    } on DownloadException catch (e) {
      if (e.code == 'cancelled') {
        if (_pausing == f.fileName) paused.add(f.fileName);
      } else {
        final why = e.code == 'failed' && e.message.contains('401')
            ? 'This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".'
            : e.message;
        failed[f.fileName] = why;
        if (search) {
          searchModelError = why;
        } else {
          error = why;
        }
      }
    } catch (e) {
      failed[f.fileName] = '$e';
      if (search) {
        searchModelError = '$e';
      } else {
        error = 'The download stopped: $e';
      }
    } finally {
      current = null;
      verifying = false;
      _cancel = null;
      if (_pausing == f.fileName) _pausing = null;
      if (_discardAfter == f.fileName) {
        _discardAfter = null;
        discardPart(f);
      }
      notifyListeners();
    }
    return ok;
  }

  String _meterKey(HfFile f) => 'model:${f.fileName}';

  /// Pauses the download of [f]: it stops and keeps what it has; [resume] continues it. What waits after it waits on.
  void pause(HfFile f) {
    if (_server != null) return _pauseRemote(f);
    if (current?.fileName != f.fileName || _pausing != null) return;
    _pausing = f.fileName;
    DlMeter.reset(_meterKey(f));
    notifyListeners();
    _cancel?.cancel();
  }

  /// Continues a paused or stopped download of [f] from the bytes it has.
  Future<void> resume(HfFile f, {bool anyway = false}) => start(f, anyway: anyway);

  /// Removes the download of [f] and what it saved: a running one stops first, a waiting one leaves the queue.
  Future<void> remove(HfFile f) async {
    if (_server != null) return _removeRemote(f);
    queue.removeWhere((q) => q.fileName == f.fileName);
    paused.remove(f.fileName);
    failed.remove(f.fileName);
    if (waiting?.fileName == f.fileName) {
      waiting = null;
      blocked = null;
    }
    if (isSearchModel(f)) searchModelError = null;
    if (current?.fileName == f.fileName) {
      _discardAfter = f.fileName;
      _cancel?.cancel();
      notifyListeners();
      return;
    }
    discardPart(f);
  }

  /// Where the download of [f] stands, as its row shows it.
  DlState stateOf(HfFile f) {
    final name = f.fileName;
    if (_server != null) return _remoteStateOf(f);
    if (current?.fileName == name) {
      if (_pausing == name || _discardAfter == name) return DlState(DlPhase.pausing, done: done, total: total);
      if (verifying) return DlState(DlPhase.verifying, done: done, total: total);
      if (!_gotBytes) return DlState(DlPhase.starting, done: done, total: total);
      return DlState(DlPhase.running, done: done, total: total, speed: DlMeter.speed(_meterKey(f), done));
    }
    if (_starting.contains(name)) return DlState(DlPhase.starting, done: partBytes(f), total: f.size);
    if (queue.any((q) => q.fileName == name)) {
      final c = current;
      return DlState(DlPhase.waiting, done: partBytes(f), total: f.size, waitingFor: c == null ? null : nameOf(c));
    }
    if (waiting?.fileName == name) return DlState(DlPhase.waiting, done: partBytes(f), total: f.size, waitLine: 'Waiting for Wi-Fi');
    if (isInstalled(f)) return DlState(DlPhase.done, total: f.size);
    final why = failed[name];
    if (why != null) {
      final reason = DlReason.of(why);
      final own = why.contains('Hugging Face account') ? 'this model needs a Hugging Face account' : null;
      return DlState(DlPhase.failed, done: partBytes(f), total: f.size, reason: reason, reasonText: own);
    }
    final part = partBytes(f);
    if (paused.contains(name) || part > 0) return DlState(DlPhase.paused, done: part, total: f.size);
    return DlState(DlPhase.idle, total: f.size);
  }

  /// The name a row shows for [f] ("Gemma 4 E4B · Q4_K_M" for a recommended model); the file name when no better name is known.
  String Function(HfFile f) nameOf = (f) => f.fileName.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');

  /// Stops the download that runs; what waits after it is dropped too.
  void cancel() {
    if (_server != null) {
      for (final d in _remote.values.where((d) => d.active)) {
        final f = _fileOf(d.name);
        if (f != null) unawaited(_removeRemote(f));
      }
      waiting = null;
      blocked = null;
      return;
    }
    queue.clear();
    waiting = null;
    blocked = null;
    _cancel?.cancel();
    notifyListeners();
  }

  /// Throws away the partly downloaded file of [f].
  void discardPart(HfFile f) {
    if (_server != null) {
      unawaited(_removeRemote(f));
      return;
    }
    for (final p in [_partFor(f), _oldPartFor(f)]) {
      try {
        if (p.existsSync()) p.deleteSync();
      } catch (_) {}
    }
    notifyListeners();
  }

  // ---- A browser: the server runs the downloads (server/src/models.rs). Nothing below runs on a phone.

  final ServerModels? _server;
  bool _disposed = false;
  Timer? _poll;

  /// What the server last said, by file name.
  Map<String, ServerDownload> _remote = {};
  final Map<String, HfFile> _known = {};
  bool _searchReady = false;

  /// The server has the search model.
  bool get searchModelReady => _searchReady;

  /// The search model is on this device (a browser: on the server).
  bool get hasSearchModel => _server != null ? _searchReady : app.searchModel != null;

  HfFile? _fileOf(String name) {
    final k = _known[name];
    if (k != null) return k;
    final sm = searchModel;
    if (sm != null && sm.fileName == name) return sm;
    final d = _remote[name];
    return d == null ? null : HfFile(repo: '', path: name, size: d.total);
  }

  /// Asks the server how its downloads stand and brings this object to it; keeps asking every second while one is active.
  Future<void> refreshRemote() async {
    final server = _server;
    if (server == null || _disposed) return;
    try {
      final list = await server.downloads();
      final ready = await server.searchModelReady();
      if (_disposed) return;
      await _applyRemote(list, ready);
    } catch (e) {
      // not reachable now: what is shown stays, and the next ask may work
      if (!_disposed && error == null && _remote.values.any((d) => d.active)) notifyListeners();
    }
    _schedule();
  }

  void _schedule() {
    final busy = _starting.isNotEmpty || _remote.values.any((d) => d.active) || _pausing != null || _discardAfter != null;
    if (busy && _poll == null && !_disposed) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(refreshRemote()));
    } else if (!busy) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _applyRemote(List<ServerDownload> list, bool searchReady) async {
    final before = _remote;
    _remote = {for (final d in list) d.name: d};
    _searchReady = searchReady;
    // what has finished since the last look: it was going, and is now done or gone
    final finishedNow = <String>[
      for (final b in before.values)
        if (b.active && (_remote[b.name] == null || _remote[b.name]!.state == 'done')) b.name,
    ];
    if (finishedNow.isNotEmpty) await app.refreshModels();
    for (final name in finishedNow) {
      final f = _fileOf(name);
      if (f != null && !isSearchModel(f)) {
        for (final m in app.models) {
          if (m.fileName == name) finished = m;
        }
      }
    }
    HfFile? now;
    done = 0;
    total = 0;
    verifying = false;
    queue.clear();
    for (final d in list) {
      final f = _fileOf(d.name);
      if (f == null) continue;
      final search = isSearchModel(f);
      switch (d.state) {
        case 'running' || 'verifying':
          now = f;
          done = d.done;
          total = d.total > 0 ? d.total : f.size;
          verifying = d.state == 'verifying';
          _gotBytes = d.done > 0;
        case 'queued':
          queue.add(f);
        case 'paused':
          paused.add(d.name);
        case 'failed':
          final why = d.error ?? 'The download stopped.';
          failed[d.name] = why;
          if (search) {
            searchModelError = why;
          } else {
            error = why;
          }
      }
      if (d.state != 'paused') paused.remove(d.name);
      if (d.state != 'failed' && d.state != 'done') failed.remove(d.name);
    }
    current = now;
    if (_pausing != null && _remote[_pausing!]?.state != 'running' && _remote[_pausing!]?.state != 'verifying') _pausing = null;
    if (_discardAfter != null && _remote[_discardAfter!] == null) _discardAfter = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> _startRemote(HfFile f, {bool anyway = false}) async {
    final server = _server!;
    final name = f.fileName;
    final search = isSearchModel(f);
    paused.remove(name);
    failed.remove(name);
    _known[name] = f;
    // The row changes on the frame of the tap, before the mobile-data check and the server's answer.
    _starting.add(name);
    notifyListeners();
    if (search) {
      searchModelError = null;
    } else {
      error = null;
      blocked = null;
      finished = null;
    }
    try {
      await policy?.checkDownload(anyway: anyway);
    } on MobileDataBlocked catch (b) {
      _starting.remove(name);
      if (search) {
        searchModelError = b.message;
      } else {
        blocked = b;
        waiting = f;
      }
      notifyListeners();
      return;
    }
    try {
      if (search) {
        await server.startSearchModel();
      } else {
        // The first chat model brings the search model: the server starts it when this file is done, with no tab open.
        final sm = searchModel;
        final withSearch = sm != null && !_searchReady && !searchModelQueued;
        await server.add(f, search: withSearch);
      }
    } on ServerModelsException catch (e) {
      failed[name] = e.message;
      if (search) {
        searchModelError = e.message;
      } else {
        error = e.message;
      }
    } finally {
      _starting.remove(name);
    }
    await refreshRemote();
  }

  void _pauseRemote(HfFile f) {
    // The search model's download belongs to the server's embedder, which cannot pause.
    if (isSearchModel(f) || _pausing != null) return;
    final d = _remote[f.fileName];
    if (d == null || !d.active) return;
    _pausing = f.fileName;
    DlMeter.reset(_meterKey(f));
    notifyListeners();
    unawaited(() async {
      try {
        await _server!.pause(f.fileName);
      } catch (_) {
        _pausing = null;
      }
      await refreshRemote();
    }());
  }

  Future<void> _removeRemote(HfFile f) async {
    final name = f.fileName;
    paused.remove(name);
    failed.remove(name);
    if (waiting?.fileName == name) {
      waiting = null;
      blocked = null;
    }
    if (isSearchModel(f)) {
      searchModelError = null;
      notifyListeners();
      return;
    }
    if (_remote[name]?.state == 'running' || _remote[name]?.state == 'verifying') _discardAfter = name;
    notifyListeners();
    try {
      await _server!.remove(name);
    } catch (_) {
      _discardAfter = null;
    }
    await refreshRemote();
  }

  DlState _remoteStateOf(HfFile f) {
    final name = f.fileName;
    final r = _remote[name];
    if (r != null) {
      final size = r.total > 0 ? r.total : f.size;
      switch (r.state) {
        case 'running' || 'verifying':
          if (_pausing == name || _discardAfter == name) return DlState(DlPhase.pausing, done: r.done, total: size);
          if (r.state == 'verifying') return DlState(DlPhase.verifying, done: r.done, total: size);
          if (r.done == 0) return DlState(DlPhase.starting, done: r.done, total: size);
          return DlState(DlPhase.running, done: r.done, total: size, speed: DlMeter.speed(_meterKey(f), r.done));
        case 'queued':
          String? other;
          for (final d in _remote.values) {
            if (d.state == 'running' || d.state == 'verifying') other = nameOf(_fileOf(d.name) ?? f);
          }
          return DlState(DlPhase.waiting, done: r.done, total: size, waitingFor: other);
      }
    }
    if (_starting.contains(name)) return DlState(DlPhase.starting, done: r?.done ?? 0, total: f.size);
    if (waiting?.fileName == name) return DlState(DlPhase.waiting, done: r?.done ?? 0, total: f.size, waitLine: 'Waiting for Wi-Fi');
    if (isInstalled(f)) return DlState(DlPhase.done, total: f.size);
    final why = failed[name];
    if (why != null) {
      final own = why.contains('Hugging Face account') ? 'this model needs a Hugging Face account' : null;
      return DlState(DlPhase.failed, done: r?.done ?? 0, total: f.size, reason: DlReason.of(why), reasonText: own);
    }
    if (r != null && r.state == 'paused') return DlState(DlPhase.paused, done: r.done, total: r.total > 0 ? r.total : f.size);
    return DlState(DlPhase.idle, total: f.size);
  }
}
