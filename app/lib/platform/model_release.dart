import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// How long Cache stays in the background, with no answer being written, before the chat model is let go.
const Duration kBackgroundReleaseGrace = Duration(seconds: 30);

/// Lets the chat model go from memory when Cache has been in the background and idle for [grace]. Android 14 and later no longer
/// tell apps their memory runs low, so going to the back is the signal Cache acts on.
///
/// Back in front within the grace period cancels the release. An answer being written holds it; when the answer ends and Cache is
/// still in the back, a new grace period starts. The release is [release] (AppState.release), so things are left exactly as a trim
/// release leaves them: the next question loads the model through the normal path, and the saved prompt prefix on disk is untouched.
class BackgroundModelRelease {
  BackgroundModelRelease({
    required this.busy,
    required this.loaded,
    required this.release,
    Listenable? changes,
    this.grace = kBackgroundReleaseGrace,
  }) {
    _changes = changes;
    changes?.addListener(_onChange);
  }

  /// An answer is being written.
  final bool Function() busy;

  /// A chat model is loaded.
  final bool Function() loaded;
  final Future<void> Function() release;
  final Duration grace;
  Listenable? _changes;

  bool _background = false;
  bool _heldByAnswer = false;
  bool _wasBusy = false;
  Timer? _timer;

  /// Cache went to the background (lifecycle hidden or paused, or onTrimMemory UI_HIDDEN or beyond).
  void toBackground() {
    if (_background) return;
    _background = true;
    _wasBusy = busy();
    _arm();
  }

  /// Cache is back in front.
  void toFront() {
    _background = false;
    final pending = _timer != null || _heldByAnswer;
    _timer?.cancel();
    _timer = null;
    _heldByAnswer = false;
    if (pending) logInfo('Chat model: release cancelled (back in front)');
  }

  void _arm() {
    _timer?.cancel();
    _heldByAnswer = false;
    _timer = Timer(grace, _fire);
  }

  void _fire() {
    _timer = null;
    if (!_background || !loaded()) return;
    if (busy()) {
      _heldByAnswer = true;
      _wasBusy = true;
      return;
    }
    logInfo('Chat model: released (background, idle ${grace.inSeconds} s)');
    unawaited(release());
  }

  /// An answer that ends while Cache is in the back starts a new grace period.
  void _onChange() {
    final b = busy();
    if (_background && _wasBusy && !b) _arm();
    _wasBusy = b;
  }

  void dispose() {
    _timer?.cancel();
    _changes?.removeListener(_onChange);
  }
}
