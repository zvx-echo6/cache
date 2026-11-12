/// Android's ApplicationExitInfo reasons (API level 30 and later) that say the system or the person ended Cache on purpose, not
/// a crash. The numbers and meanings are from the Android reference for ApplicationExitInfo:
///   8 PERMISSION_CHANGE: killed for a runtime permission change;
///   10 USER_REQUESTED: force stop, or swiped from Recents (before Android 14 an app update was reported as this too);
///   11 USER_STOPPED: the user it ran as was stopped;
///   13 OTHER: killed for reasons "not by problems in apps", for example the system just finished updates;
///   15 PACKAGE_STATE_CHANGE: the app or a component was disabled or changed without DONT_KILL_APP (API 34);
///   16 PACKAGE_UPDATED: the app was updated (API 34).
/// Crashes (4, 5), not responding (6), low memory (3), signals (2), excessive resource use (9) and the rest stay reported.
const Set<int> kBenignExitReasons = {8, 10, 11, 13, 15, 16};

/// Whether an exit [reason] code (ApplicationExitInfo.getReason) is one the system or the person chose.
bool isBenignExitReason(int? reason) => reason != null && kBenignExitReasons.contains(reason);

/// Whether the "running" mark left from the last run means Cache stopped unexpectedly. The mark's time is when Cache was last in
/// front; [exits] are the system's records of the app's process ending (`time` in ms since the epoch, `code` the
/// reason). The first record at or after the mark says why that run ended: a benign one (an update, the user stopping it) is not
/// unexpected. With no such record, or on an Android without them, a mark left behind is unexpected, as before.
bool stoppedUnexpectedly(DateTime? marked, List<Map<Object?, Object?>> exits) {
  if (marked == null) return true;
  final from = marked.millisecondsSinceEpoch;
  Map<Object?, Object?>? ended;
  var endedAt = 0;
  for (final e in exits) {
    final t = (e['time'] as num?)?.toInt() ?? 0;
    if (t < from) continue;
    // the first death after the mark, whatever the order of the list
    if (ended == null || t < endedAt) {
      ended = e;
      endedAt = t;
    }
  }
  if (ended == null) return true;
  return !isBenignExitReason((ended['code'] as num?)?.toInt());
}
