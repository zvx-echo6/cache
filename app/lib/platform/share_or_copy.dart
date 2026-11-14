import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'share_check_stub.dart' if (dart.library.js_interop) 'share_check_web.dart' as check;

/// Whether this platform has a share sheet: always on a phone; in a browser only with navigator.share, which most Linux desktop
/// browsers lack. Replaced in tests.
bool Function() systemShareAvailable = check.systemShareAvailable;

/// Shares [text] through [share] (the share sheet) when there is one; otherwise copies it and says [copied] ("Link copied"), so
/// a Share button never does nothing.
Future<void> shareOrCopy(BuildContext context, String text, {required Future<void> Function(String text) share, required String copied}) async {
  if (systemShareAvailable()) {
    await share(text);
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(copied)));
}

/// A text (a conversation, a report) shared with its title, or copied with "Copied" where there is no share sheet.
Future<void> shareTextOrCopy(BuildContext context, String title, String text, Future<void> Function(String title, String text) share) =>
    shareOrCopy(context, text, share: (t) => share(title, t), copied: 'Copied');
