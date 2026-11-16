import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Asks the browser for permission to show notifications (once; an answer already given is kept by the browser). True when granted.
Future<bool> askBrowserNotifications() async {
  try {
    if (web.Notification.permission == 'granted') return true;
    if (web.Notification.permission == 'denied') return false;
    final answer = await web.Notification.requestPermission().toDart;
    return answer.toDart == 'granted';
  } catch (_) {
    return false;
  }
}

/// Shows one notification. [quiet] is a silent one (quiet hours); an [extreme] alert stays until it is dismissed. [tag] makes a
/// repeat of the same alert replace the first. [onTap] runs when it is clicked (the tab is brought forward first). False when the
/// browser would not show it (no permission, or no notification support).
bool showBrowserNotification({
  required String title,
  required String body,
  required String tag,
  required bool quiet,
  required bool extreme,
  required void Function() onTap,
}) {
  try {
    if (web.Notification.permission != 'granted') return false;
    final n = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: tag, silent: quiet, requireInteraction: extreme && !quiet),
    );
    n.addEventListener(
      'click',
      ((web.Event _) {
        try {
          web.window.focus();
        } catch (_) {}
        n.close();
        onTap();
      }).toJS,
    );
    return true;
  } catch (_) {
    return false;
  }
}
