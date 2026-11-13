import 'package:test/test.dart';

import '../bin/host_load.dart';

void main() {
  const gib = 1 << 30;
  late double? temp;
  late ({int available, int total})? mem;
  late DateTime now;
  late HostLoad load;

  setUp(() {
    temp = 40;
    mem = (available: 8 * gib, total: 16 * gib);
    now = DateTime(2026, 11, 9, 12);
    load = HostLoad(readTempC: () => temp, readMemory: () => mem, clock: () => now);
  });

  HostDuty at(Duration later) {
    now = now.add(later);
    return load.duty();
  }

  test('a cool host with memory to spare runs at the desktop share (2 s on, a quarter second off)', () {
    final d = load.duty();
    expect(d.paused, isFalse);
    expect(d.workMs, 2000);
    expect(d.idleMs, 250);
    expect(d.hold, isNull);
    expect(d.pace(), {'work_ms': 2000, 'idle_ms': 250, 'paused': false});
  });

  test('heat slows the work, pauses it at the top, and lets it go on again only when well down', () {
    expect(load.duty().hold, isNull);
    temp = 82; // heat 0.48: slowed
    final slow = at(const Duration(seconds: 6));
    expect(slow.paused, isFalse);
    expect(slow.hold, 'heat');
    expect(slow.idleMs, greaterThan(250));
    temp = 95; // heat 1: paused
    expect(at(const Duration(seconds: 6)).paused, isTrue);
    temp = 80; // heat 0.4 smoothed from 1: 0.7, still held (resumes below 0.6)
    final held = at(const Duration(seconds: 6));
    expect(held.paused, isTrue);
    expect(held.hold, 'heat');
    temp = 40;
    at(const Duration(seconds: 6));
    expect(at(const Duration(seconds: 6)).paused, isFalse);
  });

  test('low memory pauses the work until twice the floor is free again', () {
    mem = (available: 500 * (1 << 20), total: 16 * gib); // the floor is 5% of 16 GiB, about 820 MB
    final d = load.duty();
    expect(d.paused, isTrue);
    expect(d.hold, 'memory');
    mem = (available: 1000 * (1 << 20), total: 16 * gib); // over the floor, under twice it
    expect(at(const Duration(seconds: 6)).paused, isTrue);
    mem = (available: 2 * gib, total: 16 * gib);
    expect(at(const Duration(seconds: 6)).paused, isFalse);
  });

  test('the host is read at most every five seconds', () {
    expect(load.duty().paused, isFalse);
    temp = 100;
    expect(at(const Duration(seconds: 1)).paused, isFalse);
    expect(at(const Duration(seconds: 6)).paused, isTrue);
  });

  test('nothing to read means no yield', () {
    temp = null;
    mem = null;
    expect(load.duty().paused, isFalse);
  });

  test('/proc/meminfo is parsed', () {
    final m = parseMemInfo('MemTotal:       16384 kB\nMemFree:         100 kB\nMemAvailable:    8192 kB\n');
    expect(m, (available: 8192 * 1024, total: 16384 * 1024));
    expect(parseMemInfo('nothing here'), isNull);
  });

  test('the pacer returns inside a burst, rests after it, and waits while the host holds work', () async {
    final slept = <Duration>[];
    var held = true;
    final pacer = IndexPacer(
      HostLoad(readTempC: () => null, readMemory: () => held ? (available: 1, total: 16 * gib) : (available: 8 * gib, total: 16 * gib), clock: () => now, every: Duration.zero),
      sleep: (d) async {
        slept.add(d);
        if (d == const Duration(seconds: 2)) held = false;
        now = now.add(d);
      },
      clock: () => now,
    );
    await pacer.permit();
    expect(slept, [const Duration(seconds: 2)], reason: 'it waited once for memory, then the burst began');
    await pacer.permit();
    expect(slept, hasLength(1), reason: 'still inside the burst');
    now = now.add(const Duration(seconds: 3));
    await pacer.permit();
    expect(slept.last, const Duration(milliseconds: 250), reason: 'the burst is over: rest');
  });
}
