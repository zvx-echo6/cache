import 'dart:async';
import 'dart:io';

import 'package:cache/background/background_lock.dart';
import 'package:cache/background/fgs_add.dart';
import 'package:cache/background/fgs_refused_note.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/watch_background.dart';
import 'package:cache/platform/battery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../add_pdf/add_pdf_fixtures.dart';

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 20000 && !ok(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ok(), isTrue);
}

Future<void> _turns(int n) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The foreground service's emulator round (build 52 test APK, 2026-11-14): Pause in the notification and Stop adding did nothing for
/// minutes (the core's step was eight pieces), a force-stopped run's lock held the next open off, and the refused-notifications note
/// was not seen.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fgs-emu'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('Pause and Stop adding are heard within one piece', () {
    test('the core is asked for one piece a step, and the service looks for a Pause every second at most', () async {
      final calls = FakeIngestCalls({'step': steps([progress('done', result: {'copy': 'c' * 64})])});
      final s = testAddPdfState(Directory('${tmp.path}/ingest'), calls: calls);
      final f = File('${tmp.path}/a.pdf')..writeAsStringSync('pdf');
      await s.add(pdfPath: f.path, fileName: 'a.pdf', bytes: 3, title: 'A', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books', isDefault: true));
      final run = await (await s.pending()).single.start();
      await run.finished;
      final opts = calls.argsOf('start').single['opts'] as Map;
      expect(opts['embed_batch'], 1, reason: 'a step that is eight pieces cannot be interrupted for minutes');
      expect(kFgsLookEvery, lessThanOrEqualTo(const Duration(seconds: 1)));
    });

    test('the notification Pause: the run takes no further step once the piece it is on is done', () async {
      final support = '${tmp.path}/support';
      final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
      var n = 0;
      final calls = FakeIngestCalls({
        'step': (_) async {
          final i = n++;
          await gates[i].future; // one piece
          return progress('embedding', pages: 100, pagesDone: 100, pieces: 50, piecesDone: i + 1);
        },
      });
      final s = testAddPdfState(Directory('$support/ingest'), calls: calls);
      addTearDown(s.dispose);
      final f = File('${tmp.path}/a.pdf')..writeAsStringSync('pdf');
      final job = await s.add(pdfPath: f.path, fileName: 'a.pdf', bytes: 3, title: 'A', target: const AddPdfTarget(title: 'My books', path: '/tmp/my-books', isDefault: true));
      final lock = BackgroundLock(Directory(backgroundDir(support)));
      final c = FgsAddControl();
      final running = fgsAddJob(support: support, control: c, lock: lock, battery: () async => const BatteryReading(percent: 80, charging: true, thermal: Thermal.nominal), state: s, queue: ({bool next = false, Duration delay = Duration.zero}) async {}, waitForBack: Duration.zero, lookEvery: const Duration(milliseconds: 10));
      await _until(() => n == 1);
      c.stop('person'); // the notification's Pause, while the piece is in flight
      await _turns(100);
      gates[0].complete(); // the piece ends
      final out = await running;
      expect(n, 1, reason: 'no second piece was started after the Pause');
      expect(job.pausedByPerson, isTrue);
      expect(c.result?.why, 'person');
      expect(out.words, isNotEmpty);
    });
  });

  group('a force-stopped run holds nothing', () {
    final dead = 2147480000; // not a process on any machine
    test('its lock file names a process that is gone: the next open is not made to wait', () async {
      if (!(Platform.isLinux || Platform.isAndroid)) return;
      final dir = Directory('${tmp.path}/background');
      final service = BackgroundLock(dir, pid: dead);
      expect(service.hold(kAddPdfWork), isTrue);
      expect(service.runs(kAddPdfWork), isTrue, reason: 'its own process is taken as alive');
      final app = BackgroundLock(dir);
      expect(app.runs(kAddPdfWork), isFalse, reason: 'the process that wrote it is gone');
      expect(await app.takeOver(kAddPdfWork, wait: Duration.zero), isTrue);
    });

    test('a run in a live process, or an old file without a process, still holds as before', () async {
      final dir = Directory('${tmp.path}/background');
      final live = BackgroundLock(dir, pid: pid);
      expect(live.hold(kAddPdfWork), isTrue);
      expect(BackgroundLock(dir, pid: 1).runs(kAddPdfWork), isTrue, reason: 'a live process holds');
      dir.createSync(recursive: true);
      File('${dir.path}/run-${kAddPdfWork}2').writeAsStringSync(DateTime.now().toIso8601String());
      expect(BackgroundLock(dir).runs('${kAddPdfWork}2'), isTrue, reason: 'no process named: the time decides');
      final old = BackgroundLock(dir, clock: () => DateTime.now().add(const Duration(minutes: 3)));
      expect(old.runs(kAddPdfWork), isFalse, reason: 'a stale time holds nothing');
    });
  });

  group('the refused-notifications note', () {
    testWidgets('is shown even when the screen is replaced right as the question ends, and stays', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const Scaffold(body: Text('Add PDF'))));
      unawaited(showFgsRefusedNote(() => key.currentContext, after: const Duration(milliseconds: 100)));
      key.currentState!.pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Progress'))));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Progress'), findsOneWidget);
      expect(find.text(FgsWords.refused), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(FgsWords.refused), findsOneWidget, reason: 'long enough to read');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
