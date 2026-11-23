import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the phone's own screen lock said (fingerprint, face or PIN, whatever the system has).
enum DeviceLockResult {
  /// The person proved it is them.
  ok,

  /// The person backed out, or could not prove it.
  cancelled,

  /// No screen lock is set (or this platform has none to ask): the plain confirm is enough.
  none,
}

/// Asks for the phone's screen lock before something that must not be done by whoever picks the phone up,
/// such as unlinking a device. Android only for now; everywhere else it answers [DeviceLockResult.none].
class DeviceLock {
  static const MethodChannel _channel = MethodChannel('co.cache/device_lock');

  static Future<DeviceLockResult> confirm({required String title, required String description}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return DeviceLockResult.none;
    try {
      final answer = await _channel.invokeMethod<String>('confirm', {'title': title, 'description': description});
      return switch (answer) {
        'ok' => DeviceLockResult.ok,
        'none' => DeviceLockResult.none,
        _ => DeviceLockResult.cancelled,
      };
    } on MissingPluginException {
      // No native side (tests, a headless engine): nothing to ask.
      return DeviceLockResult.none;
    } on PlatformException {
      return DeviceLockResult.cancelled;
    }
  }
}
