import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../settings/data_policy.dart';
import 'format.dart';
import 'token_store.dart';

/// What a person is told when a video call fails.
String videoErrorText(Object e) {
  if (e is CacheSearchException) {
    switch (e.code) {
      case 'fetch_failed':
        return "Can't reach the instance. Check the connection and try again.";
      case 'quota':
        return 'The instance asked us to slow down. Try again in a minute.';
      case 'auth_failed':
        return 'The instance needs you to log in again.';
      case 'otp_required':
        return 'This account needs its two-factor code.';
      case 'not_found':
        return e.message.contains('add it first') ? 'That instance is not in the list.' : 'Not found on the instance.';
      case 'unsupported':
        return e.message;
      case 'no_space':
        return 'Not enough free space on this phone.';
      case 'bad_response':
        return "That address doesn't look like a PeerTube instance.";
      case 'bad_json':
        return e.message;
      case 'damaged':
        return 'The file did not arrive intact. Try again.';
    }
    return e.message.isEmpty ? e.code : e.message;
  }
  return e.toString();
}

enum DownloadPhase { running, done, failed, cancelled }

/// One download the app started. The partial file stays on disk after a cancel or a failure, so [VideoState.retry]
/// continues where it stopped.
class DownloadTask {
  DownloadTask({required this.instance, required this.uuid, required this.title, required this.choice, required this.label, this.expectedSize});

  final String instance;
  final String uuid;
  final String title;
  final String choice;

  /// "480p", "Audio only".
  final String label;
  final int? expectedSize;
  DownloadPhase phase = DownloadPhase.running;
  int done = 0;
  int total = 0;
  String? error;
  VideoJob? job;

  /// Stopped before it began because the phone is on mobile data and downloads on mobile data are off.
  bool blockedByMobile = false;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
  bool get isActive => phase == DownloadPhase.running;
  String get key => '$instance/$uuid';
}

/// The video connector as the app uses it: instances, logins (tokens in secure storage), browse calls with the
/// token and one automatic refresh, downloads with progress, the saved videos, and citation links.
class VideoState extends ChangeNotifier {
  VideoState({this.dirOverride, this.nativeFactory, TokenStore? tokens, this.policy}) : tokens = tokens ?? const SecureTokenStore();

  /// Whether a download may start on the current connection (mobile data switches). Null: always.
  final DataPolicy? policy;

  /// The folder the saved videos are in, once started.
  Directory? dir;

  /// Test hooks.
  final Directory? dirOverride;
  final CsNativeFactory? nativeFactory;
  final TokenStore tokens;

  VideoCore? _core;
  bool get ready => _core != null;

  /// Why videos cannot be used on this device, or null.
  String? unavailable;
  List<VideoInstance> instances = [];
  List<DownloadedVideo> saved = [];
  final List<DownloadTask> tasks = [];
  final Map<String, String> _users = {};
  Timer? _poll;
  bool _disposed = false;

  VideoCore get core => _core ?? (throw const CacheSearchException('internal', 'Videos are not available on this device'));

  static CsNative _defaultNative() => FfiCsNative.open();

  Future<void> init() async {
    final Directory dir;
    if (dirOverride != null) {
      dir = dirOverride!;
    } else {
      final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
      dir = Directory('${base.path}/videos');
    }
    this.dir = dir;
    await dir.create(recursive: true);
    try {
      _core = await VideoCore.open(dir.path, native: nativeFactory ?? _defaultNative);
    } catch (e) {
      unavailable = e is CacheSearchException ? e.message : 'Videos are not available on this device';
      notifyListeners();
      return;
    }
    await refresh();
  }

  /// Reloads the instance list and the saved videos from the core.
  Future<void> refresh() async {
    try {
      instances = await core.instances();
      saved = await core.downloads();
      for (final i in instances) {
        final u = await tokens.read(_k(i.id, 'user'));
        if (u != null) _users[i.id] = u;
      }
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  static String _k(String instance, String what) => 'video.$instance.$what';

  /// The signed-in user of an instance, or null.
  String? userOf(String instance) => _users[instance];

  VideoInstance? instanceById(String id) {
    for (final i in instances) {
      if (i.id == id) return i;
    }
    return null;
  }

  int get savedBytes => saved.fold(0, (a, d) => a + d.size);

  // ---- instances and login

  Future<VideoInstance> addInstance(String url) async {
    final i = await core.addInstance(url);
    await refresh();
    return i;
  }

  Future<void> removeInstance(String id, {bool deleteDownloads = false}) async {
    await core.removeInstance(id, deleteDownloads: deleteDownloads);
    await _forget(id);
    _users.remove(id);
    await refresh();
  }

  Future<void> _forget(String id) async {
    for (final w in ['access', 'refresh', 'user']) {
      await tokens.delete(_k(id, w));
    }
  }

  Future<void> login(String instance, String username, String password, {String? otp}) async {
    final t = await core.login(instance, username, password, otp: otp);
    await _store(instance, t);
    await tokens.write(_k(instance, 'user'), username);
    _users[instance] = username;
    notifyListeners();
  }

  Future<void> logout(String instance) async {
    await _forget(instance);
    _users.remove(instance);
    notifyListeners();
  }

  Future<void> _store(String instance, VideoTokens t) async {
    await tokens.write(_k(instance, 'access'), t.accessToken);
    if (t.refreshToken != null) await tokens.write(_k(instance, 'refresh'), t.refreshToken!);
  }

  /// Runs [call] with the instance's access token (null when signed out). If the instance refuses the token, the
  /// refresh token is traded for a new one and the call is repeated once; if that fails too the login is dropped.
  Future<T> withToken<T>(String instance, Future<T> Function(String? token) call) async {
    final access = await tokens.read(_k(instance, 'access'));
    try {
      return await call(access);
    } on CacheSearchException catch (e) {
      final refresh = await tokens.read(_k(instance, 'refresh'));
      if (e.code != 'auth_failed' || access == null || refresh == null) rethrow;
      try {
        final t = await core.refresh(instance, refresh);
        await _store(instance, t);
        return await call(t.accessToken);
      } on CacheSearchException {
        await logout(instance);
        rethrow;
      }
    }
  }

  // ---- browse

  Future<ChannelPage> channels(String instance, {String? search, int start = 0}) =>
      withToken(instance, (t) => core.channels(instance, search: search, start: start, token: t));

  Future<VideoPage> list(String instance, {String? channel, int start = 0}) =>
      withToken(instance, (t) => core.list(instance, channel: channel, start: start, token: t));

  Future<VideoPage> search(String instance, String query, {int start = 0}) =>
      withToken(instance, (t) => core.search(instance, query, start: start, token: t));

  Future<VideoDetails> details(String instance, String uuid) => withToken(instance, (t) => core.get(instance, uuid, token: t));

  // ---- downloads

  DownloadTask? taskFor(String instance, String uuid) {
    for (final t in tasks.reversed) {
      if (t.instance == instance && t.uuid == uuid) return t;
    }
    return null;
  }

  DownloadedVideo? savedFor(String instance, String uuid) {
    for (final d in saved) {
      if (d.instance == instance && d.uuid == uuid) return d;
    }
    return null;
  }

  /// Starts downloading [option] of [d]. The sizes shown to the user come from the same list.
  Future<DownloadTask> download(VideoDetails d, VideoOption option, {bool anyway = false}) async {
    tasks.removeWhere((t) => t.instance == d.instance && t.uuid == d.uuid && !t.isActive);
    final task = DownloadTask(instance: d.instance, uuid: d.uuid, title: d.title, choice: option.key, label: option.label, expectedSize: option.size);
    tasks.add(task);
    await _start(task, anyway: anyway);
    return task;
  }

  /// Continues a cancelled or failed download from the partial file.
  Future<void> retry(DownloadTask task, {bool anyway = false}) async {
    task
      ..phase = DownloadPhase.running
      ..error = null;
    await _start(task, anyway: anyway);
  }

  Future<void> _start(DownloadTask task, {bool anyway = false}) async {
    task.blockedByMobile = false;
    notifyListeners();
    try {
      await policy?.checkDownload(anyway: anyway);
    } on MobileDataBlocked catch (e) {
      task
        ..phase = DownloadPhase.failed
        ..blockedByMobile = true
        ..error = e.message;
      notifyListeners();
      return;
    }
    try {
      final token = await tokens.read(_k(task.instance, 'access'));
      task.job = await core.startDownload(task.instance, task.uuid, choice: task.choice, token: token);
      _ensurePolling();
    } catch (e) {
      task
        ..phase = DownloadPhase.failed
        ..error = videoErrorText(e);
    }
    notifyListeners();
  }

  void _ensurePolling() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 500), (_) => pollOnce());
  }

  /// Reads the progress of every running download once.
  Future<void> pollOnce() async {
    var anyRunning = false;
    var finished = false;
    for (final t in tasks.where((t) => t.isActive && t.job != null)) {
      try {
        final p = await t.job!.progress();
        t
          ..done = p.done
          ..total = p.total;
        switch (p.state) {
          case JobState.running:
            anyRunning = true;
          case JobState.done:
            t.phase = DownloadPhase.done;
            finished = true;
          case JobState.cancelled:
            t.phase = DownloadPhase.cancelled;
          case JobState.failed:
            t.phase = DownloadPhase.failed;
            t.error = videoErrorText(CacheSearchException(p.errorCode ?? 'internal', p.errorMessage ?? ''));
        }
        if (t.phase != DownloadPhase.running) {
          await t.job!.free();
          t.job = null;
        }
      } catch (e) {
        t
          ..phase = DownloadPhase.failed
          ..error = videoErrorText(e);
      }
    }
    if (!anyRunning) {
      _poll?.cancel();
      _poll = null;
    }
    if (finished) await refresh();
    if (!_disposed) notifyListeners();
  }

  /// Stops a running download; the partial file is kept so [retry] continues it.
  Future<void> cancel(DownloadTask task) async {
    await task.job?.cancel();
    await pollOnce();
  }

  /// Removes a finished or failed task from the list.
  void dismiss(DownloadTask task) {
    tasks.remove(task);
    notifyListeners();
  }

  Future<void> deleteSaved(DownloadedVideo d) async {
    await core.delete(d.instance, d.uuid);
    tasks.removeWhere((t) => t.instance == d.instance && t.uuid == d.uuid && !t.isActive);
    await refresh();
  }

  // ---- citations

  /// Where to open [video] (a link, uuid or short uuid) at [offsetS]: the saved file when it is downloaded, else a
  /// stream. [instance] only matters for a bare id.
  Future<VideoTarget> resolve(String video, {String? instance, double? offsetS}) async {
    final inst = instance ?? _instanceOfLink(video);
    final token = inst == null ? null : await tokens.read(_k(inst, 'access'));
    return core.resolve(video, instance: instance, offsetS: offsetS, token: token);
  }

  /// The instance id (host, with `_port`) of a video link, or null for a bare id.
  static String? _instanceOfLink(String video) {
    final u = Uri.tryParse(video.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return null;
    return u.hasPort ? '${u.host.toLowerCase()}_${u.port}' : u.host.toLowerCase();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _core?.close();
    super.dispose();
  }
}

/// "480p · 54 MB" for a download choice.
String optionLine(VideoOption o) => o.size == null ? o.label : '${o.label} · ${formatBytes(o.size!)}';
