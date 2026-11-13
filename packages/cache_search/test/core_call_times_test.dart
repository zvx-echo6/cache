import 'dart:io';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

/// The first version call holds the worker for a while (a long library search, say); the later ones answer at once.
class _SlowFirst extends FakeNative {
  int n = 0;

  @override
  String? version() {
    if (n++ == 0) sleep(const Duration(milliseconds: 400));
    return '{"core":"1"}';
  }
}

CsNative _slowFirst() => _SlowFirst();

void main() {
  tearDown(() {
    CoreCallTimes.onSlow = null;
    CoreCallTimes.slowAfter = const Duration(seconds: 2);
  });

  test('a slow call is reported with its wait in the queue and its run; a quick one is not', () async {
    final seen = <(String, Duration, Duration)>[];
    CoreCallTimes.slowAfter = const Duration(milliseconds: 200);
    CoreCallTimes.onSlow = (op, queued, ran) => seen.add((op, queued, ran));
    final core = await SearchCore.open(const [], native: _slowFirst);
    seen.clear();
    // Two calls at once: the second waits in the queue behind the first.
    await Future.wait([core.version(), core.version()]);
    expect([for (final s in seen) s.$1], ['version', 'version']);
    final (_, firstQueued, firstRan) = seen[0];
    final (_, secondQueued, secondRan) = seen[1];
    expect(firstRan, greaterThanOrEqualTo(const Duration(milliseconds: 400)), reason: 'the first one ran long');
    expect(firstQueued, lessThan(const Duration(milliseconds: 200)), reason: 'and hardly waited');
    expect(secondQueued, greaterThanOrEqualTo(const Duration(milliseconds: 300)), reason: 'the second one waited behind it');
    expect(secondRan, lessThan(const Duration(milliseconds: 200)), reason: 'and ran quickly');
    await core.version();
    expect(seen, hasLength(2), reason: 'a quick call is not reported');
    await core.close();
  });

  test('nothing is reported without a listener or under the threshold', () {
    CoreCallTimes.answered('search', const Duration(seconds: 9), const Duration(seconds: 1));
    final seen = <String>[];
    CoreCallTimes.onSlow = (op, queued, ran) => seen.add(op);
    CoreCallTimes.answered('savedPlaces', const Duration(milliseconds: 1999), const Duration(milliseconds: 2));
    expect(seen, isEmpty);
    CoreCallTimes.answered('savedPlaces', const Duration(milliseconds: 18000), const Duration(milliseconds: 2));
    expect(seen, ['savedPlaces']);
  });

  test('the line has the call name and its times only', () {
    expect(CoreCallTimes.line('mapSearch', const Duration(milliseconds: 9000), const Duration(milliseconds: 120)),
        'Core call mapSearch: 9120 ms (9000 ms in the queue, 120 ms running)');
  });
}
