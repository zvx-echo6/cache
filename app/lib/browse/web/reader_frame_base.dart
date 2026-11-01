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
