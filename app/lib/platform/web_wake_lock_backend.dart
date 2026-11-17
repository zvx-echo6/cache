/// The browser calls under [WebWakeLock], so a test can stand in for them.
abstract class WakeLockBackend {
  /// Takes the lock; throws when the browser refuses.
  Future<Object> request();

  /// Lets go of a lock [request] returned.
  Future<void> release(Object sentinel);

  /// Calls [callback] each time the tab becomes visible; the returned function stops it.
  void Function() onVisible(void Function() callback);
}
