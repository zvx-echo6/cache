import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/data_policy.dart';
import '../settings/hub.dart' show UrlOpener, openInSystemBrowser;

/// What opening a web link uses: the connection check (the app's own, [ConnectivityProbe]), the phone's browser and the
/// clipboard. Tests replace them.
class WebLinks {
  static ConnectionProbe probe = ConnectivityProbe();
  static UrlOpener open = openInSystemBrowser;
  static Future<void> Function(String text) copy = (t) => Clipboard.setData(ClipboardData(text: t));
}

/// Whether [url] is a web address (http or https): the only links this opens.
bool isWebLink(Uri url) => url.scheme == 'http' || url.scheme == 'https';

/// Whether the phone has no connection right now.
Future<bool> isOffline() async => await WebLinks.probe.current() == ConnectionKind.none;

/// WORDING (for cache-pm): said when a web link is tapped with no connection.
const String kOfflineLinkMessage = "You're offline";

/// Opens a web link the person tapped (in a book, a ZIM page): in the phone's browser when there is a connection; offline it says
/// "You're offline" with "Copy link", in place (a snackbar: no new screen).
Future<void> openWebLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (await isOffline()) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('offline-link'),
        content: const Text(kOfflineLinkMessage),
        action: SnackBarAction(label: 'Copy link', onPressed: () => WebLinks.copy(url)),
      ));
    return;
  }
  try {
    await WebLinks.open(url);
  } catch (_) {}
}
