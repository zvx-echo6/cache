import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const systemUiChannel = MethodChannel('co.cache/system_ui');
bool _themeHidesStatus = false;

/// Theme policy is restored after a fullscreen viewer closes.
Future<void> setSystemBarTheme({required bool hideStatusBar}) {
  _themeHidesStatus = hideStatusBar;
  return setSystemBars();
}

/// Android navigation stays hidden, with swipe-to-reveal handled by the OS.
/// iOS keeps its existing status-bar behavior.
Future<void> setSystemBars({bool? hideStatusBar}) async {
  final hideStatus = hideStatusBar ?? _themeHidesStatus;
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await systemUiChannel.invokeMethod<void>('apply', {
        'hideStatusBar': hideStatus,
      });
      return;
    } on MissingPluginException {
      // Flutter-only tests and older hosts without the native bridge.
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: hideStatus ? const [] : const [SystemUiOverlay.top],
      );
      return;
    }
  }
  await SystemChrome.setEnabledSystemUIMode(
    hideStatus ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
  );
}
