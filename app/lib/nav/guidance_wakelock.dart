import 'dart:async';

import 'package:flutter/widgets.dart';

import '../platform/screen_awake.dart';
import 'nav_state.dart';

/// Keeps the screen on while turn-by-turn guidance runs, so it does not dim on the dashboard. It is let go the moment guidance
/// ends, the destination is reached, or the app leaves the screen, and taken again when the app comes back mid-route.
class GuidanceWakeLock {
  GuidanceWakeLock(this.nav, {Future<void> Function(bool on)? setKeepOn}) : _set = setKeepOn ?? keepScreenOn {
    nav.addListener(_update);
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      // Inactive is a passing state (a call banner, the notification shade): the app is still on the screen.
      _onScreen = s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
      _update();
    });
    _update();
  }

  final NavState nav;
  final Future<void> Function(bool on) _set;
  late final AppLifecycleListener _lifecycle;
  bool _onScreen = true;
  bool _held = false;

  /// Whether the screen is being kept on now.
  bool get held => _held;

  void _update() {
    final want = _onScreen && nav.guiding && !nav.arrived;
    if (want == _held) return;
    _held = want;
    unawaited(_set(want));
  }

  void dispose() {
    nav.removeListener(_update);
    _lifecycle.dispose();
    if (_held) {
      _held = false;
      unawaited(_set(false));
    }
  }
}
