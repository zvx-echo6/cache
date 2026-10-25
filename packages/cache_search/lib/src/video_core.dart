import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'engine.dart' show CoreJob;
import 'errors.dart';
import 'models.dart';
import 'native.dart';
import 'search_core.dart' show CsNativeFactory;
import 'video_models.dart';

CsNative _openNative() => FfiCsNative.open();

/// The video connector for the UI. It has its own core handle in its own background isolate, so a slow
/// instance never holds up search. Every call is JSON in and out (cache_search.h, "videos"); access tokens
/// are passed in by the caller on each call and kept nowhere here.
class VideoCore {
  VideoCore._(this._isolate, this._toWorker, this._fromWorker);

  /// Starts the worker and opens a handle whose `video` folder is [dir] (instances.json and downloads live
  /// there). Throws a [CacheSearchException] if the native library is missing or cs_open fails.
  static Future<VideoCore> open(String dir, {CsNativeFactory native = _openNative}) async {
    final rp = ReceivePort();
    final errors = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, [rp.sendPort, native], debugName: 'cache_video', onError: errors.sendPort);
    final events = StreamIterator<dynamic>(rp);
    await events.moveNext();
    final core = VideoCore._(isolate, events.current as SendPort, rp);
    errors.listen((dynamic e) => core._failAll(CacheSearchException('internal', 'The video core crashed: ${(e as List).first}')));
    core._errors = errors;
    unawaited(() async {
      while (await events.moveNext()) {
        core._onReply(events.current as Map);
      }
    }());
    try {
      await core._call('open', {'dir': dir});
    } catch (_) {
      await core.close();
      rethrow;
    }
    core.dir = dir;
    return core;
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  ReceivePort? _errors;
  int _nextId = 1;
  bool _closed = false;
  final Map<int, Completer<dynamic>> _pending = {};

  /// The video folder this core was opened on (also what a download job is given).
  late final String dir;

  void _onReply(Map m) {
    final c = _pending.remove(m['id'] as int);
    if (c == null) return;
    final err = m['error'];
    if (err is List) {
      c.completeError(CacheSearchException(err[0] as String, err[1] as String));
    } else {
      c.complete(m['result']);
    }
  }

  void _failAll(CacheSearchException e) {
    for (final c in _pending.values) {
      c.completeError(e);
    }
    _pending.clear();
  }

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) {
    if (_closed) return Future.error(const CacheSearchException('internal', 'The video core is closed'));
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _toWorker.send({'id': id, 'op': op, 'args': args});
    return c.future;
  }

  Future<Map<String, dynamic>> _video(String op, [Map<String, dynamic>? request]) async =>
      (jsonDecode((await _call('video', {'op': op, 'request': request == null ? '' : jsonEncode(request)})) as String) as Map).cast<String, dynamic>();

  static Map<String, dynamic> _req(Map<String, dynamic> m) => {for (final e in m.entries) if (e.value != null) e.key: e.value};

  Future<List<VideoInstance>> instances() async => [
        for (final i in (await _video('instances'))['instances'] as List) VideoInstance.fromJson((i as Map).cast<String, dynamic>()),
      ];

  Future<VideoInstance> addInstance(String url) async => VideoInstance.fromJson(await _video('instance_add', {'url': url}));

  Future<void> removeInstance(String instance, {bool deleteDownloads = false}) =>
      _video('instance_remove', {'instance': instance, 'delete_downloads': deleteDownloads});

  /// PeerTube's OAuth password login. Returns the tokens for the caller to store.
  Future<VideoTokens> login(String instance, String username, String password, {String? otp}) async =>
      VideoTokens.fromJson(await _video('login', _req({'instance': instance, 'username': username, 'password': password, 'otp': otp})));

  Future<VideoTokens> refresh(String instance, String refreshToken) async =>
      VideoTokens.fromJson(await _video('refresh', {'instance': instance, 'refresh_token': refreshToken}));

  /// The signed-in user's name.
  Future<String> me(String instance, String token) async => ((await _video('me', {'instance': instance, 'token': token}))['username'] ?? '') as String;

  Future<ChannelPage> channels(String instance, {String? search, int start = 0, int count = 20, String? token}) async =>
      ChannelPage.fromJson(await _video('channels', _req({'instance': instance, 'search': search, 'start': start, 'count': count, 'token': token})));

  Future<VideoPage> list(String instance, {String? channel, int start = 0, int count = 20, String? token}) async =>
      VideoPage.fromJson(await _video('list', _req({'instance': instance, 'channel': channel, 'start': start, 'count': count, 'token': token})));

  Future<VideoPage> search(String instance, String query, {int start = 0, int count = 20, String? token}) async =>
      VideoPage.fromJson(await _video('search', _req({'instance': instance, 'query': query, 'start': start, 'count': count, 'token': token})));

  Future<VideoDetails> get(String instance, String video, {String? token}) async =>
      VideoDetails.fromJson(await _video('get', _req({'instance': instance, 'video': video, 'token': token})));

  Future<List<DownloadedVideo>> downloads() async => [
        for (final d in (await _video('downloads'))['downloads'] as List) DownloadedVideo.fromJson((d as Map).cast<String, dynamic>()),
      ];

  Future<void> delete(String instance, String video) => _video('delete', {'instance': instance, 'video': video});

  /// Where to open [video] (a link, uuid or short uuid) at [offsetS]: the saved file, else a stream.
  Future<VideoTarget> resolve(String video, {String? instance, double? offsetS, String? token}) async =>
      VideoTarget.fromJson(await _video('resolve', _req({'video': video, 'instance': instance, 'offset_s': offsetS, 'token': token})));

  /// Starts a download job (choice: "audio", "lowest", "highest" or a resolution key from [VideoDetails.options]).
  /// Poll [VideoJob.progress]; cancel keeps the partial file and a new job for the same video continues it.
  Future<VideoJob> startDownload(String instance, String video, {String choice = 'lowest', String? token}) async => VideoJob._(
      this,
      (await _call('jobStart', {
        'kind': 'video_download',
        'params': _req({'dir': dir, 'instance': instance, 'video': video, 'choice': choice, 'token': token}),
      })) as int);

  Future<void> close() async {
    if (_closed) return;
    try {
      await _call('close');
    } catch (_) {}
    _closed = true;
    _failAll(const CacheSearchException('internal', 'The video core is closed'));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _fromWorker.close();
    _errors?.close();
  }
}

/// A running or finished download.
class VideoJob {
  VideoJob._(this._core, this._id);

  final VideoCore _core;
  final int _id;
  bool _freed = false;

  Future<JobProgress> progress() async =>
      JobProgress.fromJson(((await _core._call('jobProgress', {'job': _id})) as Map).cast<String, dynamic>());

  Future<void> cancel() => _core._call('jobCancel', {'job': _id});

  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('jobFree', {'job': _id});
    } catch (_) {}
  }
}

void _workerMain(List<dynamic> init) {
  final toMain = init[0] as SendPort;
  final factory = init[1] as CsNativeFactory;
  final rp = ReceivePort();
  toMain.send(rp.sendPort);
  CsNative? native;
  var handle = 0;
  final jobs = <int, CoreJob>{};
  var nextKey = 1;

  rp.listen((dynamic m) {
    final msg = m as Map;
    final id = msg['id'] as int;
    final a = (msg['args'] as Map).cast<String, dynamic>();
    try {
      Object? result;
      switch (msg['op']) {
        case 'open':
          native = factory();
          handle = native!.open(jsonEncode({'sources': <Object>[], 'video': {'dir': a['dir']}}));
          if (handle == 0) throw CacheSearchException.fromJson(native!.lastError(0));
        case 'video':
          if (handle == 0) throw const CacheSearchException('internal', 'The video core is not open');
          result = native!.video(handle, a['op'] as String, a['request'] as String) ?? (throw CacheSearchException.fromJson(native!.lastError(handle)));
        case 'jobStart':
          final j = CoreJob.start(native!, a['kind'] as String, (a['params'] as Map).cast<String, dynamic>());
          final key = nextKey++;
          jobs[key] = j;
          result = key;
        case 'jobProgress':
          final p = jobs[a['job']]!.progress();
          result = {
            'state': p.state.name,
            'done': p.done,
            'total': p.total,
            'error': p.errorCode == null ? null : {'code': p.errorCode, 'message': p.errorMessage},
          };
        case 'jobCancel':
          jobs[a['job']]!.cancel();
        case 'jobFree':
          jobs.remove(a['job'])?.free();
        case 'close':
          for (final j in jobs.values) {
            j.free();
          }
          jobs.clear();
          if (handle != 0) native?.close(handle);
          handle = 0;
        default:
          throw CacheSearchException('internal', 'Unknown call ${msg['op']}');
      }
      toMain.send({'id': id, 'result': result});
    } on CacheSearchException catch (e) {
      toMain.send({'id': id, 'error': [e.code, e.message]});
    } catch (e) {
      toMain.send({'id': id, 'error': ['internal', e.toString()]});
    }
  });
}
