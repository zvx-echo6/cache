// The browser's notifications (the Notification API), behind the same conditional import as platform.dart: the web side is
// browser_notification_web.dart (package:web); everywhere else the names do nothing, so the code that uses them runs on a phone and in tests.
export 'browser_notification_io.dart' if (dart.library.js_interop) 'browser_notification_web.dart';
