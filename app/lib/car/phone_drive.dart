import 'package:flutter/foundation.dart';

/// True while the phone's drive screen is actually showing to a person: a car screen is connected and guiding, the phone is
/// unlocked with Cache in front, the Maps tab is selected and the drive screen is what is on it. It reaches the car as
/// `overlay: {phoneDrive: ..}` ([carOverlaySwitches]), at once on every change.
///
/// The Maps screen writes it (screens/maps_screen.dart).
class PhoneDriveSignal extends ValueNotifier<bool> {
  PhoneDriveSignal() : super(false);
}

/// Where the car carries the two extras (the route mini map and the elevation), by the class of its screen. The car sides
/// measure the class (small, in-between or big); the phone only needs to know what it means for it.
enum CarExtras {
  /// A small car screen: the car never carries them, so the phone does.
  never,

  /// An in-between car screen: the car carries them unless the phone's drive screen is showing; while it shows, the phone does.
  unlessPhoneShows,

  /// A big car screen: the car always carries them, so the phone's list of turns has the whole room.
  always,
}

/// The word the car side sends (`extras`, `{'carries': word}`) as a [CarExtras]; absent or any word not known is [CarExtras.never].
CarExtras carExtrasFrom(Object? word) => switch (word) {
      'unlessPhone' => CarExtras.unlessPhoneShows,
      'always' => CarExtras.always,
      _ => CarExtras.never,
    };

/// What the Maps screen needs to know about the car, and the one thing it tells the car. The platform sides keep these up to
/// date: [carConnected] while a car screen is attached, [extras] from the car's own measure of its screen (until a car side
/// reports it, [CarExtras.never]); the screen writes [signal].
class PhoneDrive {
  final PhoneDriveSignal signal = PhoneDriveSignal();
  final ValueNotifier<bool> carConnected = ValueNotifier<bool>(false);
  final ValueNotifier<CarExtras> extras = ValueNotifier<CarExtras>(CarExtras.never);

  void dispose() {
    signal.dispose();
    carConnected.dispose();
    extras.dispose();
  }
}
