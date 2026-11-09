import 'dart:async';
import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../settings/data_policy.dart';
import '../settings/space.dart';
import 'caption_search.dart';
import 'format.dart';
import 'token_store.dart';
import '../platform.dart' as plat;
import 'video_prefs.dart';

/// What a person is told when a video call fails.
String videoErrorText(Object e) {
  if (e is CacheSearchException) {
    switch (e.code) {
      case 'fetch_failed':
        return "Can't reach the video site. Check the connection and try again.";
      case 'quota':
        return 'The video site asked us to slow down. Try again in a minute.';
      case 'auth_failed':
        return 'The video site needs you to sign in again.';
      case 'otp_required':
        return 'This account needs its two-factor code.';
      case 'not_found':
        return e.message.contains('add it first') ? 'That video site is not in the list.' : 'Not found on the video site.';
      case 'unsupported':
        return e.message;
      case 'no_space':
        return 'Not enough free space on this device.';
      case 'bad_response':
        return "That address doesn't look like a PeerTube site.";
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

/// One heading of the saved videos (a channel; null when there is only one) and its videos, newest first.
class SavedGroup {
  const SavedGroup(this.heading, this.videos);

  final String? heading;
  final List<DownloadedVideo> videos;
}

/// "Spanish captions did not save." (or "English and Spanish captions did not save.") for a saved video missing some.
String missingCaptionsLine(DownloadedVideo d) {
  final names = [for (final c in d.missingCaptions) c.label.isEmpty ? c.language : c.label];
  if (names.isEmpty) return '';
  final list = names.length == 1 ? names.first : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '$list captions did not save.';
}

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

  /// Pause was tapped and the download is still stopping.
  bool pausing = false;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
  bool get isActive => phase == DownloadPhase.running;
  String get key => '$instance/$uuid';
}

/// The video connector as the app uses it: instances, logins (tokens in secure storage), browse calls with the
/// token and one automatic refresh, downloads with progress, the saved videos, and citation links.
class VideoState extends ChangeNotifier {
  VideoState({this.dirOverride, this.nativeFactory, TokenStore? tokens, this.policy, VideoPrefs? prefs, this.captionSearch = const CaptionSearchMissing(), this.spaceOf, this.indexesDir})
      : tokens = tokens ?? const SecureTokenStore(),
        // ignore: prefer_initializing_formals
        _prefs = prefs;

  /// Where each video was left and the captions choice, on this device only (beside the app's other files, never in the shared
  /// videos folder). Tests give one in memory.
  VideoPrefs get prefs => _prefs ??= VideoPrefs();
  VideoPrefs? _prefs;

  /// Search saved videos by caption text (the core's captions index; [CaptionSearchMissing] until it is in the core).
  CaptionSearch captionSearch;

  /// The storage the videos go to (tests set it); null: the videos folder's own.
  final Space Function()? spaceOf;

  /// The storage a download would use, or null when it cannot be read.
  Space? get space {
    try {
      if (spaceOf != null) return spaceOf!();
      final d = dir;
      return d == null ? null : Space.of(d.path);
    } catch (_) {
      return null;
    }
  }

  /// The device's indexes folder (the core's indexes_dir): a saved video's captions are indexed there (captions_index).
  final Future<Directory?> Function()? indexesDir;

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
    if (plat.isWeb) {
      // Videos are saved into a folder on the phone; there is none in a browser.
      unavailable = 'Videos are not available on this device';
      notifyListeners();
      return;
    }
    final Directory dir;
    if (dirOverride != null) {
      dir = dirOverride!;
    } else {
      final base = (plat.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
      dir = Directory('${base.path}/videos');
    }
    this.dir = dir;
    await dir.create(recursive: true);
    if (_prefs == null && dirOverride == null) {
      try {
        _prefs = VideoPrefs(file: File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}video-prefs.json'));
      } catch (_) {}
    }
    await prefs.load();
    try {
      _core = await VideoCore.open(dir.path, indexesDir: (await indexesDir?.call())?.path, native: nativeFactory ?? _defaultNative);
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

  /// How the site lets people sign in (its public config); the user name and password form alone when it cannot be read.
  Future<VideoAuthMethods> authMethods(String instance) async {
    try {
      return await core.authMethods(instance);
    } catch (_) {
      return const VideoAuthMethods(password: true, external: [], returnPrefix: '');
    }
  }

  /// Finishes a sign-in with the site's external auth plugin: trades the one-time token its /login page got for the usual
  /// tokens, kept in secure storage like a password login (the refresh token works the same).
  Future<void> loginExternal(String instance, String username, String externalAuthToken) async {
    final t = await core.loginExternal(instance, username, externalAuthToken);
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

  /// Pauses a running download: it stops and keeps what it has (its row reads Paused); [retry] continues it.
  Future<void> pause(DownloadTask task) async {
    task.pausing = true;
    notifyListeners();
    try {
      await cancel(task);
    } finally {
      task.pausing = false;
      notifyListeners();
    }
  }

  /// Removes a download and what it saved: a running one stops first; the partial file goes with it.
  Future<void> remove(DownloadTask task) async {
    if (task.isActive) await cancel(task);
    try {
      await core.delete(task.instance, task.uuid);
    } catch (_) {}
    tasks.remove(task);
    notifyListeners();
  }

  /// Removes a finished or failed task from the list.
  void dismiss(DownloadTask task) {
    tasks.remove(task);
    notifyListeners();
  }

  Future<void> deleteSaved(DownloadedVideo d) async {
    await core.delete(d.instance, d.uuid);
    tasks.removeWhere((t) => t.instance == d.instance && t.uuid == d.uuid && !t.isActive);
    prefs.clearPosition(VideoPrefs.keyOf(instance: d.instance, uuid: d.uuid));
    await refresh();
  }

  /// The saved videos whose captions are being fetched again.
  final Set<String> fetchingCaptions = {};

  /// Fetches again only the captions [d] is missing (the video file stays); null when that worked, else what to tell the person.
  Future<String?> fetchMissingCaptions(DownloadedVideo d) async {
    final key = '${d.instance}/${d.uuid}';
    fetchingCaptions.add(key);
    notifyListeners();
    try {
      final token = await tokens.read(_k(d.instance, 'access'));
      final after = await core.fetchMissingCaptions(d.instance, d.uuid, token: token);
      await refresh();
      return after.missingCaptions.isEmpty ? null : "${missingCaptionsLine(after)} Check the connection and try again.";
    } catch (e) {
      return videoErrorText(e);
    } finally {
      fetchingCaptions.remove(key);
      if (!_disposed) notifyListeners();
    }
  }

  /// The saved videos in groups for the list: by channel when they come from two or more channels (each group's newest first,
  /// the group with the most recently saved video first); one group with no heading otherwise.
  List<SavedGroup> savedGroups([List<DownloadedVideo>? list]) {
    final all = list ?? saved;
    String channelOf(DownloadedVideo d) => d.channelName.isNotEmpty ? d.channelName : (instanceById(d.instance)?.name ?? d.instance);
    String at(DownloadedVideo d) => d.downloadedAt ?? '';
    final sorted = [...all]..sort((a, b) => at(b).compareTo(at(a)));
    final groups = <String, List<DownloadedVideo>>{};
    for (final d in sorted) {
      groups.putIfAbsent(channelOf(d), () => []).add(d);
    }
    if (groups.length < 2) return [if (sorted.isNotEmpty) SavedGroup(null, sorted)];
    return [for (final e in groups.entries) SavedGroup(e.key, e.value)];
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
