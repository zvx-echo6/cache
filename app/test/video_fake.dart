import 'dart:convert';

import 'package:cache_search/cache_search.dart';

/// A stand-in for the native core that behaves like a small PeerTube connector: it keeps the instance list, knows
/// one account, shows a video as saved once its download job has finished. Top-level so it can run in the worker isolate.
CsNative fakeVideoNative() => VideoFakeNative();

/// A factory of [VideoFakeNative]s with [saved] already on the device (the manifests as cs_video_downloads lists them; the
/// closure is copied to the worker isolate). [captionFetchFails]: captions_fetch fetches nothing.
CsNative Function() seededVideoNative(List<Map<String, dynamic>> saved, {bool captionFetchFails = false, bool noCaptions = false}) =>
    () => VideoFakeNative()
      .._saved.addAll([for (final m in saved) {...m}])
      ..captionFetchFails = captionFetchFails
      ..noCaptions = noCaptions;

/// A saved video's manifest for [seededVideos].
Map<String, dynamic> savedManifest({
  required String uuid,
  required String title,
  String channel = 'Field Skills',
  String at = '2026-10-01T10:00:00Z',
  int size = 230 * 1024 * 1024,
  int durationS = 252,
  String label = '480p',
  List<Map<String, dynamic>> captions = const [],
  List<Map<String, dynamic>> missing = const [],
  String instance = 'example.org',
  String? thumb,
}) =>
    {
      'instance': instance, 'uuid': uuid, 'title': title, 'channel': {'display_name': channel}, 'duration_s': durationS, 'kind': 'video',
      'resolution': label.replaceAll('p', ''), 'resolution_label': label, 'size': size, 'path': '/data/$uuid/video.mp4', 'thumbnail_path': thumb,
      'downloaded_at': at, 'captions': captions, 'missing_captions': missing,
      'warnings': [for (final m in missing) 'caption ${m['language']} not saved: the instance did not answer'],
      'description': 'How to tie it, step by step.', 'published_at': '2026-03-14T09:00:00Z',
    };

class VideoFakeNative implements CsNative {
  // The tool, location, places and live calls are not used by these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final List<Map<String, dynamic>> _instances = [];
  final List<Map<String, dynamic>> _saved = [];
  String? _error;
  int _progressCalls = 0;
  bool _accessValid = true;

  static const String uuid = '07273a4b-40a5-433f-a305-1c8f4268fd72';

  Map<String, dynamic> _video() => {
        'uuid': uuid,
        'short_uuid': '1TesHJPJ33Jz5TUP7TA7cu',
        'title': 'Merry Christmas',
        'duration_s': 11,
        'published_at': '2026-01-01T00:00:00Z',
        'views': 3,
        'channel': {'name': 'big-clive', 'display_name': 'Big Clive', 'handle': 'big-clive', 'host': 'example.org', 'avatar': null},
        'thumbnail': null,
        'nsfw': false,
        'is_live': false,
        'downloaded': _saved.isNotEmpty,
      };

  @override
  String? video(int handle, String op, String requestJson) {
    final r = requestJson.isEmpty ? <String, dynamic>{} : (jsonDecode(requestJson) as Map).cast<String, dynamic>();
    _error = null;
    switch (op) {
      case 'instances':
        return jsonEncode({'instances': _instances});
      case 'instance_add':
        final host = (r['url'] as String).replaceFirst(RegExp(r'^https?://'), '');
        if (host.contains('nope')) {
          _error = jsonEncode({'code': 'bad_response', 'message': 'not peertube'});
          return null;
        }
        _instances.add({'id': host, 'url': 'https://$host', 'name': 'Example PeerTube', 'version': '8.2.4', 'added_at': 'x'});
        return jsonEncode(_instances.last);
      case 'instance_remove':
        _instances.removeWhere((i) => i['id'] == r['instance']);
        return jsonEncode({'removed': r['instance'], 'downloads_deleted': false});
      case 'login':
        if (r['password'] != 'right') {
          _error = jsonEncode({'code': 'auth_failed', 'message': 'wrong'});
          return null;
        }
        _accessValid = true;
        return jsonEncode({'instance': r['instance'], 'token_type': 'Bearer', 'access_token': 'A1', 'refresh_token': 'R1', 'expires_in': 100});
      case 'refresh':
        _accessValid = true;
        return jsonEncode({'instance': r['instance'], 'token_type': 'Bearer', 'access_token': 'A2', 'refresh_token': 'R2', 'expires_in': 100});
      case 'list':
      case 'search':
        if (r['token'] == 'A1' && !_accessValid) {
          _error = jsonEncode({'code': 'auth_failed', 'message': 'expired'});
          return null;
        }
        return jsonEncode({'instance': r['instance'], 'total': 1, 'start': 0, 'videos': [_video()]});
      case 'channels':
        return jsonEncode({
          'instance': r['instance'],
          'total': 1,
          'start': 0,
          'channels': [
            {'name': 'big-clive', 'display_name': 'Big Clive', 'handle': 'big-clive', 'host': 'example.org', 'avatar': null, 'description': 'd', 'followers': 2}
          ]
        });
      case 'get':
        return jsonEncode({
          ..._video(),
          'instance': r['instance'],
          'description': 'A short video',
          'download_enabled': true,
          'captions': [
            if (!noCaptions) {'language': 'en', 'label': 'English', 'automatic': true, 'url': 'https://example.org/c.vtt'}
          ],
          'options': [
            {'key': '720', 'label': '720p', 'kind': 'video', 'size': 9000000, 'source': 'web'},
            {'key': '360', 'label': '360p', 'kind': 'video', 'size': 3000000, 'source': 'web'},
            {'key': 'audio', 'label': 'Audio only', 'kind': 'audio', 'size': 500000, 'source': 'hls'},
          ],
          'stream': {'hls': null, 'mp4': 'https://example.org/v.mp4', 'needs_auth': false},
          'downloaded': _saved.isEmpty ? null : {'kind': 'video', 'resolution': '360', 'size': 3000000, 'downloaded_at': 'x'},
        });
      case 'downloads':
        return jsonEncode({'downloads': _saved, 'total_bytes': _saved.fold<int>(0, (a, d) => a + (d['size'] as int))});
      case 'delete':
        _saved.removeWhere((d) => d['uuid'] == r['video']);
        return jsonEncode({'deleted': r['video']});
      case 'captions_fetch':
        final d = _saved.firstWhere((d) => d['uuid'] == r['video'], orElse: () => <String, dynamic>{});
        if (d.isEmpty) {
          _error = jsonEncode({'code': 'not_found', 'message': 'no downloaded video'});
          return null;
        }
        if (captionFetchFails) return jsonEncode(d);
        d['captions'] = [
          ...(d['captions'] as List),
          for (final m in (d['missing_captions'] as List? ?? const [])) {...(m as Map), 'path': '/data/${d['uuid']}/captions-${m['language']}.vtt'},
        ];
        d['missing_captions'] = <Map<String, dynamic>>[];
        d['warnings'] = <String>[];
        return jsonEncode(d);
      case 'resolve':
        if (_saved.isNotEmpty) {
          return jsonEncode({
            'kind': 'local', 'instance': 'example.org', 'uuid': uuid, 'title': 'Merry Christmas', 'media': 'video',
            'path': '/data/video.mp4', 'offset_s': r['offset_s'] ?? 0, 'duration_s': 11, 'resolution': '360p', 'captions': [], 'thumbnail_path': null,
          });
        }
        return jsonEncode({
          'kind': 'stream', 'instance': 'example.org', 'uuid': uuid, 'title': 'Merry Christmas', 'url': 'https://example.org/v.mp4',
          'format': 'mp4', 'offset_s': r['offset_s'] ?? 0, 'duration_s': 11, 'needs_auth': false, 'thumbnail': null,
        });
      case 'me':
        return jsonEncode({'instance': r['instance'], 'username': 'alice'});
    }
    _error = jsonEncode({'code': 'internal', 'message': 'unknown $op'});
    return null;
  }

  @override
  int jobStart(String kind, String paramsJson) => 3;

  @override
  String? jobProgress(int job) {
    _progressCalls++;
    if (_progressCalls < 2) return '{"state":"running","done":1000000,"total":3000000,"error":null}';
    if (_saved.isEmpty) {
      _saved.add({
        'instance': 'example.org', 'uuid': uuid, 'title': 'Merry Christmas', 'channel': {'display_name': 'Big Clive'}, 'duration_s': 11,
        'kind': 'video', 'resolution': '360', 'resolution_label': '360p', 'size': 3000000, 'path': '/data/video.mp4', 'thumbnail_path': null,
        'downloaded_at': 'x', 'captions': [],
      });
    }
    return '{"state":"done","done":3000000,"total":3000000,"error":null}';
  }

  @override
  int jobCancel(int job) => 0;
  @override
  void jobFree(int job) {}
  @override
  int open(String configJson) => 1;
  @override
  String? lastError(int handle) => _error;
  @override
  void close(int handle) {}
  @override
  String? version() => '{"version":"0.1.0","index_format":2}';
  @override
  int setSources(int handle, String configJson) => 0;
  @override
  String? status(int handle) => '{"sources":[]}';
  @override
  String? search(int handle, String query, String optionsJson) => null;
  @override
  String? read(int handle, String address, int maxChars) => null;
  @override
  ZimBytes? zimGet(int handle, String address) => null;
  @override
  String? zimMainPage(int handle, String zimId) => null;
  @override
  String? suggest(int handle, String prefix, String optionsJson) => null;
  @override
  int conversationNew() => 0;
  @override
  String? format(int conv, String resultsJson) => null;
  @override
  String? conversationIds(int conv) => null;
  @override
  void conversationFree(int conv) {}

  /// captions_fetch fetches nothing (the site still does not answer).
  bool captionFetchFails = false;

  /// The site's video has no captions.
  bool noCaptions = false;

  /// Makes the next token-carrying list call fail once, as an expired token does.
  void expireToken() => _accessValid = false;
}
