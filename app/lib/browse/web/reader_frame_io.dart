import 'package:flutter/widgets.dart';

import 'reader_frame_base.dart';

/// Not a browser: the phone's reader uses a web view, so no frame is ever built here.
Widget buildZimFrame({
  Key? key,
  required String initialUrl,
  required void Function(ZimFrameHandle) onCreated,
  required void Function(String path, String title) onPage,
  required void Function(String url) onExternal,
}) =>
    const SizedBox.shrink();

/// Opens a link in a new tab (a browser only).
void openInNewTab(String url) {}
