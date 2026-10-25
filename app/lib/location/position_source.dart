import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Whether the app may read the phone's position.
enum LocationPermissionState { notAsked, granted, denied, deniedForever }

/// One reading of the phone's position.
class Fix {
  const Fix({required this.lat, required this.lon, required this.accuracyM, required this.time});

  final double lat;
  final double lon;

  /// Horizontal accuracy in metres (the radius the phone is within, about 68% of the time).
  final double accuracyM;

  /// When the phone made the reading.
  final DateTime time;
}

/// The phone's position, behind a small seam so the service can be tested. The real one is geolocator.
abstract class PositionSource {
  Future<LocationPermissionState> permission();

  /// Shows the system permission prompt.
  Future<LocationPermissionState> requestPermission();

  /// False when the phone's location switch is off.
  Future<bool> serviceEnabled();

  Future<Fix> current();

  /// Fixes while the app is in use.
  Stream<Fix> stream();

  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

/// geolocator is the package the Flutter community uses for this (a Flutter Favorite, by Baseflow): it covers
/// Android and iOS, handles the permission prompt itself, and its position stream needs no background service.
class GeolocatorSource implements PositionSource {
  static LocationPermissionState _state(LocationPermission p) => switch (p) {
        LocationPermission.denied => LocationPermissionState.notAsked,
        LocationPermission.deniedForever => LocationPermissionState.deniedForever,
        LocationPermission.whileInUse || LocationPermission.always => LocationPermissionState.granted,
        LocationPermission.unableToDetermine => LocationPermissionState.denied,
      };

  static Fix _fix(Position p) => Fix(lat: p.latitude, lon: p.longitude, accuracyM: p.accuracy, time: p.timestamp);

  // Best accuracy: a survival app wants the real position, not a battery-saving guess. The stream only
  // runs while the app is on screen, and a fix is taken after the phone has moved 25 m.
  static const LocationSettings _settings = LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 25);

  @override
  Future<LocationPermissionState> permission() async => _state(await Geolocator.checkPermission());

  @override
  Future<LocationPermissionState> requestPermission() async {
    final r = await Geolocator.requestPermission();
    // "denied" after a prompt means the user said no this time.
    return r == LocationPermission.denied ? LocationPermissionState.denied : _state(r);
  }

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<Fix> current() async => _fix(await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 30)),
      ));

  @override
  Stream<Fix> stream() => Geolocator.getPositionStream(locationSettings: _settings).map(_fix);

  @override
  Future<void> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}
