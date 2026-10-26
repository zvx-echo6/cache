import 'package:flutter/services.dart';

/// Whether the app may show notifications, requested through each platform's native permission flow.
/// Android guidance uses an ongoing foreground-service notification; iOS uses its system notification authorization.
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
