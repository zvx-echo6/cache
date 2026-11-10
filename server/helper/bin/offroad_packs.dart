import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../packages/cache_search/lib/src/errors.dart';

/// The hosts an off-road pack may be fetched from (the published data bucket, under both its names; the same two the server's
/// `/api/fetch` allows for the catalogues). A browser names the address, so it is checked here, not trusted.
const Set<String> kPackHosts = {'data.cached.info', 'cache.echo6.co'};

bool _defaultAllowed(Uri u) => u.scheme == 'https' && kPackHosts.contains(u.host);

final RegExp _segment = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');

/// The off-road packs the server downloads for the browser, as the phone's RegionsState._fetchPack does for itself: into
/// `<dir>/<build>/<id>/offroad.sqlite`, under the hidden name `.offroad.sqlite.part` in that folder (a part left by an earlier try
/// is continued), checked against the published SHA-256 (a file that does not match is thrown away), then renamed into place, so the
/// router only ever sees whole packs. The download runs in the helper, so it goes on with no browser open.
class OffroadPacks {
  OffroadPacks(this.dir, {this.log, HttpClient Function()? clientFactory, bool Function(Uri)? allowed, this.idleTimeout = const Duration(seconds: 60)})
      : _clientFactory = clientFactory ?? _defaultClient,
        _allowed = allowed ?? _defaultAllowed;

  /// `<support>/regions/offroad`.
  final Directory dir;
  final void Function(String message)? log;
  final HttpClient Function() _clientFactory;
  final bool Function(Uri) _allowed;

  /// How long a download may go with no bytes arriving before it fails (the part is kept, so a later try continues). Not an overall
  /// deadline: a large pack that keeps flowing is never cut off.
  final Duration idleTimeout;

  final Map<String, _Run> _runs = {};

  /// The person's Pause: nothing is fetched until it is lifted.
  bool held = false;

  static HttpClient _defaultClient() => HttpClient()
    ..userAgent = 'Cache/server'
    ..connectionTimeout = const Duration(seconds: 20);

  /// The pack's file under [dir]; `bad_path` unless [path] is `<build>/<id>/offroad.sqlite` with plain names.
  File fileOf(Object? path) {
    final parts = path is String ? path.split('/') : const <String>[];
    if (parts.length != 3 || !parts.every((s) => _segment.hasMatch(s) && !s.contains('..')) || parts.last != 'offroad.sqlite') {
      throw const CacheSearchException('bad_path', 'An off-road pack is <build>/<id>/offroad.sqlite');
    }
    return File('${dir.path}/${parts.join('/')}');
  }

  File _partOf(File dest) => File('${dest.parent.path}/.offroad.sqlite.part');

  /// Starts the download of one pack (nothing when it is on disk, already running, or the downloads are held). Answers at once.
  Map<String, Object?> fetch(Map<String, dynamic> a) {
    final dest = fileOf(a['path']);
    final path = a['path'] as String;
    final url = Uri.tryParse('${a['url']}');
    if (url == null || !_allowed(url)) throw const CacheSearchException('bad_url', 'That address is not one an off-road pack is fetched from');
    final sha = '${a['sha256'] ?? ''}'.toLowerCase();
    final bytes = (a['bytes'] as num?)?.toInt() ?? 0;
    if (dest.existsSync()) return {'state': 'ready'};
    if (held) return {'state': 'held'};
    final running = _runs[path];
    if (running != null && running.running) return {'state': 'running'};
    final run = _runs[path] = _Run()..total = bytes;
    unawaited(_download(path, dest, url, sha, bytes, run));
    return {'state': 'running'};
  }

  Future<void> _download(String path, File dest, Uri url, String sha, int bytes, _Run run) async {
    final part = _partOf(dest);
    final client = _clientFactory();
    run.client = client;
    try {
      dest.parent.createSync(recursive: true);
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (bytes > 0 && have > bytes) {
        part.deleteSync();
        have = 0;
      }
      var res = await _get(client, url, have);
      if (res.statusCode == 416) {
        await res.drain<void>();
        part.deleteSync();
        have = 0;
        res = await _get(client, url, 0);
      }
      // A redirect is never followed (the address was checked only before the request), so any 3xx fails like a bad status.
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}');
      }
      // A server that ignored the range sends the whole file: start over.
      if (res.statusCode == 200) have = 0;
      run.done = have;
      if (res.contentLength > 0) run.total = have + res.contentLength;
      final sink = part.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res.timeout(idleTimeout)) {
          if (run.cancelled) break;
          sink.writeFromSync(chunk);
          run.done += chunk.length;
        }
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
      if (run.cancelled) {
        _runs.remove(path);
        return;
      }
      final size = part.lengthSync();
      if (bytes > 0 && size != bytes) {
        throw const HttpException('The download stopped early');
      }
      if (sha.isNotEmpty) {
        final digest = (await sha256.bind(part.openRead()).first).toString();
        if (digest != sha) {
          part.deleteSync();
          throw const FormatException('The file does not match its checksum');
        }
      }
      part.renameSync(dest.path);
      _runs.remove(path);
      log?.call('off-road pack $path downloaded');
    } catch (e) {
      if (run.cancelled) {
        _runs.remove(path);
        return;
      }
      log?.call('off-road pack $path failed: $e');
      run
        ..running = false
        ..error = "Off-road data couldn't be downloaded. Try again later.";
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri url, int from) async {
    final req = await client.getUrl(url);
    req.followRedirects = false;
    if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    return req.close().timeout(idleTimeout);
  }

  /// What each of [paths] is: `{"<path>": {"on_disk", "running", "done", "total", "error"}}`.
  Map<String, Object?> status(Iterable<Object?> paths) {
    final out = <String, Object?>{};
    for (final p in paths) {
      final File f;
      try {
        f = fileOf(p);
      } on CacheSearchException {
        continue;
      }
      final run = _runs['$p'];
      out['$p'] = {
        'on_disk': f.existsSync(),
        'running': run?.running ?? false,
        'done': run?.done ?? 0,
        'total': run?.total ?? 0,
        'error': run?.error,
      };
    }
    return out;
  }

  /// Stops one download; what it fetched so far stays for the next try.
  void cancel(String path) {
    final run = _runs.remove(path);
    run?.cancelled = true;
    run?.client?.close(force: true);
  }

  /// Pause: stops every download, as the phone does.
  void cancelAll() {
    for (final p in List.of(_runs.keys)) {
      cancel(p);
    }
  }

  /// Stops the pack's download and deletes the file and the part (a region that was the last to use it was removed).
  void remove(Object? path) {
    final dest = fileOf(path);
    cancel(path as String);
    for (final f in [dest, _partOf(dest)]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException catch (e) {
        log?.call('off-road pack $path: ${e.message}');
      }
    }
  }
}

class _Run {
  bool running = true;
  bool cancelled = false;
  int done = 0;
  int total = 0;
  String? error;
  HttpClient? client;
}
