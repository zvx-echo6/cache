import 'package:share_plus/share_plus.dart';

/// Hands a conversation, as Markdown, to the phone's share sheet.
typedef ShareMarkdown = Future<void> Function(String title, String markdown);

Future<void> shareMarkdown(String title, String markdown) =>
    SharePlus.instance.share(ShareParams(text: markdown, subject: title, title: title));
