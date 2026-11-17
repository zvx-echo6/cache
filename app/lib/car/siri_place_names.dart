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

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  bool _again = false;
  bool _gone = false;
  StreamSubscription<Object?>? _sub;
  List<String>? _last;

  /// Sends the names now, then again after each change. Call once.
  void start() {
    if (_started) return;
    _started = true;
    for (final c in changes) {
      c.addListener(_onChange);
    }
    _sub = events?.listen((_) => _onChange());
    unawaited(_send());
  }

  void dispose() {
    _gone = true;
    _timer?.cancel();
    unawaited(_sub?.cancel());
    if (!_started) return;
    for (final c in changes) {
      c.removeListener(_onChange);
    }
  }

  /// A change: read after [delay], and one read for however many changes came in that time.
  void _onChange() {
    if (_gone || (_timer?.isActive ?? false)) return;
    _timer = Timer(delay, () => unawaited(_send()));
  }

  Future<void> _send() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        final names = await read();
        if (_gone) return;
        if (_last != null && listEquals(_last, names)) continue;
        // The iPhone side keeps at most the first 100 different names and gives Siri them only when they differ from the ones
        // it has (CarVoiceSaved).
        await _channel.invokeMethod<void>('siriPlaces', {'names': names});
        _last = names;
      } while (_again && !_gone);
    } catch (_) {
      // The places could not be read yet, or this build has no iPhone side for it: the next change tries again.
    } finally {
      _running = false;
    }
  }
}
