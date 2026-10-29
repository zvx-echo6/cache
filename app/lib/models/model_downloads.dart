import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../browse/zim_download.dart';
import '../files.dart';
import '../settings/data_policy.dart';
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
  fits('Fits this phone'),
  tight('May be tight on this phone'),
  tooBig('Too big for this phone'),
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
      _downloader = downloader ?? ZimDownloader();

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

  /// Set when the mobile-data switch stopped the download; the screen offers "Download anyway".
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

  /// Downloads [f]. While another download runs, only the search model is taken, into the queue; anything else is ignored.
  /// A chat model brings the search model after it when that is missing; it starts once the chat model has finished.
  Future<void> start(HfFile f, {bool anyway = false}) async {
    if (app.modelsDir == null) return;
    final search = isSearchModel(f);
    if (busy) {
      if (search && !searchModelQueued) {
        queue.add(f);
        notifyListeners();
      }
      return;
    }
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
      // The search model may start on its own, with no screen to ask "Download anyway": the reason is shown as its stop.
      if (search) {
        searchModelError = b.message;
      } else {
        blocked = b;
      }
      notifyListeners();
      return;
    }
    final sm = searchModel;
    if (!search && sm != null && app.searchModel == null && !searchModelQueued) queue.add(sm);
    final ok = await _run(f, search: search);
    // A stopped or failed download takes what waits after it along; the search model is offered again with the next chat
    // model, and from the line where meaning search needs it.
    final next = ok && queue.isNotEmpty ? queue.removeAt(0) : null;
    if (!ok) queue.clear();
    notifyListeners();
    if (next != null) unawaited(start(next, anyway: anyway));
  }

  /// Runs one download; true when the file is in place.
  Future<bool> _run(HfFile f, {required bool search}) async {
    var ok = false;
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
      if (e.code != 'cancelled') {
        final why = e.code == 'failed' && e.message.contains('401')
            ? 'This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".'
            : e.message;
        if (search) {
          searchModelError = why;
        } else {
          error = why;
        }
      }
    } catch (e) {
      if (search) {
        searchModelError = '$e';
      } else {
        error = 'The download stopped: $e';
      }
    } finally {
      current = null;
      verifying = false;
      _cancel = null;
      notifyListeners();
    }
    return ok;
  }

  /// Stops the download that runs; what waits after it is dropped too.
  void cancel() {
    queue.clear();
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
