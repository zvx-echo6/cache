import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Gives Siri the names of the saved places from the phone: whenever they change, and once when the app starts.
class SiriPlaceNames {
  SiriPlaceNames({
    required this.read,
    this.changes = const [],
    this.events,
    MethodChannel? channel,
    this.delay = const Duration(seconds: 2),
  }) : _channel = channel ?? const MethodChannel('co.cache/car');

  /// The saved places' names, in the order the car lists them.
  final Future<List<String>> Function() read;

  /// Tell when the saved places may have changed.
  final List<Listenable> changes;

  /// Also tells it, by an event (a place saved or removed from its card).
  final Stream<Object?>? events;
  final MethodChannel _channel;
  final Duration delay;

  void start() {}

  void dispose() {}
}
