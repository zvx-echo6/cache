import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../browse/web/device_api.dart' show DeviceApi, DeviceException;
import '../browse/web/device_fetch.dart';
import '../platform.dart' as plat;
import '../version.dart';

export '../browse/web/device_api.dart' show FetchScope;

/// The one name the app gives the servers it reads from.
const String kUserAgent = 'Cache/$kAppVersion';

/// Why a fetch did not give the body.
enum FetchFailure {
  /// Not an https address (or this phone's own, for local servers).
  notAllowed,

  /// No connection.
  unreachable,

  /// The server did not answer in time.
  timedOut,

  /// The secure connection could not be made.
  insecure,

  /// The server answered with an error ([FetchException.status]).
  status,

  /// The body was larger than the caller allows.
  tooLarge,

  /// The answer could not be read to the end.
  unreadable,
}

class FetchException implements Exception {
  const FetchException(this.failure, this.host, {this.status});

  final FetchFailure failure;
  final String host;
  final int? status;

  @override
  String toString() => 'Fetching from $host failed: ${failure.name}${status == null ? '' : ' (HTTP $status)'}';
}

bool isLoopbackHost(String host) => host == 'localhost' || host == '127.0.0.1';

/// HTTPS, or this phone's own address (a local test server).
bool isFetchAllowed(Uri u) => u.hasAuthority && u.host.isNotEmpty && (u.scheme == 'https' || (u.scheme == 'http' && isLoopbackHost(u.host)));

/// The one way the app reads a small file from the network (catalogues, lists, icons, captions): a GET with [kUserAgent] and
/// timeouts, redirects followed, no key or cookie, at most [maxBytes]. Big files go through the resumable downloader instead
/// (browse/zim_download.dart). [httpsOnly] false also reads plain http (a video server's captions). [scope] is only for a browser, where
/// Cache Server reads for the page: it says what kind of address this is (a [FetchScope]; null is the catalogue hosts) and so which
/// the server allows. A phone reads any https address itself and ignores it.
Future<List<int>> fetchBytes(Uri url, {int maxBytes = 4 * 1024 * 1024, bool httpsOnly = true, Duration timeout = const Duration(seconds: 30), String? scope}) async {
  if (httpsOnly ? !isFetchAllowed(url) : !(url.scheme == 'https' || url.scheme == 'http')) {
    throw FetchException(FetchFailure.notAllowed, url.host);
  }
  // In a browser the page may not read other sites: this device reads the catalogue and hands the answer on.
  final viaDevice = deviceFetchApi;
  if (plat.isWeb && viaDevice != null) return fetchBytesViaDevice(viaDevice, url, maxBytes: maxBytes, scope: scope, plain: !httpsOnly);
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = kUserAgent;
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw FetchException(FetchFailure.status, url.host, status: res.statusCode);
    }
    final out = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      out.addAll(chunk);
      if (out.length > maxBytes) throw FetchException(FetchFailure.tooLarge, url.host);
    }
    return out;
  } on FetchException {
    rethrow;
  } on TimeoutException {
    throw FetchException(FetchFailure.timedOut, url.host);
  } on SocketException {
    throw FetchException(FetchFailure.unreachable, url.host);
  } on HandshakeException {
    throw FetchException(FetchFailure.insecure, url.host);
  } on HttpException {
    throw FetchException(FetchFailure.unreadable, url.host);
  } finally {
    client.close(force: true);
  }
}

/// [fetchBytes] in a browser: through [api] (Cache Server's `/api/fetch`, which reads the addresses [scope] allows and no private one).
Future<List<int>> fetchBytesViaDevice(DeviceApi api, Uri url, {int maxBytes = 4 * 1024 * 1024, String? scope, bool plain = false}) async {
  try {
    final body = await api.fetch(url, scope: scope, plain: plain);
    if (body.length > maxBytes) throw FetchException(FetchFailure.tooLarge, url.host);
    return body;
  } on DeviceException catch (e) {
    throw FetchException(
      switch (e.code) {
        'host_not_allowed' || 'invalid' || 'scope_off' => FetchFailure.notAllowed,
        'unreachable' || 'busy' => FetchFailure.unreachable,
        'upstream_status' => FetchFailure.status,
        'too_large' => FetchFailure.tooLarge,
        _ => FetchFailure.unreadable,
      },
      url.host,
      status: e.code == 'upstream_status' ? e.status : null,
    );
  }
}

/// [fetchBytes] as UTF-8 text.
Future<String> fetchText(Uri url, {int maxBytes = 4 * 1024 * 1024, bool httpsOnly = true, Duration timeout = const Duration(seconds: 30), String? scope}) async =>
    utf8.decode(await fetchBytes(url, maxBytes: maxBytes, httpsOnly: httpsOnly, timeout: timeout, scope: scope), allowMalformed: true);
