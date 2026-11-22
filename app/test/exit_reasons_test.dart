import 'package:cache/platform/exit_reasons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an update, the user stopping the app and the system\'s own housekeeping are not unexpected; crashes, ANRs and kills are', () {
    for (final benign in [8, 10, 11, 13, 15, 16]) {
      expect(isBenignExitReason(benign), isTrue, reason: 'reason $benign');
    }
    // 0 unknown, 1 exit self, 2 signaled, 3 low memory, 4 crash, 5 native crash, 6 ANR, 7 initialization failure,
    // 9 excessive resource usage, 12 dependency died, 14 freezer, 17 memory limiter, 18 anomaly
    for (final real in [0, 1, 2, 3, 4, 5, 6, 7, 9, 12, 14, 17, 18]) {
      expect(isBenignExitReason(real), isFalse, reason: 'reason $real');
    }
    expect(isBenignExitReason(null), isFalse);
  });

  group('a "running" mark left from the last run', () {
    final marked = DateTime.fromMillisecondsSinceEpoch(1000000);
    Map<Object?, Object?> exit(int t, int code) => {'time': t, 'code': code};

    test('the run ended by an app update: not unexpected', () {
      expect(stoppedUnexpectedly(marked, [exit(1000500, 16)]), isFalse);
    });
    test('before Android 14 an update shows as user requested: not unexpected', () {
      expect(stoppedUnexpectedly(marked, [exit(1000500, 10)]), isFalse);
    });
    test('a crash, a native crash, an ANR or low memory: unexpected', () {
      for (final c in [4, 5, 6, 3]) {
        expect(stoppedUnexpectedly(marked, [exit(1000500, c)]), isTrue, reason: 'reason $c');
      }
    });
    test('no record after the mark (an Android without them, or none): unexpected, as before', () {
      expect(stoppedUnexpectedly(marked, const []), isTrue);
      expect(stoppedUnexpectedly(marked, [exit(500, 16)]), isTrue, reason: 'an older exit says nothing about this run');
      expect(stoppedUnexpectedly(null, [exit(1000500, 16)]), isTrue, reason: 'the mark has no time');
    });
    test('the first death after the mark decides, whatever the list order', () {
      expect(stoppedUnexpectedly(marked, [exit(2000000, 4), exit(1000500, 16)]), isFalse);
      expect(stoppedUnexpectedly(marked, [exit(1000500, 16), exit(2000000, 4)]), isFalse);
    });
  });
}
