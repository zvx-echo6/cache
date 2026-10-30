import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../net/fetch.dart' show kUserAgent;

/// Why a download stopped, in words for people.
class DownloadException implements Exception {
  const DownloadException(this.message, {this.code = 'failed'});

  final String message;

  /// "no_space", "checksum", "cancelled", "network" or "failed".
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

/// iOS uses a native helper compiled against its platform statvfs headers.
/// Android and Linux use libc directly (64-bit). Null on failure or unsupported platforms; the download relies on the
/// write failing cleanly when the disk is full.
int? freeBytesOnDisk(String dir) {
  if (Platform.isIOS) {
    final path = dir.toNativeUtf8();
    try {
      final freeBytes = ffi.DynamicLibrary.process()
          .lookupFunction<
            ffi.Int64 Function(ffi.Pointer<Utf8>),
            int Function(ffi.Pointer<Utf8>)
          >('cache_free_bytes_on_disk');
      final available = freeBytes(path);
      return available < 0 ? null : available;
    } catch (_) {
      return null;
    } finally {
      calloc.free(path);
    }
  }
  if (!(Platform.isAndroid || Platform.isLinux)) return null;
  if (ffi.Abi.current() != ffi.Abi.androidArm64 &&
      ffi.Abi.current() != ffi.Abi.androidX64 &&
      ffi.Abi.current() != ffi.Abi.linuxArm64 &&
      ffi.Abi.current() != ffi.Abi.linuxX64) {
    return null;
  }
  final path = dir.toNativeUtf8();
  // struct statvfs on 64-bit: f_bsize, f_frsize, f_blocks, f_bfree, f_bavail (unsigned 64-bit each), then more.
  final buf = calloc<ffi.Uint64>(32);
  try {
    final statvfs = ffi.DynamicLibrary.process()
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>),
          int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>)
        >('statvfs');
    if (statvfs(path, buf) != 0) return null;
    final frsize = buf[1];
    final bavail = buf[4];
    return frsize * bavail;
  } catch (_) {
    return null;
  } finally {
    calloc.free(path);
    calloc.free(buf);
  }
}

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
    this.freeSpace = freeBytesOnDisk,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? _defaultClient;

  final FreeSpace freeSpace;
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
    final client = _clientFactory();
    cancel?._onCancel(() => client.close(force: true));
    try {
      _checkCancel(cancel);
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
      throw DownloadException(
        full
            ? 'The device is out of space. Free some and try again.'
            : 'Could not write the file: ${e.message}',
        code: full ? 'no_space' : 'failed',
      );
    } finally {
      client.close(force: true);
    }
  }

  DownloadException? _stopped(CancelToken? c) => c != null && c.isCancelled
      ? const DownloadException('Cancelled', code: 'cancelled')
      : null;

  void _checkCancel(CancelToken? c) {
    if (c != null && c.isCancelled) {
      throw const DownloadException('Cancelled', code: 'cancelled');
    }
  }

  /// Follows redirects (301, 302, 303, 307, 308) with HEAD until a 200; returns the final address and size.
  Future<_Resolved> _resolve(
    HttpClient client,
    Uri url,
    CancelToken? cancel,
  ) async {
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
      throw DownloadException(
        'The download server answered ${res.statusCode}.',
      );
    }
    final raf = await part.open(mode: mode);
    var done = from;
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in res) {
        _checkCancel(cancel);
        await raf.writeFrom(chunk);
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
