import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'zim_urls.dart';

/// Android retains HTTPS interception. iOS registers a WKURLSchemeHandler.
/// Content blockers are compiled by the pinned iOS plugin before its first load.
InAppWebViewSettings readerSettings({required bool customScheme}) =>
    InAppWebViewSettings(
      useShouldInterceptRequest: !customScheme,
      useShouldOverrideUrlLoading: true,
      resourceCustomSchemes: customScheme ? [zimReaderScheme] : [],
      contentBlockers: customScheme
          ? [
              ContentBlocker(
                trigger: ContentBlockerTrigger(
                  urlFilter: r'^[a-zA-Z][a-zA-Z0-9+.-]*:',
                ),
                action: ContentBlockerAction(
                  type: ContentBlockerActionType.BLOCK,
                ),
              ),
              // WKContentRuleList does not support regex alternation. Keep each
              // local protocol in its own rule after the generic block.
              for (final scheme in [zimReaderScheme, 'data', 'blob'])
                ContentBlocker(
                  trigger: ContentBlockerTrigger(urlFilter: '^$scheme:'),
                  action: ContentBlockerAction(
                    type: ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
                  ),
                ),
            ]
          : [],
      javaScriptEnabled: true,
      blockNetworkLoads: true,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      geolocationEnabled: false,
      supportZoom: true,
      builtInZoomControls: true,
      displayZoomControls: false,
      transparentBackground: false,
      cacheEnabled: false,
      incognito: true,
    );

// Defense in depth, installed before the archive's first script executes.
const _offlinePolicy =
    "default-src $zimReaderScheme: data: blob:; "
    "script-src $zimReaderScheme: 'unsafe-inline' 'unsafe-eval'; "
    "style-src $zimReaderScheme: 'unsafe-inline'; "
    "connect-src $zimReaderScheme:; "
    "frame-src $zimReaderScheme:; object-src 'none'; "
    "base-uri $zimReaderScheme:; form-action $zimReaderScheme:";

String _offlineHtml(String html) {
  const meta =
      '<meta http-equiv="Content-Security-Policy" content="$_offlinePolicy">';
  // Prefix the policy before any archive markup can execute or load resources.
  final doctype = RegExp(
    r'^\s*<!doctype[^>]*>',
    caseSensitive: false,
  ).firstMatch(html);
  final offset = doctype?.end ?? 0;
  return html.replaceRange(offset, offset, meta);
}

/// Always completes the native scheme task, even for a missing entry. The pinned
/// API takes raw Uint8List bytes and exposes no HTTP status/header fields.
Future<CustomSchemeResponse> serveCustomZimResource(
  ZimPageServer server,
  Uri url,
) async {
  final entry = isReaderUrl(url, customScheme: true)
      ? await server.serve(url)
      : const ServedEntry(404, 'text/plain', []);
  var mime = entry.mime.split(';').first.trim();
  var bytes = Uint8List.fromList(entry.bytes);
  if (entry.status != 200) {
    mime = 'text/html';
    bytes = Uint8List.fromList(
      utf8.encode(
        '<!doctype html><html><head><title>Offline article</title></head>'
        '<body><p>${entry.status == 404 ? 'This entry is not in the offline archive.' : 'This offline entry could not be read.'}</p></body></html>',
      ),
    );
  }
  if (mime == 'text/html') {
    bytes = Uint8List.fromList(
      utf8.encode(_offlineHtml(utf8.decode(bytes, allowMalformed: true))),
    );
  }
  final text =
      mime.startsWith('text/') ||
      mime.contains('xml') ||
      mime.contains('json') ||
      mime.contains('javascript');
  return CustomSchemeResponse(
    data: bytes,
    contentType: mime,
    // The pinned API requires a String; empty means no character encoding.
    contentEncoding: text ? 'utf-8' : '',
  );
}
