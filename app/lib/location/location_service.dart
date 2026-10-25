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
  LocationService({PositionSource? source, this.settingsDirOverride}) : _source = source ?? GeolocatorSource();

  final PositionSource _source;

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

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/location.json');
    try {
      if (_file!.existsSync()) {
        enabled = (jsonDecode(_file!.readAsStringSync()) as Map)['enabled'] != false;
      }
    } catch (_) {}
    WidgetsBinding.instance.addObserver(this);
    // Never asks: it only picks the position up again if the permission was already given.
    if (enabled) {
      permission = await _safe(_source.permission, LocationPermissionState.notAsked);
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

  /// The one place a fix goes to the rest of the app. TODO(tool-framework): call cs_set_location here when the
  /// core has it; until then the fix lives in [fix] only.
  void _publish(Fix f) {
    fix = f;
    problem = null;
    notifyListeners();
  }

  /// Makes sure there is a recent position, for a user who needs it now. If the permission was never asked,
  /// [explain] is shown first (a polite reason and a choice); the system prompt only follows a yes.
  /// Returns true when a position was read.
  Future<bool> request({required Future<bool> Function() explain}) async {
    if (!enabled) {
      problem = LocationProblem.off;
      notifyListeners();
      return false;
    }
    if (busy) return false;
    busy = true;
    notifyListeners();
    try {
      permission = await _source.permission();
      if (permission == LocationPermissionState.notAsked || permission == LocationPermissionState.denied) {
        if (!await explain()) return false;
        permission = await _source.requestPermission();
      }
      if (permission == LocationPermissionState.deniedForever) {
        problem = LocationProblem.permissionBlocked;
        return false;
      }
      if (permission != LocationPermissionState.granted) {
        problem = LocationProblem.permissionDenied;
        return false;
      }
      if (!await _source.serviceEnabled()) {
        problem = LocationProblem.serviceOff;
        return false;
      }
      _publish(await _source.current());
      _listen();
      return true;
    } catch (_) {
      problem = LocationProblem.noFix;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _listen() {
    if (_sub != null || !_foreground) return;
    _sub = _source.stream().listen(_publish, onError: (Object _) {
      problem = LocationProblem.noFix;
      notifyListeners();
    });
  }

  void _unlisten() {
    _sub?.cancel();
    _sub = null;
  }

  /// The setting: off stops reading the position and forgets the last fix.
  Future<void> setEnabled(bool on) async {
    enabled = on;
    problem = null;
    if (!on) {
      _unlisten();
      fix = null;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _unlisten();
    } else if (enabled && permission == LocationPermissionState.granted) {
      _listen();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlisten();
    super.dispose();
  }
}
