import 'package:geolocator/geolocator.dart';

/// How far the person has let Cache use the phone's position.
enum LocationAccess {
  /// Allowed all the time, so alerts and updates can work in the background.
  always,

  /// Allowed while Cache is open.
  whileUsing,

  /// Not allowed (never asked, or said no this time): asking again shows the system prompt.
  denied,

  /// Refused for good: only the phone's settings can change it.
  blocked,
}

/// Reads the real permission, behind a seam for tests. (LocationService does the asking; this tells "always" from "while using",
/// which it does not.)
abstract class LocationAccessProbe {
  Future<LocationAccess> read();
}

class GeolocatorAccessProbe implements LocationAccessProbe {
  @override
  Future<LocationAccess> read() async {
    try {
      return switch (await Geolocator.checkPermission()) {
        LocationPermission.always => LocationAccess.always,
        LocationPermission.whileInUse => LocationAccess.whileUsing,
        LocationPermission.deniedForever => LocationAccess.blocked,
        _ => LocationAccess.denied,
      };
    } catch (_) {
      return LocationAccess.denied;
    }
  }
}
