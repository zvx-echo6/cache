import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Gives [bytes] to the browser under [name]: a download, or with [inTab] a new tab (the browser's own PDF viewer).
void saveBytesInBrowser(String name, String mime, Uint8List bytes, {bool inTab = false}) {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..style.display = 'none';
  if (inTab) {
    a.target = '_blank';
  } else {
    a.download = name;
  }
  web.document.body!.append(a);
  a.click();
  a.remove();
  // The new tab or the download has the blob by now; free it later.
  Future<void>.delayed(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}
