import 'dart:async';
import 'dart:io';

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

  testWidgets('the engine\'s step lines are taken every second while the start runs, and once more when it ends, in order', (tester) async {
    final r = await SettingsRig.create(tester);
    final lines = <String>[];
    final timers = <_HandTimer>[];
    final every = <_HandTimer>[];
    // what the engine has said and nobody has taken (the real one is Rust's buffer, cs_sync_take_log)
    final said = <String>['sync open: started +0 ms'];
    List<String> take() {
      final out = [...said];
      said.clear();
      return out;
    }

    late final Completer<void> opening;
    late final Completer<SyncCoreLike> open;
    late Future<void> setup;
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
      drainLog: take,
      every: (d, run) {
        final t = _HandTimer(d, run);
        every.add(t);
        return t;
      },
      opener: (_) {
        opening.complete();
        return open.future;
      },
    );
    await tester.runAsync(() async {
      opening = Completer<void>();
      open = Completer<SyncCoreLike>();
      setup = sharing.setUp();
      await opening.future;
    });
    expect(sharing.starting, isTrue);
    expect(every.single.after, const Duration(seconds: 1));
    // the open is still running in the engine: the 1 s drain shows its last step, so a hang names where it stopped
    every.single.fire();
    expect(lines, ['Sharing: starting', 'sync open: started +0 ms']);
    said.add('sync open: links loaded +4 ms');
    said.add('sync open: identity loaded +9 ms');
    await tester.runAsync(() async {
      open.complete(r.sync);
      await setup;
    });
    // the end takes what is left, in order, and the drain timer is stopped
    expect(lines.where((l) => l.startsWith('sync open')), ['sync open: started +0 ms', 'sync open: links loaded +4 ms', 'sync open: identity loaded +9 ms']);
    expect(every.single.cancelled, isTrue);
    sharing.dispose();
    await r.dispose(tester);
  });

  testWidgets('a status refresh takes what the engine has said since (a link dropped by the other device) into the log, once', (tester) async {
    final r = await SettingsRig.create(tester);
    final lines = <String>[];
    final said = <String>[];
    List<String> take() {
      final out = [...said];
      said.clear();
      return out;
    }

    final sharing = SharingState(
      policy: r.policy,
      supportDir: () async => r.dir,
      kinds: const [],
      log: lines.add,
      drainLog: take,
      every: (d, run) => _HandTimer(d, run),
      opener: (_) async => r.sync,
    );
    await tester.runAsync(sharing.setUp);
    lines.clear();
    // a round in the engine dropped a link: the line is in the engine's buffer, and the next refresh takes it
    said.add('Desk unlinked this device');
    await tester.runAsync(sharing.refresh);
    expect(lines, ['Desk unlinked this device']);
    await tester.runAsync(sharing.refresh);
    expect(lines, ['Desk unlinked this device'], reason: 'taken once; a refresh with nothing said adds nothing');
    sharing.dispose();
    await r.dispose(tester);
  });

  test('no callback from the engine into Dart remains: nothing registers one, the lines are asked for', () {
    for (final f in [
      File('lib/main.dart'),
      File('lib/sharing/sharing_state.dart'),
      File('../packages/cache_search/lib/src/sync_core_io.dart'),
      File('../packages/cache_search/native/include/cache_search.h'),
      File('../packages/cache_search/native/cache_search/src/ffi.rs'),
      File('../packages/cache_search/native/cache_sync/src/lib.rs'),
    ]) {
      final t = f.readAsStringSync();
      expect(t, isNot(contains('cs_sync_set_log')), reason: f.path);
      expect(t, isNot(contains('NativeCallable')), reason: f.path);
      expect(t, isNot(contains('SyncCore.setLog')), reason: f.path);
    }
    expect(File('../packages/cache_search/lib/src/sync_core_io.dart').readAsStringSync(), contains('cs_sync_take_log'));
  });
}
