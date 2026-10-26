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
    stop();
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: title,
              notificationText: text,
              notificationChannelName: 'Navigation',
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
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) => out.add(_fix(p)),
      onError: out.addError,
    );
    return out.stream;
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _out?.close();
    _out = null;
  }
}
