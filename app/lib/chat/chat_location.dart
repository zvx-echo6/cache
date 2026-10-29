import 'dart:async';

import 'package:flutter/foundation.dart';

import '../location/location_service.dart';
import '../location/position_source.dart';

/// Keeps the chat's location flag behind acknowledged, ordered core updates; listeners hear when [known] may have changed.
class ChatLocation extends ChangeNotifier {
  ChatLocation({required this.location, required this.synchronize});

  final LocationService location;
  final Future<bool> Function(Fix? fix) synchronize;
  Future<void> _writes = Future.value();
  int _revision = 0;
  Fix? _known;

  bool get known => location.enabled && _known != null && identical(location.fix, _known);

  /// Used by LocationService.onFix, including stream updates and location clears.
  void update(Fix? fix) {
    final revision = ++_revision;
    _known = null;
    notifyListeners();
    _writes = _writes.then((_) async {
      final synchronized = await synchronize(fix);
      if (revision == _revision) _known = synchronized ? fix : null;
      notifyListeners();
    }).catchError((Object _) {
      _known = null;
      notifyListeners();
    });
  }

  Future<void> prepare(bool Function() isCancelled) async {
    final fix = await location.prepareForChat(isCancelled: isCancelled);
    if (isCancelled()) return;
    update(fix);
    await _drain(isCancelled);
  }

  /// Waits for the core updates asked for so far, at most [timeout]; true when the chat now has the position (the same
  /// [known] the chip and the system prompt read).
  Future<bool> settled({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      await _drain(() => false).timeout(timeout);
    } on TimeoutException catch (_) {}
    return known;
  }

  /// Includes any stream update queued while an earlier core write was pending.
  Future<void> _drain(bool Function() isCancelled) async {
    Future<void> pending;
    do {
      pending = _writes;
      await pending;
    } while (!isCancelled() && !identical(pending, _writes));
  }
}
