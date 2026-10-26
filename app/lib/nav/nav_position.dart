import 'dart:async';
import 'dart:io';

import 'package:geolocator/geolocator.dart';

import '../location/position_source.dart';

/// The position stream guidance runs on: one fix a second, kept running with the screen locked. On Android that is
/// geolocator's foreground service, which shows an ongoing notification for as long as it runs; it stops when the stream is
/// cancelled. On iOS it is background location updates (the app needs the "location" background mode).
abstract class NavPositionSource {
  /// Starts the service and gives its fixes. [title] and [text] are the notification (Android).
  Stream<Fix> start({required String title, required String text});

  /// Stops the service.
  Future<void> stop();
}

class GeolocatorNavSource implements NavPositionSource {
  /// [positions] makes the plugin's position stream; tests give their own.
  GeolocatorNavSource({Stream<Position> Function(LocationSettings settings)? positions})
      : _positions = positions ?? ((s) => Geolocator.getPositionStream(locationSettings: s));

  final Stream<Position> Function(LocationSettings settings) _positions;
  StreamController<Fix>? _out;
  StreamSubscription<Position>? _sub;

  static Fix _fix(Position p) => Fix(
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: p.accuracy,
        time: p.timestamp,
        heading: p.speed > 0.7 && p.heading >= 0 && p.heading <= 360 ? p.heading : null,
      );

  @override
  Stream<Fix> start({required String title, required String text}) {
    // Let go of the old stream first and without waiting: stop() is asynchronous, and if it ran after this method had made the
    // new stream it would cancel and close the new one instead, leaving the position service running with nobody listening.
    final old = (_sub, _out);
    _sub = null;
    _out = null;
    unawaited(_release(old.$1, old.$2));
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: title,
              notificationText: text,
              notificationChannelName: 'Navigation',
              notificationIcon: AndroidResource(name: 'ic_stat_cache', defType: 'drawable'),
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : Platform.isIOS
            ? AppleSettings(
                accuracy: LocationAccuracy.bestForNavigation,
                activityType: ActivityType.automotiveNavigation,
                distanceFilter: 0,
                pauseLocationUpdatesAutomatically: false,
                showBackgroundLocationIndicator: true,
                allowBackgroundLocationUpdates: true,
              )
            : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
    final out = StreamController<Fix>.broadcast();
    _out = out;
    _sub = _positions(settings).listen(
      (p) => out.add(_fix(p)),
      onError: out.addError,
    );
    return out.stream;
  }

  static Future<void> _release(StreamSubscription<Position>? sub, StreamController<Fix>? out) async {
    await sub?.cancel();
    await out?.close();
  }

  @override
  Future<void> stop() async {
    final sub = _sub, out = _out;
    _sub = null;
    _out = null;
    await _release(sub, out);
  }
}
