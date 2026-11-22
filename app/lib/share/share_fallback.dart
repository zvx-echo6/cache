import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Starts a browser download of [text] as [fileName]. The browser build sets it; until then a download does nothing.
void Function(String fileName, String text) startWebDownload = (_, _) {};

/// What the browser says when a download or a copy starts (the page cannot see whether the browser kept the file).
const String kDownloadStarted = 'Download started';
const String kCopied = 'Copied';

/// Where the phone would show the system share sheet and the browser cannot: a small dialog to copy the text or save it as a file.
/// [title] is the thing shared ("Share chat", "Share reports"), [blurb] says what is taken. With [clipboardBlocked] (a page that is
/// not on a secure address) Copy is replaced by the text itself, to select and copy by hand.
Future<void> showShareFallback(
  BuildContext context, {
  required String title,
  required String blurb,
  required String text,
  required String fileName,
  bool clipboardBlocked = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  void say(String s) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(s)));
  }

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('share-fallback'),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(blurb),
          if (clipboardBlocked) ...[
            const SizedBox(height: 12),
            Text('Your browser blocks copying here. Select the text and copy it yourself.', style: TextStyle(fontSize: 13, color: ctx.t.secondary)),
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('share-text'),
              constraints: const BoxConstraints(maxHeight: 140),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(border: Border.all(color: ctx.t.secondary.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(8)),
              child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 13, fontFamily: 'monospace'))),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('share-save'),
          onPressed: () {
            startWebDownload(fileName, text);
            Navigator.pop(ctx);
            say(kDownloadStarted);
          },
          child: const Text('Save as file'),
        ),
        if (!clipboardBlocked)
          FilledButton(
            key: const ValueKey('share-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              say(kCopied);
            },
            child: const Text('Copy'),
          ),
      ],
    ),
  );
}
