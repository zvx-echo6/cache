import 'package:flutter/foundation.dart';

/// True while the phone's drive screen is actually showing to a person: a car screen is connected and guiding, the phone is
/// unlocked with Cache in front, the Maps tab is selected and the drive screen is what is on it. It reaches the car as
/// `overlay: {phoneDrive: ..}` ([carOverlaySwitches]), at once on every change.
///
/// The Maps screen writes it. Until that screen exists (this first step) nothing does, so it stays false.
class PhoneDriveSignal extends ValueNotifier<bool> {
  PhoneDriveSignal() : super(false);
}
