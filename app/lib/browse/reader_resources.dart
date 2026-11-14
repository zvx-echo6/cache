import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
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
      // Android: when the page's renderer dies (the phone ran low on memory, or it crashed) the reader is told and shows a
      // Reload button. Without this, Android ends the whole app.
      useOnRenderProcessGone: true,
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

/// ZIMs made without pictures (Kiwix's "mini" and "nopic" editions, such as WikiMed mini) keep each picture's place as a
/// transparent SVG of its size (`data:image/svg+xml`, fill transparent). Wikipedia's own styles paint infobox pictures white
/// when the phone is in dark mode (`prefers-color-scheme: dark`, "images with white backgrounds"), so every missing picture
/// showed as a blank white box: on iPhone, in dark mode at night (1.0.28 feedback). In light mode the placeholder is invisible,
/// which is why Android looked fine. Those placeholders are made to take no space and no colour. Real pictures are untouched.
const String kNoPicturePlaceholderStyle =
    '<style id="cache-no-picture">img[src^="data:image/svg+xml"][src*="fill%3D%22transparent%22"]'
    '{background:transparent!important;border:0!important;display:none!important}</style>';

/// [html] with [kNoPicturePlaceholderStyle] at the end of its head (or at the start when it has none). Both readers use it.
String withoutPicturePlaceholders(String html) {
  final head = RegExp(r'</head\s*>', caseSensitive: false).firstMatch(html);
  if (head != null) return html.replaceRange(head.start, head.start, kNoPicturePlaceholderStyle);
  final doctype = RegExp(r'^\s*<!doctype[^>]*>', caseSensitive: false).firstMatch(html);
  final at = doctype?.end ?? 0;
  return html.replaceRange(at, at, kNoPicturePlaceholderStyle);
}

/// The in-memory IndexedDB and Web Storage every ZIM page gets (the reader's frame has no storage of its own, and pages built on
/// PouchDB would stay on "Loading"). One file for the server and both phone readers; nothing it holds is kept.
const String kZimStorageAsset = 'assets/reader/zim_storage.js';

/// Its licence text (a copy of third_party/fake-indexeddb/LICENSE; a test keeps them equal), listed under Open-source licenses.
const String kFakeIndexedDbLicenseAsset = 'assets/reader/fake-indexeddb-LICENSE';

Future<String>? _zimStorage;

/// The stand-in's text, read once. The reader screen starts it when it opens, so the first page does not wait.
Future<String> zimStorageScript() => _zimStorage ??= rootBundle.loadString(kZimStorageAsset);

/// The index just past the end of the first `<name ...>` tag in [lower] (the page in lower case), or null.
int? _afterOpenTag(String lower, String name) {
  final m = RegExp('<$name(?=[\\s/>])').firstMatch(lower);
  if (m == null) return null;
  final end = lower.indexOf('>', m.end);
  return end < 0 ? null : end + 1;
}

/// [html] with [js] as an inline script first in its head (after `<html>` when it has no head, at the start with neither), so it
/// runs before the page's own scripts. Both phone readers use it, as the server does for the browser.
String withZimStorage(String html, String js) {
  final lower = html.toLowerCase();
  final at = _afterOpenTag(lower, 'head') ?? _afterOpenTag(lower, 'html') ?? 0;
  final safe = js.replaceAll(RegExp('</script', caseSensitive: false), r'<\/script');
  return html.replaceRange(at, at, '<script>$safe</script>');
}

/// What the Android reader gives a page: the stand-in first, the no-picture style at the end of the head.
String androidReaderHtml(String html, String js) => withoutPicturePlaceholders(withZimStorage(html, js));

String _offlineHtml(String html, String? storageScript) {
  html = withoutPicturePlaceholders(storageScript == null ? html : withZimStorage(html, storageScript));
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
/// API takes raw Uint8List bytes and exposes no HTTP status/header fields. [storageScript] is the text of [zimStorageScript].
Future<CustomSchemeResponse> serveCustomZimResource(
  ZimPageServer server,
  Uri url, {
  String? storageScript,
}) async {
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
      utf8.encode(_offlineHtml(utf8.decode(bytes, allowMalformed: true), storageScript)),
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
