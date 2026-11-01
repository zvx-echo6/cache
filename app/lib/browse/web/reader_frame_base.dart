import 'package:flutter/widgets.dart';

/// What the reader can ask of the frame that shows a ZIM page in a browser.
abstract class ZimFrameHandle {
  /// Shows [url] (a `/zim/<token>/...` address) in the frame.
  void load(String url);

  /// One page back or forward in the frame's own history.
  void back();
  void forward();
}

/// Builds the frame. [onPage] hears the address (`/zim/...`, path and query) and the title of the page the frame has settled on;
/// [onExternal] a link that leaves the ZIM (the reader opens it in a new tab).
typedef ZimFrameBuilder = Widget Function({
  Key? key,
  required String initialUrl,
  required void Function(ZimFrameHandle) onCreated,
  required void Function(String path, String title) onPage,
  required void Function(String url) onExternal,
});

/// A message from the reader's frame, once checked: a page report or a link that leaves the ZIM.
sealed class ZimFrameMessage {
  const ZimFrameMessage();
}

class ZimFramePage extends ZimFrameMessage {
  const ZimFramePage(this.href, this.title);
  final String href;
  final String title;
}

class ZimFrameExternal extends ZimFrameMessage {
  const ZimFrameExternal(this.url);
  final String url;
}

/// Reads a message from the frame. Anything that is not exactly a page report or an external link, with string fields, is null.
/// (The frame's page is other people's content: nothing in it is trusted.)
ZimFrameMessage? parseZimFrameMessage(Object? data) {
  if (data is! Map) return null;
  switch (data['cacheZim']) {
    case 'page':
      final href = data['href'];
      final title = data['title'];
      if (href is! String || title is! String) return null;
      return ZimFramePage(href, title);
    case 'external':
      final url = data['url'];
      if (url is! String) return null;
      return ZimFrameExternal(url);
  }
  return null;
}

/// Only web addresses and mail links may be opened from the frame.
bool isOpenableExternalUrl(String url) {
  final u = Uri.tryParse(url);
  return u != null && (u.scheme == 'https' || u.scheme == 'http' || u.scheme == 'mailto');
}
