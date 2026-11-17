import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:xml/xml.dart';

import '../chat/ask_focus.dart';
import '../net/fetch.dart' show kUserAgent;
import 'free_space.dart';

export 'free_space.dart' show allowedBytesOnDisk, freeBytesOnDisk;

/// Why a download stopped, in words for people.
class DownloadException implements Exception {
  const DownloadException(this.message, {this.code = 'failed'});

  final String message;

  /// "no_space", "checksum", "cancelled", "network", "not_mirrored" or "failed".
  final String code;

  @override
  String toString() => message;
}

/// Not enough room on the device.
class NoSpaceException extends DownloadException {
  NoSpaceException(this.needed, this.available)
    : super(
        'Not enough free space: ${_mb(needed)} needed, ${_mb(available)} free.',
        code: 'no_space',
      );

  final int needed;
  final int available;
}

String _mb(int b) => b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

/// Asked to stop. Checked between chunks; the partly downloaded file stays so the download can go on later.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      l();
    }
  }

  void _onCancel(void Function() f) => _listeners.add(f);
}

/// Free bytes on the file system holding [dir], or null when it cannot be told.
typedef FreeSpace = int? Function(String dir);

/// The room a download needs on top of the file: a margin for the file system and other writers.
int downloadMargin(int fileBytes) {
  final five = fileBytes ~/ 20;
  const min = 64 << 20;
  return five > min ? five : min;
}

class DownloadResult {
  const DownloadResult({
    required this.file,
    required this.bytes,
    required this.verified,
    this.checksumKind,
  });

  final File file;
  final int bytes;

  /// True when the file matched a published checksum (Kiwix's, or one given by the caller).
  final bool verified;
  final String? checksumKind;
}

/// Downloads one file from its official address and checks it against the checksum Kiwix publishes next to
/// it. It follows redirects to a mirror, resumes a partly downloaded file with an HTTP Range request,
/// checks free space first, reports progress and can be cancelled.
class ZimDownloader {
  ZimDownloader({
    this.freeSpace = allowedBytesOnDisk,
    HttpClient Function()? clientFactory,
    @visibleForTesting this.writeChunk = _writeChunk,
    this.stallTimeout = const Duration(seconds: 60),
  }) : _clientFactory = clientFactory ?? _defaultClient;

  /// The free space a download may use (the pre-check: see [usableBytesOnDisk]).
  final FreeSpace freeSpace;

  /// Writes one chunk of the body; tests give one that fails the way a full disk does.
  final Future<void> Function(RandomAccessFile file, List<int> chunk) writeChunk;

  /// How long a body may send nothing before the connection counts as stalled (and the next mirror takes over).
  final Duration stallTimeout;

  static Future<void> _writeChunk(RandomAccessFile file, List<int> chunk) => file.writeFrom(chunk);
  final HttpClient Function() _clientFactory;

  static HttpClient _defaultClient() => HttpClient()
    ..userAgent = kUserAgent
    ..connectionTimeout = const Duration(seconds: 20);

  /// Downloads [url] into [part] (a partial file from an earlier try is continued), verifies it and returns
  /// the finished file, which is [part] itself; the caller moves it into place.
  Future<DownloadResult> download({
    required Uri url,
    required File part,
    Uri? sha256Url,
    Uri? md5Url,
    String? expectedSha256,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  }) async {
    // While Ask answers, a download that has not started waits (see chat/ask_focus.dart); one running is held in _fetchBody.
    await askIdle(worker: 'Downloads');
    final client = _clientFactory();
    cancel?._onCancel(() => client.close(force: true));
    try {
      _checkCancel(cancel);
      // 0. Kiwix's own metalink lists the mirrors in order of preference, with the file's sha-256. Without one (or without a
      // sha-256 in it) the redirect and the .sha256 beside the file are used, as before.
      final meta = await _fetchMetalink(client, url, cancel);
      if (meta != null && meta.mirrors.isNotEmpty && (meta.sha256 != null || expectedSha256 != null)) {
        return await _downloadFromMirrors(
          client,
          meta,
          part,
          expectedSha256 != null ? _Checksum('sha256', expectedSha256.toLowerCase()) : _Checksum('sha256', meta.sha256!),
          onProgress,
          onVerifying,
          cancel,
        );
      }
      // 1. The real address (the mirror) and the exact size.
      final head = await _resolve(client, url, cancel);
      final total = head.length;
      final dir = part.parent.path;

      // 2. Free space: the rest of the file and a margin.
      final have = part.existsSync() ? part.lengthSync() : 0;
      final startAt = have <= total ? have : 0;
      final avail = freeSpace(dir);
      final needed = (total - startAt) + downloadMargin(total);
      if (avail != null && avail < needed) {
        throw NoSpaceException(needed, avail);
      }

      // 3. The published checksum, from Kiwix's own host (not the mirror that serves the file).
      final expected = expectedSha256 != null
          ? _Checksum('sha256', expectedSha256.toLowerCase())
          : await _fetchChecksum(client, sha256Url, md5Url, cancel);

      // 4. The file.
      await _fetchBody(client, head, part, startAt, total, onProgress, cancel);
      _checkCancel(cancel);
      final size = part.lengthSync();
      if (size != total) {
        throw DownloadException(
          'The download stopped early (${_mb(size)} of ${_mb(total)}). Try again to continue.',
          code: 'network',
        );
      }

      // 5. Verify.
      if (expected != null) {
        await askIdle(worker: 'Downloads'); // the check reads the whole file: not while Ask answers
        onVerifying?.call();
        final got = await _hashFile(part.path, expected.kind);
        _checkCancel(cancel);
        if (got != expected.hex) {
          try {
            part.deleteSync();
          } catch (_) {}
          throw const DownloadException(
            'The file did not match its published checksum, so it was thrown away. Try again.',
            code: 'checksum',
          );
        }
      }
      return DownloadResult(
        file: part,
        bytes: size,
        verified: expected != null,
        checksumKind: expected?.kind,
      );
    } on DownloadException {
      rethrow;
    } on SocketException catch (e) {
      throw _stopped(cancel) ??
          DownloadException(
            'The connection failed: ${e.message}',
            code: 'network',
          );
    } on HttpException catch (e) {
      throw _stopped(cancel) ??
          DownloadException(
            'The connection failed: ${e.message}',
            code: 'network',
          );
    } on HandshakeException {
      throw const DownloadException(
        'Could not make a secure connection to the download server.',
        code: 'network',
      );
    } on TimeoutException {
      throw const DownloadException(
        'The download server took too long to answer.',
        code: 'network',
      );
    } on FileSystemException catch (e) {
      final full = (e.osError?.errorCode ?? 0) == 28;
      if (full) {
        // A full disk stops the write; the part written so far goes, so it does not keep the little room that is left.
        try {
          part.deleteSync();
        } catch (_) {}
      }
      throw DownloadException(
        full
            ? 'The device is out of space, so the download stopped and the part already saved was removed. Free some space and try again.'
            : 'Could not write the file: ${e.message}',
        code: full ? 'no_space' : 'failed',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Tries the metalink's mirrors in priority order. A mirror that answers 404, 410 or 5xx, cannot be reached, or stalls or drops the
  /// connection mid-body hands over to the next, which continues the partial file with a Range request. When every mirror says
  /// 404 or 410 the file is not on the download servers yet.
  Future<DownloadResult> _downloadFromMirrors(
    HttpClient client,
    _Metalink meta,
    File part,
    _Checksum expected,
    void Function(int, int)? onProgress,
    void Function()? onVerifying,
    CancelToken? cancel,
  ) async {
    Object? lastError;
    var allMissing = true;
    var spaceChecked = false;
    for (final mirror in meta.mirrors) {
      _checkCancel(cancel);
      try {
        final head = await _resolve(client, mirror, cancel, mirror: true);
        final total = head.length;
        if (meta.size != null && total != meta.size) {
          allMissing = false;
          lastError = const DownloadException('The download server sent a file of the wrong size. Try again.', code: 'network');
          continue;
        }
        final have = part.existsSync() ? part.lengthSync() : 0;
        final startAt = have <= total ? have : 0;
        if (!spaceChecked) {
          final avail = freeSpace(part.parent.path);
          final needed = (total - startAt) + downloadMargin(total);
          if (avail != null && avail < needed) throw NoSpaceException(needed, avail);
          spaceChecked = true;
        }
        await _fetchBody(client, head, part, startAt, total, onProgress, cancel);
        _checkCancel(cancel);
        final size = part.lengthSync();
        if (size != total) {
          throw DownloadException(
            'The download stopped early (${_mb(size)} of ${_mb(total)}). Try again to continue.',
            code: 'network',
          );
        }
        // Verify against the metalink's hash.
        await askIdle(worker: 'Downloads'); // the check reads the whole file: not while Ask answers
        onVerifying?.call();
        final got = await _hashFile(part.path, expected.kind);
        _checkCancel(cancel);
        if (got != expected.hex) {
          try {
            part.deleteSync();
          } catch (_) {}
          throw const DownloadException(
            'The file did not match its published checksum, so it was thrown away. Try again.',
            code: 'checksum',
          );
        }
        return DownloadResult(file: part, bytes: size, verified: true, checksumKind: expected.kind);
      } on _MirrorStatus catch (e) {
        if (e.status != 404 && e.status != 410 && e.status < 500) rethrow;
        if (e.status != 404 && e.status != 410) allMissing = false;
        lastError = e;
      } on SocketException catch (e) {
        _checkCancel(cancel);
        allMissing = false;
        lastError = e;
      } on HttpException catch (e) {
        _checkCancel(cancel);
        allMissing = false;
        lastError = e;
      } on HandshakeException catch (e) {
        allMissing = false;
        lastError = e;
      } on TimeoutException catch (e) {
        _checkCancel(cancel);
        allMissing = false;
        lastError = e;
      } on DownloadException catch (e) {
        if (e.code != 'network') rethrow;
        allMissing = false;
        lastError = e;
      }
    }
    if (allMissing) {
      throw const DownloadException(
        "This file isn't on the download servers yet. Try again later.",
        code: 'not_mirrored',
      );
    }
    throw lastError!;
  }

  /// Kiwix's metalink for [url] (`<url>.meta4`, on the same host), or null when there is none or it cannot be read.
  Future<_Metalink?> _fetchMetalink(HttpClient client, Uri url, CancelToken? cancel) async {
    if (!url.path.toLowerCase().endsWith('.zim')) return null;
    try {
      var at = url.replace(path: '${url.path}.meta4', query: null, fragment: null);
      for (var hop = 0; hop < 4; hop++) {
        _checkCancel(cancel);
        final req = await client.getUrl(at);
        req.followRedirects = false;
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.isRedirect) {
          await res.drain<void>();
          at = at.resolve(res.headers.value(HttpHeaders.locationHeader) ?? '');
          continue;
        }
        if (res.statusCode != 200) {
          await res.drain<void>();
          return null;
        }
        final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
        if (text.length > 1 << 20) return null;
        return _Metalink.parse(text);
      }
    } on SocketException {
      // The file itself decides whether the network works.
    } on HttpException {
      // Same.
    } on TimeoutException {
      // Same.
    } on HandshakeException {
      // Same.
    } on FormatException {
      // Not text: no metalink.
    }
    return null;
  }

  DownloadException? _stopped(CancelToken? c) => c != null && c.isCancelled
      ? const DownloadException('Canceled', code: 'cancelled')
      : null;

  void _checkCancel(CancelToken? c) {
    if (c != null && c.isCancelled) {
      throw const DownloadException('Canceled', code: 'cancelled');
    }
  }

  /// Follows redirects (301, 302, 303, 307, 308) with HEAD until a 200; returns the final address and size.
  ///
  /// With [mirror], an answer that is not 200 throws a [_MirrorStatus] so the caller can tell a missing file from a failing server.
  Future<_Resolved> _resolve(
    HttpClient client,
    Uri url,
    CancelToken? cancel, {
    bool mirror = false,
  }) async {
    var u = url;
    for (var hop = 0; hop < 8; hop++) {
      _checkCancel(cancel);
      final req = await client.openUrl('HEAD', u);
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 30));
      await res.drain<void>();
      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null) {
          throw const DownloadException(
            'The download server sent a redirect with no address.',
          );
        }
        u = u.resolve(loc);
        continue;
      }
      if (mirror && res.statusCode != 200) throw _MirrorStatus(res.statusCode);
      if (res.statusCode == 404) {
        throw const DownloadException(
          'That file is no longer on the download server.',
          code: 'failed',
        );
      }
      if (res.statusCode != 200) {
        throw DownloadException(
          'The download server answered ${res.statusCode}.',
        );
      }
      final len = res.contentLength;
      if (len <= 0) {
        throw const DownloadException(
          'The download server did not say how big the file is.',
        );
      }
      final ranges = (res.headers.value('accept-ranges') ?? '')
          .toLowerCase()
          .contains('bytes');
      return _Resolved(u, len, ranges);
    }
    throw const DownloadException(
      'The download server redirected too many times.',
    );
  }

  Future<_Checksum?> _fetchChecksum(
    HttpClient client,
    Uri? sha256Url,
    Uri? md5Url,
    CancelToken? cancel,
  ) async {
    for (final c in [(sha256Url, 'sha256', 64), (md5Url, 'md5', 32)]) {
      final u = c.$1;
      if (u == null) continue;
      _checkCancel(cancel);
      try {
        var at = u;
        for (var hop = 0; hop < 6; hop++) {
          final req = await client.getUrl(at);
          req.followRedirects = false;
          final res = await req.close().timeout(const Duration(seconds: 30));
          if (res.isRedirect) {
            await res.drain<void>();
            at = at.resolve(
              res.headers.value(HttpHeaders.locationHeader) ?? '',
            );
            continue;
          }
          if (res.statusCode != 200) {
            await res.drain<void>();
            break;
          }
          final text = await res
              .transform(latin1.decoder)
              .join()
              .timeout(const Duration(seconds: 30));
          final m = RegExp('^\\s*([0-9a-fA-F]{${c.$3}})\\b').firstMatch(text);
          if (m != null) return _Checksum(c.$2, m.group(1)!.toLowerCase());
          break;
        }
      } on SocketException {
        // Try the next kind; the file itself decides whether the network works.
      } on TimeoutException {
        // Same.
      }
    }
    return null;
  }

  Future<void> _fetchBody(
    HttpClient client,
    _Resolved r,
    File part,
    int startAt,
    int total,
    void Function(int, int)? onProgress,
    CancelToken? cancel,
  ) async {
    var from = startAt;
    if (from == total) {
      onProgress?.call(total, total);
      return;
    }
    if (!r.ranges) from = 0;
    final req = await client.getUrl(r.url);
    req.followRedirects = false;
    if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    final res = await req.close();
    if (res.isRedirect) {
      await res.drain<void>();
      final next = r.url.resolve(
        res.headers.value(HttpHeaders.locationHeader) ?? '',
      );
      return _fetchBody(
        client,
        _Resolved(next, r.length, r.ranges),
        part,
        startAt,
        total,
        onProgress,
        cancel,
      );
    }
    var mode = FileMode.append;
    if (from > 0 && res.statusCode == 206) {
      // The server must continue exactly where the file ends.
      final cr = res.headers.value('content-range') ?? '';
      if (!cr.startsWith('bytes $from-')) {
        await res.drain<void>();
        throw const DownloadException(
          'The download server continued from the wrong place. Try again.',
          code: 'network',
        );
      }
    } else if (res.statusCode == 200) {
      // No range support, or a fresh start: write the file from its beginning.
      from = 0;
      mode = FileMode.write;
    } else {
      await res.drain<void>();
      throw _MirrorStatus(res.statusCode);
    }
    final raf = await part.open(mode: mode);
    var done = from;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in res.timeout(stallTimeout)) {
        _checkCancel(cancel);
        // While Ask answers the stream is held (an await in an await-for body pauses the subscription: nothing is lost). The hold
        // lasts at most [kAskHoldMax] at a time, one chunk goes by after each, so the connection never sits silent long enough for
        // the server to drop it.
        await askIdle(worker: 'Downloads', maxWait: kAskHoldMax);
        await writeChunk(raf, chunk);
        done += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 250) {
          lastReport = now;
          onProgress?.call(done, total);
        }
      }
    } finally {
      await raf.close();
    }
    onProgress?.call(done, total);
  }
}

/// A server's answer that is not a file. Its words are the ones every such answer has always had.
class _MirrorStatus extends DownloadException {
  _MirrorStatus(this.status) : super('The download server answered $status.');

  final int status;
}

/// What Kiwix's metalink (`<file><size/><hash type="sha-256"/><url priority="1"/>...`) says.
class _Metalink {
  const _Metalink(this.mirrors, this.sha256, this.size);

  /// Mirror addresses, lowest priority number first; one with no priority goes last.
  final List<Uri> mirrors;
  final String? sha256;
  final int? size;

  /// Reads the document with a real XML parser; null when it is not well-formed or has no file.
  static _Metalink? parse(String text) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException {
      return null;
    }
    final file = doc.findAllElements('file').firstOrNull;
    if (file == null) return null;
    final ranked = <(int, int, Uri)>[];
    var i = 0;
    for (final e in file.findElements('url')) {
      final u = Uri.tryParse(e.innerText.trim());
      if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) continue;
      final pr = int.tryParse(e.getAttribute('priority') ?? '');
      ranked.add((pr ?? 1 << 30, i++, u));
    }
    ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    String? sha;
    for (final h in file.findElements('hash')) {
      final v = h.innerText.trim().toLowerCase();
      if (h.getAttribute('type')?.toLowerCase() == 'sha-256' && RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) sha = v;
    }
    final size = int.tryParse(file.findElements('size').firstOrNull?.innerText.trim() ?? '');
    return _Metalink([for (final r in ranked) r.$3], sha, size != null && size > 0 ? size : null);
  }
}

class _Resolved {
  const _Resolved(this.url, this.length, this.ranges);

  final Uri url;
  final int length;
  final bool ranges;
}

class _Checksum {
  const _Checksum(this.kind, this.hex);

  final String kind;
  final String hex;
}

/// The hex digest of a whole file, computed off the UI thread.
Future<String> _hashFile(String path, String kind) => Isolate.run(() async {
  final Hash h = kind == 'md5' ? md5 : sha256;
  final d = await h.bind(File(path).openRead()).first;
  return d.toString();
});

/// The hex digest of a file (sha256 or md5), for tests and for checking a finished file again.
Future<String> hashFile(String path, {String kind = 'sha256'}) =>
    _hashFile(path, kind);
