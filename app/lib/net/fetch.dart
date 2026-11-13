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

/// The redirects one read follows.
const int kFetchRedirects = 5;

/// Whether a read of [from] may go on to [to], where a redirect points: an https address is never followed to anything but
/// https, and with [httpsOnly] every hop passes [isFetchAllowed] as the first address did.
bool isRedirectAllowed(Uri from, Uri to, {bool httpsOnly = true}) {
  if (from.scheme == 'https' && to.scheme != 'https') return false;
  return httpsOnly ? isFetchAllowed(to) : to.hasAuthority && to.host.isNotEmpty && (to.scheme == 'https' || to.scheme == 'http');
}

/// The answer for [url], redirects followed here one checked hop at a time ([isRedirectAllowed]): the client's own following
/// goes from https to plain http.
Future<HttpClientResponse> _open(HttpClient client, Uri url, {required bool httpsOnly, required Duration timeout}) async {
  var at = url;
  for (var hops = 0;; hops++) {
    final req = await client.getUrl(at).timeout(const Duration(seconds: 20));
    req.followRedirects = false;
    final res = await req.close().timeout(timeout);
    final to = const {301, 302, 303, 307, 308}.contains(res.statusCode) ? res.headers.value(HttpHeaders.locationHeader) : null;
    if (to == null) return res;
    await res.drain<void>();
    final ref = Uri.tryParse(to.trim());
    if (ref == null || hops >= kFetchRedirects) throw FetchException(FetchFailure.unreadable, at.host);
    final next = at.resolveUri(ref);
    if (!isRedirectAllowed(at, next, httpsOnly: httpsOnly)) throw FetchException(FetchFailure.notAllowed, next.host);
    at = next;
  }
}

/// The one way the app reads a small file from the network (catalogues, lists, icons, captions): a GET with [kUserAgent] and
/// timeouts, redirects followed (never from https to plain http), no key or cookie, at most [maxBytes]. Big files go through the resumable downloader instead
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
    final res = await _open(client, url, httpsOnly: httpsOnly, timeout: timeout);
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
