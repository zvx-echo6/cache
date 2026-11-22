import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notebook/save_bytes.dart';
import 'share_check_stub.dart' if (dart.library.js_interop) 'share_check_web.dart' as check;

/// Whether this platform has a share sheet: always on a phone; in a browser only with navigator.share, which most Linux desktop
/// browsers lack. Replaced in tests.
bool Function() systemShareAvailable = check.systemShareAvailable;

/// Gives a file to the browser as a download. Replaced in tests (only a browser can save this way).
void Function(String name, String mime, Uint8List bytes) saveFileInBrowser = saveBytesInBrowser;

/// Shares [text] through [share] (the share sheet) when there is one; otherwise copies it and says [copied] ("Link copied"), so
/// a Share button never does nothing.
Future<void> shareOrCopy(BuildContext context, String text, {required Future<void> Function(String text) share, required String copied}) async {
  if (systemShareAvailable()) {
    await share(text);
    return;
  }
  final ok = await _copy(text);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(ok ? copied : _copyFailed)));
}

const String _copyFailed = "Couldn't copy. Use Download instead.";

/// Puts [text] on the clipboard; false when the browser refuses it.
Future<bool> _copy(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// A text (a conversation, a report) shared with its title. With no share sheet (a browser without navigator.share) a small sheet
/// offers Copy (to the clipboard, then "Copied.") and Download (the text as a Markdown file named after [title]).
Future<void> shareTextOrCopy(BuildContext context, String title, String text, Future<void> Function(String title, String text) share) async {
  if (systemShareAvailable()) {
    await share(title, text);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(key: const ValueKey('web-share-copy'), leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, 'copy')),
        ListTile(key: const ValueKey('web-share-download'), leading: const Icon(Icons.download), title: const Text('Download'), onTap: () => Navigator.pop(ctx, 'download')),
      ]),
    ),
  );
  if (choice == 'copy') {
    final ok = await _copy(text);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(ok ? 'Copied.' : _copyFailed)));
  } else if (choice == 'download') {
    saveFileInBrowser(_fileName(title), 'text/markdown', Uint8List.fromList(utf8.encode(text)));
  }
}

/// The title as a file name: letters, digits, spaces, dashes and dots stay; anything else a file name can't hold becomes "_".
String _fileName(String title) {
  final base = title.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '_').trim();
  return '${base.isEmpty ? 'Chat' : base}.md';
}
