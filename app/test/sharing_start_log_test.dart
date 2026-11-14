import 'dart:async';

import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// A timer the test fires by hand: no waiting, and it says whether it was cancelled.
class _HandTimer implements Timer {
  _HandTimer(this.after, this._run);

  final Duration after;
  final void Function() _run;
  bool cancelled = false;
  bool fired = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    _run();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  int get tick => fired ? 1 : 0;
}

void main() {
  testWidgets('a start that never finishes says so after 60 s, once, and only says it', (tester) async {
    final r = await SettingsRig.create(tester);
    final lines = <String>[];
    final timers = <_HandTimer>[];
    // Made inside runAsync (the real zone): a Completer made in the test body would live in the fake zone and never wake it.
    late final Completer<void> opening;
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      log: lines.add,
      timer: (after, run) {
        final t = _HandTimer(after, run);
        timers.add(t);
        return t;
      },
      opener: (_) {
        opening.complete();
        return Completer<SyncCoreLike>().future;
      },
    );
    await tester.runAsync(() async {
      opening = Completer<void>();
      unawaited(sharing.setUp());
      await opening.future;
    });
    expect(sharing.starting, isTrue);
    expect(lines, ['Sharing: starting']);
    expect(timers.single.after, const Duration(seconds: 60));

    timers.single.fire();
    expect(lines, ['Sharing: starting', 'Sharing: still starting after 60 s']);
    expect(sharing.starting, isTrue, reason: 'the line only logs: nothing else changes');
    expect(sharing.error, isNull);

    sharing.dispose();
    expect(timers.single.cancelled, isTrue, reason: 'disposing the state cancels it');
    await r.dispose(tester);
  });

  testWidgets('a start that finishes logs its time and cancels the 60 s line', (tester) async {
    final r = await SettingsRig.create(tester);
    final lines = <String>[];
    final timers = <_HandTimer>[];
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      log: lines.add,
      timer: (after, run) {
        final t = _HandTimer(after, run);
        timers.add(t);
        return t;
      },
      opener: (_) async => r.sync,
    );
    await tester.runAsync(sharing.setUp);
    expect(sharing.running, isTrue);
    expect(timers.single.cancelled, isTrue);
    timers.single.fire();
    expect(lines.first, 'Sharing: starting');
    expect(lines.last, matches(RegExp(r'^Sharing: started in \d+\.\d s$')));
    expect(lines.where((l) => l.contains('still starting')), isEmpty);
    // Sample of what the owner's log gets.
    // ignore: avoid_print
    print(lines.join('\n'));
    sharing.dispose();
    await r.dispose(tester);
  });

  testWidgets('a start that fails logs the kind of failure only, without the text', (tester) async {
    final r = await SettingsRig.create(tester);
    final lines = <String>[];
    final timers = <_HandTimer>[];
    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      log: lines.add,
      timer: (after, run) {
        final t = _HandTimer(after, run);
        timers.add(t);
        return t;
      },
      opener: (_) async => throw StateError('/private/path/secret'),
    );
    await tester.runAsync(sharing.setUp);
    expect(lines.last, matches(RegExp(r'^Sharing: start failed after \d+\.\d s \(StateError\)$')));
    expect(lines.join(' '), isNot(contains('/private')));
    expect(timers.single.cancelled, isTrue);
    sharing.dispose();
    await r.dispose(tester);
  });
}
