import 'dart:async';

import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_throttle.dart';
import 'package:cache/settings/space.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;

class _Run implements IndexRun {
  final Completer<bool> _done = Completer<bool>();
  int pauses = 0;
  final List<IndexDuty> duties = [];

  @override
  void setDuty(IndexDuty duty) => duties.add(duty);

  @override
  Future<bool> get finished => _done.future;

  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    pauses++;
    if (!_done.isCompleted) _done.complete(false);
  }

  void finish() => _done.complete(true);
}

/// Work as a source lists it: what is pending, and every start (a new run each time, as a resumed job).
class _Work implements IndexWorkSource {
  final Map<String, IndexTask> tasks = {};
  final List<String> started = [];
  final Map<String, _Run> runs = {};

  void add(String key, {int size = 0, int uses = 0, bool long = true, int bytes = 0}) => tasks[key] = IndexTask(
        key: key,
        size: size,
        uses: uses,
        long: long,
        bytesNeeded: bytes,
        start: () async {
          started.add(key);
          return runs[key] = _Run();
        },
      );

  /// The work is done: its run ends and it is no longer listed.
  void finish(String key) {
    tasks.remove(key);
    runs[key]!.finish();
  }

  @override
  Future<List<IndexTask>> pending() async => tasks.values.toList();
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Work work;
  late BatteryReading? battery;
  late Space space;
  late IndexScheduler s;

  setUp(() {
    work = _Work();
    battery = const BatteryReading(percent: 80, charging: false);
    space = const Space(free: 100 * _gb, reserve: 20 * _gb);
    s = IndexScheduler(sources: [work], space: () => space, battery: () async => battery, every: const Duration(hours: 1));
  });
  tearDown(() => s.dispose());

  test('nothing runs while the app is closed; open, one piece at a time, the most used first, then the smallest', () async {
    work
      ..add('zim/big', size: 900, uses: 5)
      ..add('zim/small', size: 10, uses: 5)
      ..add('library/rare', size: 1, uses: 0);
    await s.kick();
    expect(work.started, isEmpty);
    expect(s.wait, IndexWait.closed);
    s.setOpen(true);
    await _settle();
    expect(work.started, ['zim/small']);
    expect(s.line, 'Getting search ready: 0 of 3');
    work.finish('zim/small');
    await _settle();
    expect(work.started, ['zim/small', 'zim/big']);
    expect(s.line, 'Getting search ready: 1 of 3');
    work.finish('zim/big');
    await _settle();
    work.finish('library/rare');
    await _settle();
    expect(work.started, ['zim/small', 'zim/big', 'library/rare']);
    expect(s.line, isNull, reason: 'the line goes when everything is done');
  });

  test('long work waits for charging or more than half a battery; a seal (short) does not', () async {
    battery = const BatteryReading(percent: 50, charging: false);
    work.add('zim/a', long: true);
    s.setOpen(true);
    await _settle();
    expect(work.started, isEmpty);
    expect(s.wait, IndexWait.charging);
    expect(s.line, 'Getting search ready: 0 of 1 · waits for charging');
    work.add('library/sealme', long: false);
    await s.kick();
    expect(work.started, ['library/sealme']);
    work.finish('library/sealme');
    await _settle();
    battery = const BatteryReading(percent: 50, charging: true);
    await s.kick();
    expect(work.started, ['library/sealme', 'zim/a']);
  });

  test('a low battery pauses the running work, which resumes once charging', () async {
    work.add('zim/a');
    s.setOpen(true);
    await _settle();
    expect(s.running, 'zim/a');
    battery = const BatteryReading(percent: 40, charging: false);
    await s.kick();
    expect(s.running, 'zim/a', reason: 'running long work goes on until the battery is low');
    battery = const BatteryReading(percent: 15, charging: false);
    await s.kick();
    expect(work.runs['zim/a']!.pauses, 1);
    expect(s.running, isNull);
    expect(s.line, 'Getting search ready: 0 of 1 · paused, battery low');
    battery = const BatteryReading(percent: 15, charging: true);
    await s.kick();
    expect(work.started, ['zim/a', 'zim/a'], reason: 'started again (the job resumes from what it kept)');
  });

  test('work that needs more room than the device has beyond the reserve waits', () async {
    space = const Space(free: 21 * _gb, reserve: 20 * _gb);
    work.add('zim/a', bytes: 2 * _gb);
    s.setOpen(true);
    await _settle();
    expect(work.started, isEmpty);
    expect(s.wait, IndexWait.storage);
    expect(s.line, 'Getting search ready: 0 of 1 · paused, not enough space');
    space = const Space(free: 30 * _gb, reserve: 20 * _gb);
    await s.kick();
    expect(work.started, ['zim/a']);
  });

  test('a device with no battery to read (a desktop) runs work', () async {
    battery = null;
    work.add('zim/a');
    s.setOpen(true);
    await _settle();
    expect(work.started, ['zim/a']);
  });

  test('work whose snapshot came from a linked device is skipped and counts as done', () async {
    battery = const BatteryReading(percent: 30, charging: false);
    work
      ..add('zim/a')
      ..add('zim/b');
    s.setOpen(true);
    await _settle();
    expect(s.line, 'Getting search ready: 0 of 2 · waits for charging');
    // zim/a's snapshot arrived by sync: the source no longer lists it.
    work.tasks.remove('zim/a');
    await s.kick();
    expect(work.started, isEmpty);
    expect(s.line, 'Getting search ready: 1 of 2 · waits for charging');
  });

  test('the app going to the back pauses the work; back to the front, it goes on', () async {
    work.add('zim/a');
    s.setOpen(true);
    await _settle();
    s.setOpen(false);
    await _settle();
    expect(work.runs['zim/a']!.pauses, 1);
    expect(s.running, isNull);
    s.setOpen(true);
    await _settle();
    expect(work.started, ['zim/a', 'zim/a']);
  });

  test("the core's work: a build is long, a seal short, keyed by kind and source", () async {
    final calls = _FakeCalls()
      ..list = const [
        CoreIndexNeed(kind: 'zim', sourceId: 'u1', seal: false, size: 5, uses: 2),
        CoreIndexNeed(kind: 'library', sourceId: 'lib@2', seal: true),
      ];
    final tasks = await CoreIndexWork(calls).pending();
    expect([for (final t in tasks) t.key], ['zim/u1', 'library/lib@2']);
    expect([for (final t in tasks) t.long], [true, false]);
    await tasks.first.start();
    expect(calls.started.single.sourceId, 'u1');
    // This core has neither call yet: nothing is listed.
    expect(await CoreIndexWork(IndexCoreCalls.none).pending(), isEmpty);
  });
}

class _FakeCalls implements IndexCoreCalls {
  List<CoreIndexNeed> list = const [];
  final List<CoreIndexNeed> started = [];

  @override
  Future<List<CoreIndexNeed>> needs() async => list;

  @override
  Future<IndexRun> start(CoreIndexNeed need) async {
    started.add(need);
    return _Run();
  }
}
