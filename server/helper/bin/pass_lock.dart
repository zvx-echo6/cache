import 'dart:async';

/// One sync pass at a time. On the phone one `NotebookConnections` runs the share folder pass and every Obsidian and Logseq pass behind
/// a single guard, so they never overlap. On Linux they are two hosts (`NotebookSyncHost` for the linked devices, `FolderConnections`
/// for the folders) over the same notebooks in the core; they share one [PassLock], so a pass of one waits for the pass of the other.
/// Each host still keeps the phone's rule for its own triggers: one that arrives during a pass makes one follow-up pass.
class PassLock {
  Future<void> _tail = Future.value();
  int _active = 0;

  /// The most passes that ever held the lock at once (tests read it: always 1).
  int maxActive = 0;

  /// Runs [pass] when every pass asked before it is done; a pass that throws frees the lock for the next one.
  Future<T> run<T>(Future<T> Function() pass) {
    final done = Completer<void>();
    final before = _tail;
    _tail = done.future;
    return before.then((_) async {
      _active++;
      if (_active > maxActive) maxActive = _active;
      try {
        return await pass();
      } finally {
        _active--;
        done.complete();
      }
    });
  }
}
