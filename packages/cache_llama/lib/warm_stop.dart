/// What a Stop does while a read ahead (cl_warm) may be running.
enum StopAction {
  /// The native stop (cl_stop): it ends whatever runs, the read ahead and the question behind it.
  stopAll,

  /// Cancel the question that joined the read, and nothing else: the read goes on to the end and saves its prefix.
  cancelQuestion,
}

/// The session's rule for Stop around a read ahead, kept apart from the native calls so it can be tested.
///
/// A Stop on a question that joined a running read cancels the question only. It is the full stop again when: Cache went to the
/// background (the read is given up then), the question was cancelled already (a second Stop), or no question joined.
class WarmStopPolicy {
  bool _warmInFlight = false;
  bool _joined = false;
  bool _background = false;
  bool _cancelled = false;

  /// A read was queued.
  void warmQueued() {
    _warmInFlight = true;
    _joined = false;
    _background = false;
    _cancelled = false;
  }

  /// The read has ended (its reply came).
  void warmEnded() {
    _warmInFlight = false;
    _joined = false;
    _background = false;
    _cancelled = false;
  }

  /// A question was queued (a new question starts with no cancel against it).
  void questionQueued() {
    if (_warmInFlight) {
      _joined = true;
      _cancelled = false;
    }
  }

  /// Cache went to the background while the read ran.
  void backgrounded() {
    if (_warmInFlight) _background = true;
  }

  /// A read is in flight and no question is waiting behind it: Cache going to the background may stop it.
  bool get canStopRead => _warmInFlight && !_joined;

  bool get warmInFlight => _warmInFlight;

  /// A question was queued behind the read in flight.
  bool get joined => _joined;

  /// The action for a Stop now (and the policy notes a question-only cancel, so the next Stop is a full one).
  StopAction onStop() {
    if (_warmInFlight && _joined && !_background && !_cancelled) {
      _cancelled = true;
      return StopAction.cancelQuestion;
    }
    return StopAction.stopAll;
  }
}
