/// Why a source's last download failed, as a kind (not a sentence): what the Settings list will say about the source.
enum SourceFailure { none, keyMissing, keyRejected, unreachable, providerError, limit, unreadable, outOfArea }

/// What Settings > Weather and alerts says about one source. A "No network" notice is not a state of a row ([WeatherState.noNetwork]).
enum SourceRowState { working, updating, off, needsKey, keyRejected, notAnswering, limitReached, nothingHere }

/// What is known about one source's downloads: when it last worked, when it was last tried, and why the last try failed.
class SourceHealth {
  const SourceHealth({this.lastOkAt, this.lastAttemptAt, this.failure = SourceFailure.none, this.failureSince, this.copyCurrent = false});

  final DateTime? lastOkAt;
  final DateTime? lastAttemptAt;
  final SourceFailure failure;

  /// When the failure began: the first failed try of the current run of failures; null with no failure.
  final DateTime? failureSince;

  /// As of the last try that failed: the core still held a saved copy of this source that was not out of date. (The core gives
  /// the expiry only through a read; it is kept here so [WeatherState.statusOf] can stay synchronous.)
  final bool copyCurrent;

  Map<String, dynamic> toJson() => {
    'ok': lastOkAt?.millisecondsSinceEpoch,
    'attempt': lastAttemptAt?.millisecondsSinceEpoch,
    'failure': failure.name,
    'since': failureSince?.millisecondsSinceEpoch,
    'current': copyCurrent,
  };

  static SourceHealth? fromJson(Object? j) {
    if (j is! Map) return null;
    DateTime? t(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    final name = j['failure'];
    final failure = SourceFailure.values.where((f) => f.name == name).firstOrNull ?? SourceFailure.none;
    return SourceHealth(lastOkAt: t(j['ok']), lastAttemptAt: t(j['attempt']), failure: failure, failureSince: t(j['since']), copyCurrent: j['current'] == true);
  }
}
