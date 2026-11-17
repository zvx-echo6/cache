import 'package:flutter/foundation.dart';

import 'web_wake_lock_backend.dart';
import 'web_wake_lock_factory.dart';

export 'web_wake_lock_backend.dart' show WakeLockBackend;

/// Keeps the screen on in a browser with the Screen Wake Lock API. The browser itself drops the lock when the tab is hidden, so
/// while it should be on this asks again each time the tab comes back to the front.
///
/// The browser calls sit behind [WakeLockBackend] (null when the API is missing: an old browser, or a page that is not a secure
/// context), so the decisions here run in a plain Dart test. A refused or missing lock is logged once and otherwise ignored.
class WebWakeLock {
  WebWakeLock(this._backend, {void Function(String)? log}) : _log = log ?? debugPrint;

  final WakeLockBackend? _backend;
  final void Function(String) _log;
  bool _on = false;
  Object? _sentinel;
  void Function()? _stopListening;
  bool _logged = false;

  /// Whether a lock is held now.
  bool get held => _sentinel != null;

  Future<void> set(bool on) async {
    if (on == _on) return;
    _on = on;
    final b = _backend;
    if (b == null) {
      if (on) _note('Screen wake lock is not available in this browser.');
      return;
    }
    if (on) {
      _stopListening = b.onVisible(() {
        if (_on) _acquire(b);
      });
      await _acquire(b);
    } else {
      _stopListening?.call();
      _stopListening = null;
      await _drop(b);
    }
  }

  Future<void> _acquire(WakeLockBackend b) async {
    await _drop(b);
    try {
      final s = await b.request();
      if (!_on) {
        // Turned off while the request was out.
        await _safeRelease(b, s);
        return;
      }
      _sentinel = s;
    } catch (e) {
      _note('Screen wake lock was refused: $e');
    }
  }

  Future<void> _drop(WakeLockBackend b) async {
    final s = _sentinel;
    _sentinel = null;
    if (s != null) await _safeRelease(b, s);
  }

  Future<void> _safeRelease(WakeLockBackend b, Object s) async {
    try {
      await b.release(s);
    } catch (_) {
      // The browser may already have let it go (a hidden tab).
    }
  }

  void _note(String line) {
    if (_logged) return;
    _logged = true;
    _log(line);
  }
}

/// The one lock for this page, on web; null elsewhere.
final WebWakeLock webWakeLock = WebWakeLock(createWakeLockBackend());
