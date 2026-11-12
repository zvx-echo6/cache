import 'dart:async';

import 'package:cache/weather/background.dart' show kBackgroundEvery;
import 'package:cache/weather/foreground_updates.dart';
import 'package:flutter_test/flutter_test.dart';

// 1.1 audit: with Cache left open nothing updated: no periodic update on Linux at all, none on an iPhone while Cache is in
// front. The clock here is the test's own (testWidgets): pump moves it.
void main() {
  test('Android keeps its scheduled job alone; every other platform updates by itself while in front', () {
    expect(foregroundUpdatesWanted(android: true), isFalse);
    expect(foregroundUpdatesWanted(android: false), isTrue);
  });

  testWidgets('it updates at the interval of the background schedule while in front, and not in the background', (tester) async {
    var runs = 0;
    final f = ForegroundUpdates(every: kBackgroundEvery, on: () => true, update: () async => runs++);
    addTearDown(f.dispose);
    await tester.pump(const Duration(hours: 2));
    expect(runs, 0, reason: 'not before the app is in front');
    f.front();
    expect(f.ticking, isTrue);
    await tester.pump(kBackgroundEvery - const Duration(seconds: 1));
    expect(runs, 0, reason: 'not before the interval');
    await tester.pump(const Duration(seconds: 1));
    expect(runs, 1);
    await tester.pump(kBackgroundEvery);
    expect(runs, 2);
    // in front again while it already runs: still one timer
    f.front();
    await tester.pump(kBackgroundEvery);
    expect(runs, 3);
    // the app leaves the front
    f.back();
    expect(f.ticking, isFalse);
    await tester.pump(const Duration(hours: 5));
    expect(runs, 3, reason: 'nothing in the background');
    // and comes back: the interval starts again
    f.front();
    await tester.pump(kBackgroundEvery - const Duration(seconds: 1));
    expect(runs, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(runs, 4);
    f.dispose();
    await tester.pump(const Duration(hours: 5));
    expect(runs, 4, reason: 'nothing after it is disposed');
    f.front();
    expect(f.ticking, isFalse);
  });

  testWidgets('it does nothing while nothing is switched on, and nothing at all where a scheduled job does it', (tester) async {
    var runs = 0, anythingOn = false;
    final f = ForegroundUpdates(every: kBackgroundEvery, on: () => anythingOn, update: () async => runs++);
    addTearDown(f.dispose);
    f.front();
    await tester.pump(const Duration(hours: 3));
    expect(runs, 0, reason: 'updates are off');
    anythingOn = true;
    await tester.pump(kBackgroundEvery);
    expect(runs, 1, reason: 'a source switched on is updated at the next tick');
    final android = ForegroundUpdates(every: kBackgroundEvery, on: () => true, update: () async => runs++, wanted: foregroundUpdatesWanted(android: true));
    addTearDown(android.dispose);
    android.front();
    expect(android.ticking, isFalse);
    f.back();
    await tester.pump(const Duration(hours: 3));
    expect(runs, 1);
  });

  testWidgets('never two at once: a tick that finds the last update still running does nothing', (tester) async {
    var started = 0, open = 0, most = 0;
    var gate = Completer<void>();
    final f = ForegroundUpdates(
      every: kBackgroundEvery,
      on: () => true,
      update: () async {
        started++;
        open++;
        if (open > most) most = open;
        await gate.future;
        open--;
      },
    );
    addTearDown(f.dispose);
    f.front();
    await tester.pump(kBackgroundEvery);
    expect((started, open), (1, 1));
    // the update takes longer than three more ticks
    await tester.pump(kBackgroundEvery * 3);
    expect((started, most), (1, 1), reason: 'none started beside it');
    gate.complete();
    gate = Completer<void>()..complete();
    await tester.pump(kBackgroundEvery);
    expect((started, most, open), (2, 1, 0), reason: 'the next tick after it finished runs');
    // an update that throws does not stop the ones after it
    final g = ForegroundUpdates(every: kBackgroundEvery, on: () => true, update: () async => throw StateError('no'));
    addTearDown(g.dispose);
    g.front();
    await tester.pump(kBackgroundEvery * 2);
    expect(g.ticking, isTrue);
    f.dispose();
    g.dispose();
  });
}
