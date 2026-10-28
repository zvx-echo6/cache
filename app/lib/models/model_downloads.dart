import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../browse/zim_download.dart';
import '../files.dart';
import '../settings/data_policy.dart';
import 'hf_hub.dart';

/// The phone's total memory in bytes, when it can be read (Android and Linux, from /proc/meminfo).
Future<int?> totalMemoryBytes() async {
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
/// model list.
class ModelDownloads extends ChangeNotifier {
  ModelDownloads({required this.app, this.policy, HfHub? hub, ZimDownloader? downloader})
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

  CancelToken? _cancel;

  bool get busy => current != null;

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
  bool isInstalled(HfFile f) => app.models.any((m) => m.fileName == f.fileName && m.size == f.size);

  Future<void> start(HfFile f, {bool anyway = false}) async {
    if (busy || app.modelsDir == null) return;
    error = null;
    blocked = null;
    finished = null;
    try {
      await policy?.checkDownload(anyway: anyway);
    } on MobileDataBlocked catch (b) {
      blocked = b;
      notifyListeners();
      return;
    }
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
      for (final m in app.models) {
        if (m.path == dest.path) finished = m;
      }
    } on DownloadException catch (e) {
      if (e.code != 'cancelled') {
        error = e.code == 'failed' && e.message.contains('401')
            ? 'This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".'
            : e.message;
      }
    } catch (e) {
      error = 'The download stopped: $e';
    } finally {
      current = null;
      verifying = false;
      _cancel = null;
      notifyListeners();
    }
  }

  void cancel() => _cancel?.cancel();

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
