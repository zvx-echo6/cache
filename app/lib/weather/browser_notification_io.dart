/// Not a browser: nothing to show with, and nothing to ask.
Future<bool> askBrowserNotifications() async => false;

/// Not a browser: nothing is shown.
bool showBrowserNotification({required String title, required String body, required String tag, required bool quiet, required bool extreme, required void Function() onTap}) => false;
