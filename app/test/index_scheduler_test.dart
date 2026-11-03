import 'dart:async';

import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_status.dart' show indexItemWords;
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
    expect(s.line, 'Getting search ready · 0 of 3 done');
    work.finish('zim/small');
    await _settle();
    expect(work.started, ['zim/small', 'zim/big']);
    expect(s.line, 'Getting search ready · 1 of 3 done');
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
    expect(s.line, 'Getting search ready · 0 of 1 done · Waits for charging (long job)');
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
    expect(s.line, 'Getting search ready · 0 of 1 done · Paused · battery low (15%) · plug in to continue');
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
    expect(s.line, 'Getting search ready · 0 of 1 done · Needs 2.0 GB free · Free space');
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
    expect(s.line, 'Getting search ready · 0 of 2 done · Waits for charging (long job)');
    // zim/a's snapshot arrived by sync: the source no longer lists it.
    work.tasks.remove('zim/a');
    await s.kick();
    expect(work.started, isEmpty);
    expect(s.line, 'Getting search ready · 1 of 2 done · Waits for charging (long job)');
  });

  test('work listed again after it was done counts as not done (the count matches the rows)', () async {
    battery = const BatteryReading(percent: 30, charging: false);
    work
      ..add('zim/a')
      ..add('zim/b')
      ..add('zim/c');
    s.setOpen(true);
    await _settle();
    work.tasks.remove('zim/a');
    await s.kick();
    expect(s.line, startsWith('Getting search ready · 1 of 3 done'));
    // zim/a got more to index (a new file in the library): it is listed again
    work.add('zim/a');
    await s.kick();
    expect(s.line, startsWith('Getting search ready · 0 of 3 done'));
    expect(s.statusOf('zim/a')?.state, isNot(IndexState.done));
  });

  test('work with no progress for the stuck time is stopped and skipped; the next runs; Retry tries it again', () async {
    var now = DateTime(2026, 11, 3);
    final s = IndexScheduler(
      sources: [work],
      space: () => space,
      battery: () async => const BatteryReading(percent: 80, charging: true),
      every: const Duration(hours: 1),
      stuckAfter: const Duration(minutes: 5),
      watchEvery: const Duration(milliseconds: 10),
      clock: () => now,
    );
    addTearDown(s.dispose);
    var read = 0;
    work.tasks['zim-captions/nhs'] = IndexTask(
      key: 'zim-captions/nhs',
      size: 1,
      progress: () => (read, 12),
      start: () async {
        work.started.add('zim-captions/nhs');
        return work.runs['zim-captions/nhs'] = _Run();
      },
    );
    work.add('zim-pdf/law', size: 2);
    s.setOpen(true);
    await _settle();
    expect(s.running, 'zim-captions/nhs');
    // progress moves: not stuck however long it takes
    now = now.add(const Duration(minutes: 4));
    read = 1;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    now = now.add(const Duration(minutes: 4));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(s.running, 'zim-captions/nhs');
    // then nothing for over five minutes: stuck, stopped, skipped; the next one runs
    now = now.add(const Duration(minutes: 2));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await _settle();
    expect(work.runs['zim-captions/nhs']!.pauses, 1);
    expect(s.running, 'zim-pdf/law');
    expect(s.statusOf('zim-captions/nhs')?.why, IndexWait.stuck);
    expect(indexItemWords(s.statusOf('zim-captions/nhs')!), 'Stuck · skipped for now · Retry');
    // Retry: back in the queue, after the one running
    work.finish('zim-pdf/law');
    await s.retry('zim-captions/nhs');
    await _settle();
    expect(s.running, 'zim-captions/nhs');
    expect(work.started.where((k) => k == 'zim-captions/nhs'), hasLength(2));
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

  group('each piece of work says where it stands (the one source of the rows, menus, overview and Settings line)', () {
    test('only the running work is running; the rest are queued in order, with their place', () async {
      work
        ..add('zim-pdf/a', size: 1)
        ..add('zim-pdf/b', size: 2)
        ..add('zim-epub/c', size: 3);
      s.setOpen(true);
      await _settle();
      expect([for (final i in s.items) (i.key, i.state, i.position)], [
        ('zim-pdf/a', IndexState.running, 0),
        ('zim-pdf/b', IndexState.queued, 2),
        ('zim-epub/c', IndexState.queued, 3),
      ]);
      expect(s.statusOf('zim-pdf/b')!.why, IndexWait.none);
      work.finish('zim-pdf/a');
      await _settle();
      expect(s.statusOf('zim-pdf/a')!.state, IndexState.done);
      expect(s.statusOf('zim-pdf/b')!.state, IndexState.running);
      expect(s.statusOf('zim-pdf/zzz'), isNull, reason: 'work the scheduler has not seen has no status');
    });

    test('on a low battery every piece is held for the battery, none says running', () async {
      battery = const BatteryReading(percent: 12, charging: false);
      work
        ..add('zim-pdf/a')
        ..add('zim-epub/a', long: false);
      s.setOpen(true);
      await _settle();
      expect(work.started, isEmpty);
      expect([for (final i in s.items) (i.state, i.why)], [(IndexState.held, IndexWait.battery), (IndexState.held, IndexWait.battery)]);
      expect(s.reading!.percent, 12);
    });

    test('long work held for charging while short work runs; the long one says why', () async {
      battery = const BatteryReading(percent: 40, charging: false);
      work
        ..add('zim-pdf/a', size: 1)
        ..add('zim/a', size: 2, long: false);
      s.setOpen(true);
      await _settle();
      expect(s.running, 'zim/a');
      expect((s.statusOf('zim-pdf/a')!.state, s.statusOf('zim-pdf/a')!.why), (IndexState.held, IndexWait.charging));
    });

    test('work that needs room says how much', () async {
      space = const Space(free: 21 * _gb, reserve: 20 * _gb);
      work.add('zim-pdf/a', bytes: 2 * _gb);
      s.setOpen(true);
      await _settle();
      final i = s.statusOf('zim-pdf/a')!;
      expect((i.state, i.why, i.bytesNeeded), (IndexState.held, IndexWait.storage, 2 * _gb));
    });

    test('in the background everything is held for that reason', () async {
      work
        ..add('zim-pdf/a')
        ..add('zim-pdf/b');
      s.setOpen(true);
      await _settle();
      s.setOpen(false);
      await _settle();
      expect([for (final i in s.items) i.why], [IndexWait.closed, IndexWait.closed]);
      expect(s.line, 'Getting search ready · 0 of 2 done · Paused · Cache is in the background');
    });

    test('Pause all holds everything as paused by you; Resume lets the rules decide again', () async {
      work
        ..add('zim-pdf/a')
        ..add('zim-pdf/b');
      s.setOpen(true);
      await _settle();
      await s.pauseAll();
      expect(work.runs['zim-pdf/a']!.pauses, 1);
      expect(s.running, isNull);
      expect([for (final i in s.items) (i.state, i.why)], [(IndexState.held, IndexWait.person), (IndexState.held, IndexWait.person)]);
      expect(s.line, 'Getting search ready · 0 of 2 done · Paused by you · Resume');
      await s.kick();
      expect(s.running, isNull, reason: 'nothing starts while paused by you');
      await s.resumeAll();
      await _settle();
      expect(s.running, 'zim-pdf/a');
    });

    test('a battery that cannot be read does not hold work (it runs as if plugged in)', () async {
      battery = null;
      work.add('zim-pdf/a');
      s.setOpen(true);
      await _settle();
      expect(s.running, 'zim-pdf/a');
      expect(s.reading, isNull);
      expect(s.statusOf('zim-pdf/a')!.why, IndexWait.none);
    });

    test('the running work reports its progress and title as its task gives them', () async {
      var done = 3;
      work.tasks['zim-pdf/a'] = IndexTask(
        key: 'zim-pdf/a',
        title: 'Army Publishing',
        progress: () => (done, 10),
        start: () async => work.runs['zim-pdf/a'] = _Run(),
      );
      s.setOpen(true);
      await _settle();
      expect((s.statusOf('zim-pdf/a')!.title, s.statusOf('zim-pdf/a')!.progress), ('Army Publishing', (3, 10)));
      done = 4;
      expect(s.statusOf('zim-pdf/a')!.progress, (4, 10));
    });
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
