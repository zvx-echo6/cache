import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_wake_lock_backend.dart';

/// null when `navigator.wakeLock` is missing (old browser, or the page is not a secure context).
WakeLockBackend? createWakeLockBackend() => _BrowserWakeLock.available ? _BrowserWakeLock() : null;

class _BrowserWakeLock implements WakeLockBackend {
  static bool get available => web.window.navigator.has('wakeLock');

  @override
  Future<Object> request() async => await web.window.navigator.wakeLock.request('screen').toDart;

  @override
  Future<void> release(Object sentinel) async => await (sentinel as web.WakeLockSentinel).release().toDart;

  @override
  void Function() onVisible(void Function() callback) {
    final listener = ((web.Event _) {
      if (web.document.visibilityState == 'visible') callback();
    }).toJS;
    web.document.addEventListener('visibilitychange', listener);
    return () => web.document.removeEventListener('visibilitychange', listener);
  }
}
