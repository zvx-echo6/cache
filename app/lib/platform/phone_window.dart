import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the phone's own window is on the phone's screen. On an iPhone with CarPlay the app can be in use on the car screen
/// while the phone is locked in a pocket: the app as a whole is then not in the background, so nothing tells the phone's own
/// views to rest. The phone's scene says so itself (PhoneWindow in ios/Runner/SceneDelegate.swift, channel
/// `co.cache/phone_window`), and what belongs to the phone's window alone follows it: its maps stop drawing ([PhoneMapRest]).
///
/// Elsewhere (Android, desktop, tests) nothing answers on the channel and the window counts as on the screen, always.
class PhoneWindow {
  PhoneWindow({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('co.cache/phone_window');

  final MethodChannel _channel;

  /// True while the phone's window is on the phone's screen (or nothing says otherwise).
  final ValueNotifier<bool> visible = ValueNotifier(true);

  /// Listens for the phone's scene, and asks where it stands now.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && call.arguments is bool) visible.value = call.arguments as bool;
      return null;
    });
    await refresh();
  }

  /// Asks the phone's scene again (also when the app comes back to the screen: a missed message must not leave a map still).
  Future<void> refresh() async {
    try {
      final v = await _channel.invokeMethod<Object?>('get');
      if (v is bool) visible.value = v;
    } on MissingPluginException {
      // No phone scene to ask: on the screen.
    } on PlatformException {
      // The same.
    }
  }
}

/// The phone's maps rest while the phone's window is not on its screen: each map on a phone screen gives its two calls (the
/// map plugin's pauseMap and resumeMap), and they are made as the window goes and comes. A map that joins while the window is
/// away is paused at once. The car's map is not one of these: it is drawn by the car side.
class PhoneMapRest {
  PhoneMapRest(this.visible) {
    visible.addListener(_apply);
  }

  final ValueListenable<bool> visible;
  final Map<Object, ({Future<void> Function() pause, Future<void> Function() resume})> _maps = {};

  /// A map on a phone screen, from its creation. [key] is the map's own (its controller); the same key again replaces it.
  void add(Object key, {required Future<void> Function() pause, required Future<void> Function() resume}) {
    _maps[key] = (pause: pause, resume: resume);
    if (!visible.value) _quiet(pause());
  }

  /// The map is gone (its screen was closed).
  void remove(Object key) => _maps.remove(key);

  void _apply() {
    for (final m in _maps.values.toList()) {
      _quiet(visible.value ? m.resume() : m.pause());
    }
  }

  /// A map that is already gone on the native side must not break the others.
  void _quiet(Future<void> f) => f.catchError((Object _) {});

  void dispose() {
    visible.removeListener(_apply);
    _maps.clear();
  }
}

/// The app's one phone window and the maps that follow it. Started by the app on an iPhone (main.dart).
final PhoneWindow phoneWindow = PhoneWindow();
final PhoneMapRest phoneMapRest = PhoneMapRest(phoneWindow.visible);
