// CACHE PATCH (see ../../../PATCH.md): the process's one PDFium lock.
//
// PDFium is not thread-safe. pdfrx's worker isolate calls it from its own thread, and the app's core (a native library in the same
// process) calls it from others; without one lock shared by both, two calls at once corrupt PDFium's memory. The core exports the lock's
// C functions, the app hands their addresses to [PdfiumLock.functions] before pdfrx starts, and the worker holds the lock around each of
// its callbacks (the synchronous part: never across an `await`, never while a Dart callback is called).
//
// An acquisition is a token the core hands back, and it names its OWNER (a number per isolate). A killed isolate never runs its `finally`
// (the kill lands when the isolate's native call returns to Dart), so the core lets go of a dead owner's hold when told it is gone: by the
// spawner's exit listener (the worker's `onExit`), or by a NativeFinalizer attached to the owner's object, which the VM runs when the
// owner's isolate group shuts down (a destroyed Flutter engine). The core also has a minutes-long backstop.

import 'dart:ffi';
import 'dart:math';

/// The addresses of the core's lock functions: `acquire(owner) -> token`, `release(token)`, `drop_owner(owner)` and `finalize` (the
/// callback of a NativeFinalizer, whose argument is the owner's number).
typedef PdfiumLockFunctions = ({int acquire, int release, int dropOwner, int finalize});

/// Lives as long as the isolate that is an owner does; its finalizer tells the core the owner is gone.
class _OwnerLife implements Finalizable {}

/// The process's one PDFium lock.
class PdfiumLock {
  static PdfiumLockFunctions? _functions;
  static int Function(int)? _acquire;
  static void Function(int)? _release;
  static void Function(int)? _dropOwner;
  static NativeFinalizer? _finalizer;
  static int _owner = 0;
  static final List<Object> _keep = [];

  /// The addresses of the lock functions, or null (no lock: PDFium is used as before). Setting them in an isolate makes the lock
  /// usable there; the isolate takes it as an owner once it calls [become].
  static PdfiumLockFunctions? get functions => _functions;

  static set functions(PdfiumLockFunctions? value) {
    _functions = value;
    _owner = 0;
    if (value == null) {
      _acquire = _release = _dropOwner = null;
      _finalizer = null;
      return;
    }
    _acquire = Pointer<NativeFunction<Uint64 Function(Uint64)>>.fromAddress(value.acquire).asFunction<int Function(int)>();
    _release = Pointer<NativeFunction<Void Function(Uint64)>>.fromAddress(value.release).asFunction<void Function(int)>();
    _dropOwner = Pointer<NativeFunction<Void Function(Uint64)>>.fromAddress(value.dropOwner).asFunction<void Function(int)>();
    _finalizer = NativeFinalizer(Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(value.finalize));
  }

  /// A new owner number (never 0 or 1: the core's own is 1).
  static int newOwnerId() {
    final r = Random.secure();
    return ((r.nextInt(1 << 30) << 30) | r.nextInt(1 << 30)) + 2;
  }

  /// This isolate is an owner of the lock, as [owner] (or a new number). When its isolate group shuts down the VM runs a finalizer that
  /// tells the core the owner is gone. Returns the number.
  static int become([int? owner]) {
    final f = _finalizer;
    if (f == null) return 0;
    final id = owner ?? newOwnerId();
    final life = _OwnerLife();
    f.attach(life, Pointer<Void>.fromAddress(id));
    _keep.add(life);
    _owner = id;
    return id;
  }

  /// The core lets go of [owner]'s hold, if it has one: that owner's isolate is gone (the exit listener of its spawner calls this).
  static void dropOwner(int owner) => _dropOwner?.call(owner);

  /// Runs [action] with the lock held. [action] is synchronous: when it returns a Future the lock is let go at once, and whatever the
  /// Future goes on to do is not covered (so a callback must make its PDFium calls before its first `await`).
  static T hold<T>(T Function() action) {
    final acquire = _acquire, release = _release;
    if (acquire == null || release == null || _owner == 0) return action();
    final token = acquire(_owner);
    try {
      return action();
    } finally {
      release(token);
    }
  }
}
