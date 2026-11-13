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

/// How long the chat model stays loaded after Ask is left, with no answer being written, before it is let go (owner, 2026-11-13:
/// 5 minutes).
const Duration kAskIdleRelease = Duration(minutes: 5);

/// Lets the chat model go once Ask has been left (another module, Home) and nothing has used the model for [idle]: it is the most
/// memory Cache holds, and only Ask uses it. Back on Ask within [idle] cancels it. An answer being written, a load or the prompt read
/// ahead ([busy]) holds it, and a new [idle] period starts after. Going to the background is [BackgroundModelRelease]'s.
///
/// The release is [release] (AppState.release): the model stays the chosen one and loads again when Ask opens; the saved prompt start
/// on disk is untouched, so the next load restores it instead of reading it again.
class AskIdleRelease {
  AskIdleRelease({required this.busy, required this.loaded, required this.release, this.idle = kAskIdleRelease});

  /// An answer is being written, a model is loading, or the prompt start is being read ahead.
  final bool Function() busy;

  /// A chat model is loaded.
  final bool Function() loaded;
  final Future<void> Function() release;
  final Duration idle;

  bool _onAsk = false;
  Timer? _timer;

  /// Whether Ask is the screen shown now.
  bool get onAsk => _onAsk;

  /// Ask is shown ([shown] true) or left (false).
  void askShown(bool shown) {
    if (shown == _onAsk) return;
    _onAsk = shown;
    _timer?.cancel();
    _timer = null;
    if (!shown) _timer = Timer(idle, _fire);
  }

  void _fire() {
    _timer = null;
    if (_onAsk || !loaded()) return;
    if (busy()) {
      // still in use: look again after another idle period
      _timer = Timer(idle, _fire);
      return;
    }
    logInfo('Chat model: released (Ask left, idle ${idle.inSeconds} s)');
    unawaited(release());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// What is let go when memory is short (Android's onTrimMemory at the levels Cache acts on, or iOS's memory warning).
enum MemoryShortRelease { chatModel, searchModel }

/// The chat model goes first: it is by far the most memory Cache holds, and only Ask uses it. When none is loaded, or it is in use
/// ([chatBusy]: an answer being written or a load), the search model goes instead.
MemoryShortRelease releaseOnMemoryShort({required bool chatLoaded, required bool chatBusy}) =>
    chatLoaded && !chatBusy ? MemoryShortRelease.chatModel : MemoryShortRelease.searchModel;
