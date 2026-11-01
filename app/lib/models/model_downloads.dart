import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../browse/zim_download.dart';
import '../downloads/download_row.dart';
import '../files.dart';
import '../settings/data_policy.dart';
import '../settings/space.dart';
import 'device_memory.dart';
import 'hf_hub.dart';

/// The phone's total memory in bytes, when it can be read: Android and Linux from /proc/meminfo, iPhone (and Mac) from the
/// system's hw.memsize.
Future<int?> totalMemoryBytes() async {
  if (Platform.isIOS || Platform.isMacOS) return sysctlMemsize();
  if (!(Platform.isAndroid || Platform.isLinux)) return null;
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
  fits('Fits this device'),
  tight('May be tight on this device'),
  tooBig('Too big for this device'),
  unknown('');

  const ModelFit(this.label);
  final String label;

  static ModelFit of(int fileBytes, int? memory) {
    if (memory == null || memory <= 0) return ModelFit.unknown;
    final need = fileBytes + (768 << 20);
    if (need <= memory * 0.55) return ModelFit.fits;
    if (need <= memory * 0.75) return ModelFit.tight;
    return ModelFit.tooBig;
  }
}

/// One model download at a time into the models folder: resumable (a ".part" file in models/.partial that continues where it stopped),
/// checked against Hugging Face's SHA-256, asking the mobile-data switch first. When it finishes the file appears in the
/// model list. When a chat model is downloaded and the search model is missing, the search model is queued to follow it.
class ModelDownloads extends ChangeNotifier {
  ModelDownloads({required this.app, this.policy, HfHub? hub, ZimDownloader? downloader, this.searchModel})
    : hub = hub ?? HfHub(),
      _downloader = downloader ?? ZimDownloader(freeSpace: usableBytesOnDisk) {
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
    try {
      for (final p in [_partFor(f), _oldPartFor(f)]) {
        if (p.existsSync()) return p.lengthSync();
      }
    } catch (_) {}
    return 0;
  }

  /// True when the file is already in the models folder.
  bool isInstalled(HfFile f) =>
      app.models.any((m) => m.fileName == f.fileName && m.size == f.size) ||
      (app.searchModel?.fileName == f.fileName && app.searchModel?.size == f.size);

  /// Downloads [f], continuing a partly downloaded file. While another download runs, [f] waits its turn in the queue (its row says
  /// "Waiting for (the running one) to finish"). A chat model brings the search model after it when that is missing; it starts once
  /// the chat model has finished.
  Future<void> start(HfFile f, {bool anyway = false}) async {
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
  String Function(HfFile f) nameOf = (f) => f.fileName;

  /// Stops the download that runs; what waits after it is dropped too.
  void cancel() {
    queue.clear();
    waiting = null;
    blocked = null;
    _cancel?.cancel();
    notifyListeners();
  }

  /// Throws away the partly downloaded file of [f].
  void discardPart(HfFile f) {
    for (final p in [_partFor(f), _oldPartFor(f)]) {
      try {
        if (p.existsSync()) p.deleteSync();
      } catch (_) {}
    }
    notifyListeners();
  }
}
