import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'system_ui.dart';
import 'web_wake_lock.dart';

/// The iOS side of keeping the screen on (AppDelegate.swift): it sets UIApplication.isIdleTimerDisabled, and clears it itself
/// when the app goes to the background.
const screenAwakeChannel = MethodChannel('co.cache/screen_awake');

/// Keeps the screen from dimming and locking while [on] (Android: FLAG_KEEP_SCREEN_ON on the activity's window, through the
/// system_ui channel; iOS: the idle timer is switched off; browser: a Screen Wake Lock). Elsewhere it does nothing.
Future<void> keepScreenOn(bool on) async {
  if (kIsWeb) {
    // Checked first: a phone's browser reports an Android or iOS platform but has no native side.
    await webWakeLock.set(on);
    return;
  }
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        await systemUiChannel.invokeMethod<void>('keepScreenOn', {'on': on});
      case TargetPlatform.iOS:
        await screenAwakeChannel.invokeMethod<void>('keepScreenOn', {'on': on});
      default:
        return;
    }
  } on MissingPluginException {
    // Flutter-only tests and hosts without the native side.
  } on PlatformException {
    // The screen then follows the phone's own setting, as before.
  }
}
