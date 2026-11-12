import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../app_fs.dart';
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

  AppFs? _fs;
  StreamSubscription<Fix>? _sub;
  bool _foreground = true;

  /// A car screen (Android Auto) is attached ([carScreen]).
  bool _carScreen = false;

  /// Something shows the position: the phone's screen is in front, or a car screen is attached.
  bool get _shown => _foreground || _carScreen;
  bool _held = false;
  bool _disposed = false;
  bool _resuming = false;
  bool _serviceAvailable = true;
  int _resumeGeneration = 0;

  // Stream health, for telling a phone standing still (the stream sends nothing under its distance filter) from a lost signal.
  // The fix counts as held while the stream has been subscribed without error since before the fix arrived.
  bool _streamOk = false;
  DateTime? _streamSince;
  DateTime? _fixAt;
  static const Duration _defaultMaxAge = Duration(minutes: 2);

  /// True while the position stream is subscribed and healthy: no error, not cancelled (pause, hold), and the permission,
  /// the location switch and the setting still on.
  bool get streamHealthy =>
      _sub != null && _streamOk && !_disposed && enabled && _shown && !_held &&
      _serviceAvailable && permission == LocationPermissionState.granted;

  static bool _plausible(Fix? f) =>
      f != null && f.lat.isFinite && f.lon.isFinite && f.lat.abs() <= 90 && f.lon.abs() <= 180 &&
      f.accuracyM.isFinite && f.accuracyM >= 0;

  /// Whether [fix] may be used as the phone's position now: younger than [maxAge], or the stream has been healthy since it
  /// arrived (a phone standing still sends nothing new).
  bool fixIsCurrent({Duration maxAge = _defaultMaxAge}) {
    final f = fix;
    if (!_plausible(f)) return false;
    final age = DateTime.now().difference(f!.time);
    if (!age.isNegative && age <= maxAge) return true;
    final since = _streamSince, at = _fixAt;
    return streamHealthy && since != null && at != null && !at.isBefore(since) && !age.isNegative;
  }

  /// Why there is no usable position now (for the log).
  String get unknownReason {
    if (!enabled) return 'location off';
    if (permission != LocationPermissionState.granted) return 'permission off';
    if (!_serviceAvailable) return 'service off';
    if (fix == null) return 'no fix';
    return 'stale and stream down';
  }

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

  static const String _name = 'location.json';

  Future<void> init() async {
    final fs = createAppFs(supportOverride: settingsDirOverride);
    await fs.mkdir(AppRoot.support, '');
    _fs = fs;
    try {
      final text = await fs.readString(AppRoot.support, _name);
      if (text != null) {
        enabled = (jsonDecode(text) as Map)['enabled'] != false;
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
    final held = fix;
    if (held != null && f.time.isBefore(held.time)) return; // out of order: an older reading never replaces a newer one
    fix = f;
    _fixAt = DateTime.now();
    problem = null;
    onFix?.call(f);
    notifyListeners();
  }

  /// A fix from another source (navigation's own position stream) goes through the same door as the ones read here, so the map
  /// dot and the camera follow it.
  void publish(Fix f) => _publish(f);

  /// Forgets the fix held, when it was [publish]ed from a source that was not the phone's own position and that source is gone
  /// (the last point of a simulated test drive). Until a real one is read the position is not known, which is true; the stale
  /// point is not. It must be forgotten and not just replaced: a real reading may carry an older time than the simulated fix,
  /// and an older fix never replaces a newer one ([_publish]).
  void forgetPublished() {
    if (_disposed || fix == null) return;
    fix = null;
    _fixAt = null;
    onFix?.call(null);
    notifyListeners();
  }

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
        _resuming || _sub != null || !_shown || _held) {
      return;
    }
    final now = DateTime.now();
    final held = fix, at = _fixAt;
    // A fix read just before the stream started (request, resume) is held from its own arrival on.
    _streamSince = held != null && at != null && now.difference(held.time) <= _defaultMaxAge ? at : now;
    _streamOk = true;
    _sub = _source.stream().listen((f) {
      if (!_disposed && enabled && _shown && !_held) {
        if (!_streamOk) {
          _streamOk = true;
          _streamSince = DateTime.now();
        }
        _publish(f);
      }
    }, onError: (Object _) {
      _streamOk = false;
      if (_disposed || !enabled || !_shown || _held) return;
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
      _streamOk = false;
      unawaited(s?.cancel());
    } else if (enabled && permission == LocationPermissionState.granted) {
      _listen();
    }
  }

  /// A car screen (Android Auto) is attached, or the last one has gone. While one is attached the position keeps coming whether
  /// or not the phone's screen is in front: the car's map shows it, and the app can be running with no phone screen at all (its
  /// engine is kept for the life of the process, so "the phone's screen is in front" is no longer true of every car session that
  /// has no phone app open; before, such a session was always a fresh start, which counts as in front). The car session's own
  /// foreground service keeps the fixes coming with the phone locked (android/.../car/CarLocationService.kt). Nothing is
  /// asked for here: the stream starts only with the permission already given.
  void carScreen(bool attached) {
    if (_disposed || _carScreen == attached) return;
    _carScreen = attached;
    if (attached) {
      _listen();
    } else if (!_foreground) {
      _unlisten();
    }
  }

  void _unlisten() {
    _sub?.cancel();
    _sub = null;
    _streamOk = false;
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
      final fs = _fs;
      if (fs != null) await fs.writeStringAtomic(AppRoot.support, _name, jsonEncode({'enabled': enabled}));
    } catch (_) {}
  }


  /// Silent, bounded preparation for chat. Recent fixes are reused; no permission
  /// prompt or extra stream is started, including while guidance owns location.
  Future<Fix?> prepareForChat({
    required bool Function() isCancelled,
    Duration timeout = const Duration(seconds: 2),
    Duration maxAge = const Duration(minutes: 2),
  }) async {
    if (_disposed || !enabled || !_foreground || isCancelled()) return null;
    bool recent(Fix? f) {
      if (!_plausible(f)) return false;
      final age = DateTime.now().difference(f!.time);
      return !age.isNegative && age <= maxAge;
    }
    // A failed or timed-out refresh never throws the fix away: it is used while it is current, and kept (for the map) when not.
    Fix? held() => fixIsCurrent(maxAge: maxAge) ? fix : null;
    if (busy) return held();
    final generation = _resumeGeneration;
    var expired = false;
    bool valid() => !expired && !isCancelled() && _resumeIsCurrent(generation);
    Future<Fix?> read() async {
      final wasUnasked = permission == LocationPermissionState.notAsked && fix == null && problem == null;
      final access = await _source.permission();
      if (!valid()) return null;
      permission = access;
      if (access != LocationPermissionState.granted) {
        if (!(wasUnasked && access == LocationPermissionState.notAsked)) {
          _clearFix(access == LocationPermissionState.deniedForever
              ? LocationProblem.permissionBlocked : LocationProblem.permissionDenied);
        }
        return null;
      }
      final serviceOn = await _source.serviceEnabled();
      if (!valid()) return null;
      _serviceAvailable = serviceOn;
      if (!serviceOn) {
        _clearFix(LocationProblem.serviceOff);
        return null;
      }
      if (fixIsCurrent(maxAge: maxAge)) return fix;
      if (_held) return null;
      final current = await _source.current();
      if (!valid() || _held) return null;
      // A newer stream fix may have arrived during the one-shot request.
      if (fixIsCurrent(maxAge: maxAge) && !fix!.time.isBefore(current.time)) return fix;
      if (!recent(current)) return null;
      _publish(current);
      return current;
    }
    try {
      final read0 = await read().timeout(timeout, onTimeout: () {
        expired = true;
        return null;
      });
      return read0 ?? held();
    } catch (_) {
      return held(); // Location failure must never prevent an ordinary chat.
    }
  }

  bool get streamHeld => _held;

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
    // A car screen keeps the stream it has while the phone's screen is not in front.
    if (!_foreground && _carScreen) {
      _listen();
      return;
    }
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
