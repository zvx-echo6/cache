import 'package:flutter/services.dart';

/// Whether the app may show notifications. From Android 13 that is a permission asked at run time; guidance runs as a
/// foreground service whose ongoing notification (the way back to the app with the screen locked) only shows when it is
/// granted. Other platforms and older Androids always have it.
abstract class NotificationAccess {
  /// Shows the system prompt when there is one and has not been answered; the answer is whether notifications are allowed.
  Future<bool> request();
}

class PlatformNotificationAccess implements NotificationAccess {
  static const MethodChannel _channel = MethodChannel('co.cache/network_access');

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('notifications') ?? true;
    } on MissingPluginException {
      return true;
    }
  }
}
