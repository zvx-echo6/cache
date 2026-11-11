import 'dart:convert';

import 'core_transport.dart';
import 'errors.dart';
import 'models.dart' show JobProgress;
import 'transport_http.dart';
import 'video_models.dart';

/// The video connector in a browser. The engine is on Cache Server: its helper opens a core handle on `<docs>/videos` and answers the
/// `video.*` ops (server/helper/bin/video_ops.dart) that this sends through `/api/core`. Every call is JSON in and out like the
/// phone's (cache_search.h, "videos"); access tokens go in on each call and are kept nowhere here or on the server. Downloads are
/// jobs of the server's core, so they run with no tab open and a tab opened later finds them with [jobs].
class VideoCore {
  VideoCore._(this._transport, this.dir);

  /// Opens the server's video handle. [dir] and [indexesDir] are the phone's arguments and are not used: the server's folders are
  /// `<docs>/videos` and `<support>/indexes`. [transport] is a test hook.
  static Future<VideoCore> open(String dir, {String? indexesDir, Object? native, CoreTransport? transport}) async {
    final t = transport ?? HttpTransport();
    final info = ((await t.call('video.info', const {})) as Map).cast<String, dynamic>();
    return VideoCore._(t, (info['dir'] ?? '') as String);
  }

  final CoreTransport _transport;
  bool _closed = false;

  /// The saved videos' folder on the server (absolute).
  final String dir;

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) {
    if (_closed) return Future.error(const CacheSearchException('internal', 'The video core is closed'));
    return _transport.call(op, args);
  }

  Future<Map<String, dynamic>> _video(String op, [Map<String, dynamic>? request]) async =>
      (jsonDecode((await _call('video.call', {'op': op, 'request': request == null ? '' : jsonEncode(request)})) as String) as Map).cast<String, dynamic>();

  static Map<String, dynamic> _req(Map<String, dynamic> m) => {for (final e in m.entries) if (e.value != null) e.key: e.value};

  Future<List<VideoInstance>> instances() async => [
        for (final i in (await _video('instances'))['instances'] as List) VideoInstance.fromJson((i as Map).cast<String, dynamic>()),
      ];

  Future<VideoInstance> addInstance(String url) async => VideoInstance.fromJson(await _video('instance_add', {'url': url}));

  Future<void> removeInstance(String instance, {bool deleteDownloads = false}) =>
      _video('instance_remove', {'instance': instance, 'delete_downloads': deleteDownloads});

  Future<VideoTokens> login(String instance, String username, String password, {String? otp}) async =>
      VideoTokens.fromJson(await _video('login', _req({'instance': instance, 'username': username, 'password': password, 'otp': otp})));

  Future<VideoTokens> loginExternal(String instance, String username, String externalAuthToken) async =>
      VideoTokens.fromJson(await _video('login', {'instance': instance, 'username': username, 'external_auth_token': externalAuthToken}));

  Future<VideoAuthMethods> authMethods(String instance) async => VideoAuthMethods.fromJson(await _video('auth_methods', {'instance': instance}));

  Future<VideoTokens> refresh(String instance, String refreshToken) async =>
      VideoTokens.fromJson(await _video('refresh', {'instance': instance, 'refresh_token': refreshToken}));

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

  Future<DownloadedVideo> fetchMissingCaptions(String instance, String video, {String? token}) async =>
      DownloadedVideo.fromJson(await _video('captions_fetch', _req({'instance': instance, 'video': video, 'token': token})));

  Future<VideoTarget> resolve(String video, {String? instance, double? offsetS, String? token}) async =>
      VideoTarget.fromJson(await _video('resolve', _req({'video': video, 'instance': instance, 'offset_s': offsetS, 'token': token})));

  /// Starts a download on the server (choice: "audio", "lowest", "highest" or a resolution key). [title] and [label] are kept with the
  /// job so a tab opened later can show it. Poll [VideoJob.progress]; cancel keeps the partial file and starting the same video again
  /// continues it.
  Future<VideoJob> startDownload(String instance, String video, {String choice = 'lowest', String? token, String? title, String? label}) async {
    final r = ((await _call('video.jobStart', _req({'instance': instance, 'video': video, 'choice': choice, 'token': token, 'title': title, 'label': label}))) as Map);
    return VideoJob._(this, (r['job'] as num).toInt());
  }

  /// Every download the server holds (running, or stopped and not yet let go), so a tab that was closed or reloaded finds them again.
  Future<List<({VideoJobInfo info, VideoJob job})>> jobs() async => [
        for (final j in (await _call('video.jobs')) as List)
          (info: VideoJobInfo.fromJson((j as Map).cast<String, dynamic>()), job: VideoJob._(this, ((j)['job'] as num).toInt())),
      ];

  Future<void> close() async {
    _closed = true;
    await _transport.close();
  }
}

/// A running or finished download on the server.
class VideoJob {
  VideoJob._(this._core, this._id);

  final VideoCore _core;
  final int _id;
  bool _freed = false;

  Future<JobProgress> progress() async =>
      JobProgress.fromJson(((await _core._call('video.jobProgress', {'job': _id})) as Map).cast<String, dynamic>());

  Future<void> cancel() => _core._call('video.jobCancel', {'job': _id});

  Future<void> free() async {
    if (_freed) return;
    _freed = true;
    try {
      await _core._call('video.jobFree', {'job': _id});
    } catch (_) {}
  }
}
