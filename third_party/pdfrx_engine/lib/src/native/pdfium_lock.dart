// CACHE PATCH (see ../../../PATCH.md): the process's one PDFium lock.
//
// PDFium is not thread-safe. pdfrx's worker isolate calls it from its own thread, and the app's core (a native library in the same
// process) calls it from others; without one lock shared by both, two calls at once corrupt PDFium's memory. The core exports the two
// functions below (`extern "C" fn()`, reentrant: the same thread may take the lock again), the app hands their addresses to
// [PdfiumLock.functions] before pdfrx starts, and the worker holds the lock around each of its callbacks (the synchronous part: never
// across an `await`, never while a Dart callback is called).

import 'dart:ffi';

/// The process's one PDFium lock.
class PdfiumLock {
  static ({int lock, int unlock})? _functions;
  static void Function()? _lock;
  static void Function()? _unlock;

  /// The addresses of the lock and unlock functions, or null (no lock: PDFium is used as before).
  static ({int lock, int unlock})? get functions => _functions;

  static set functions(({int lock, int unlock})? value) {
    _functions = value;
    if (value == null) {
      _lock = _unlock = null;
      return;
    }
    _lock = Pointer<NativeFunction<Void Function()>>.fromAddress(value.lock).asFunction<void Function()>();
    _unlock = Pointer<NativeFunction<Void Function()>>.fromAddress(value.unlock).asFunction<void Function()>();
  }

  /// Runs [action] with the lock held. [action] is synchronous: when it returns a Future the lock is let go at once, and whatever the
  /// Future goes on to do is not covered (so a callback must make its PDFium calls before its first `await`).
  static T hold<T>(T Function() action) {
    final lock = _lock, unlock = _unlock;
    if (lock == null || unlock == null) return action();
    lock();
    try {
      return action();
    } finally {
      unlock();
    }
  }
}
