import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'position_source.dart';

/// Why there is no position right now, for the one line shown under the coordinates.
enum LocationProblem { off, permissionDenied, permissionBlocked, serviceOff, noFix }

/// The phone's GPS position: asks for permission only when it is first needed, keeps the latest fix while
/// the app is on screen, and can be turned off in one switch.
class LocationService extends ChangeNotifier with WidgetsBindingObserver {
  LocationService({PositionSource? source, this.settingsDirOverride, this.onFix}) : _source = source ?? GeolocatorSource();

  final PositionSource _source;

  /// Called with every new fix, and with null when location is disabled or access/service is lost. The app
  /// hands it to the search core (cs_set_location, cs_clear_location).
  final void Function(Fix? fix)? onFix;

  /// Test hook.
  final Directory? settingsDirOverride;

  /// The user's switch. On by default; the system permission is still asked only on first use.
  bool enabled = true;
  Fix? fix;
  LocationProblem? problem;
  bool busy = false;
  LocationPermissionState permission = LocationPermissionState.notAsked;

  File? _file;
  StreamSubscription<Fix>? _sub;
  bool _foreground = true;
  bool _held = false;
  bool _disposed = false;
  bool _resuming = false;
  bool _serviceAvailable = true;
  int _resumeGeneration = 0;

  void _invalidateResume() {
    _resumeGeneration++;
    _resuming = false;
  }

  bool _resumeIsCurrent(int generation) =>
      !_disposed && enabled && _foreground && generation == _resumeGeneration;

  void _clearFix(LocationProblem reason) {
    _unlisten();
    fix = null;
    problem = reason;
    onFix?.call(null);
    notifyListeners();
  }

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/location.json');
    try {
      if (_file!.existsSync()) {
        enabled = (jsonDecode(_file!.readAsStringSync()) as Map)['enabled'] != false;
      }
    } catch (_) {}
    if (_disposed) return;
    WidgetsBinding.instance.addObserver(this);
    // Never asks: it only picks the position up again if the permission was already given.
    if (enabled) {
      final currentPermission = await _safe(_source.permission, LocationPermissionState.notAsked);
      if (_disposed) return;
      permission = currentPermission;
      if (permission == LocationPermissionState.granted) _listen();
    }
    notifyListeners();
  }

  Future<T> _safe<T>(Future<T> Function() f, T orElse) async {
    try {
      return await f();
    } catch (_) {
      return orElse;
    }
  }

  /// The one place a fix goes to the rest of the app: [fix], and the search core through [onFix].
  void _publish(Fix f) {
    if (_disposed || !enabled) return;
    fix = f;
    problem = null;
    onFix?.call(f);
    notifyListeners();
  }

  /// A fix from another source (navigation's own position stream) goes through the same door as the ones read here, so the map
  /// dot and the camera follow it.
  void publish(Fix f) => _publish(f);

  /// Makes sure there is a recent position, for a user who needs it now. If the permission was never asked,
  /// [explain] is shown first (a polite reason and a choice); the system prompt only follows a yes.
  /// Returns true when a position was read.
  Future<bool> request({required Future<bool> Function() explain}) async {
    if (_disposed) return false;
    if (!enabled) {
      problem = LocationProblem.off;
      notifyListeners();
      return false;
    }
    if (busy) return false;
    _invalidateResume();
    busy = true;
    notifyListeners();
    try {
      final currentPermission = await _source.permission();
      if (_disposed || !enabled) return false;
      permission = currentPermission;
      if (permission == LocationPermissionState.notAsked || permission == LocationPermissionState.denied) {
        if (!await explain() || _disposed || !enabled) return false;
        final prompted = await _source.requestPermission();
        if (_disposed || !enabled) return false;
        permission = prompted;
      }
      if (permission == LocationPermissionState.deniedForever) {
        problem = LocationProblem.permissionBlocked;
        return false;
      }
      if (permission != LocationPermissionState.granted) {
        problem = LocationProblem.permissionDenied;
        return false;
      }
      final serviceOn = await _source.serviceEnabled();
      if (_disposed || !enabled) return false;
      _serviceAvailable = serviceOn;
      if (!serviceOn) {
        problem = LocationProblem.serviceOff;
        return false;
      }
      final current = await _source.current();
      if (_disposed || !enabled) return false;
      _publish(current);
      _listen();
      return true;
    } catch (_) {
      if (!_disposed && enabled) problem = LocationProblem.noFix;
      return false;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _listen() {
    if (_disposed || !enabled || !_serviceAvailable || permission != LocationPermissionState.granted ||
        _resuming || _sub != null || !_foreground || _held) {
      return;
    }
    _sub = _source.stream().listen((f) {
      if (!_disposed && enabled && _foreground && !_held) _publish(f);
    }, onError: (Object _) {
      if (_disposed || !enabled || !_foreground || _held) return;
      problem = LocationProblem.noFix;
      notifyListeners();
    });
  }

  /// Navigation reads the position through its own service (a foreground service with a notification) while guidance runs, and
  /// the plugin shares one position stream between every listener in the app: a stream already running here would be the one
  /// guidance got, without the foreground service, and the position would stop with the screen locked. So this stream lets go
  /// while [hold] is true (and the last fix stays), and starts again when it is false.
  void holdStream(bool hold) {
    if (_disposed) return;
    _held = hold;
    if (hold) {
      // Not awaited: the plugin drops its shared stream the moment the last listener cancels, which happens inside this call, and
      // a cancel that waits on the platform would hold guidance up (and a widget test with it).
      final s = _sub;
      _sub = null;
      unawaited(s?.cancel());
    } else if (enabled && permission == LocationPermissionState.granted) {
      _listen();
    }
  }

  void _unlisten() {
    _sub?.cancel();
    _sub = null;
  }

  /// The setting: off stops reading the position and forgets the last fix.
  Future<void> setEnabled(bool on) async {
    if (_disposed) return;
    _invalidateResume();
    enabled = on;
    problem = null;
    if (!on) {
      _unlisten();
      fix = null;
      onFix?.call(null);
    } else if (permission == LocationPermissionState.granted) {
      _listen();
    }
    notifyListeners();
    try {
      await _file?.writeAsString(jsonEncode({'enabled': enabled}));
    } catch (_) {}
  }

  Future<void> openAppSettings() => _source.openAppSettings();
  Future<void> openLocationSettings() => _source.openLocationSettings();

  /// A return from system settings may change permission or the location switch.
  /// Recheck silently; guidance retains ownership of its own position stream.
  Future<void> _recoverOnResume(int generation) async {
    _resuming = true;
    _serviceAvailable = false;
    var mayListen = false;
    try {
      final wasUnasked = permission == LocationPermissionState.notAsked && fix == null && problem == null;
      final currentPermission = await _source.permission();
      if (!_resumeIsCurrent(generation)) return;
      permission = currentPermission;
      if (permission != LocationPermissionState.granted) {
        if (wasUnasked && permission == LocationPermissionState.notAsked) {
          notifyListeners();
          return;
        }
        _clearFix(permission == LocationPermissionState.deniedForever
            ? LocationProblem.permissionBlocked
            : LocationProblem.permissionDenied);
        return;
      }
      final serviceOn = await _source.serviceEnabled();
      if (!_resumeIsCurrent(generation)) return;
      if (!serviceOn) {
        _clearFix(LocationProblem.serviceOff);
        return;
      }
      _serviceAvailable = true;
      mayListen = true;
      problem = null;
      if (_held) {
        notifyListeners();
        return;
      }
      final current = await _source.current();
      if (!_resumeIsCurrent(generation) || _held) return;
      _publish(current);
    } catch (_) {
      if (!_resumeIsCurrent(generation)) return;
      // A failed fix can still recover through the stream after valid permission
      // and service checks. Failed checks must not retain a stale core position.
      _clearFix(LocationProblem.noFix);
    } finally {
      if (_resumeIsCurrent(generation)) {
        _resuming = false;
        if (mayListen) _listen();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    _invalidateResume();
    _foreground = state == AppLifecycleState.resumed;
    _unlisten();
    // A permission dialog can resume the app while request() is still awaiting its
    // answer. That request performs its own permission/service/fix sequence.
    if (_foreground && enabled && !busy) {
      unawaited(_recoverOnResume(_resumeGeneration));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateResume();
    WidgetsBinding.instance.removeObserver(this);
    _unlisten();
    super.dispose();
  }
}
