// What the Library rows, their menus, the Library's overview line and its queue sheet, and the Settings line say of search
// index work: all from the index scheduler, so only the work it runs says "Making", and every wait says why and what makes it
// go on.
import 'dart:async';

import 'package:cache/platform/battery.dart';
import 'package:cache/search/epub_index_row.dart';
import 'package:cache/search/index_overview.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_status.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show ZimSubIndex;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;

class _Run implements IndexRun {
  final Completer<bool> done = Completer<bool>();

  @override
  Future<bool> get finished => done.future;

  @override
  Future<void> pause([IndexWait why = IndexWait.none]) async {
    if (!done.isCompleted) done.complete(false);
  }

  @override
  void setDuty(_) {}
}

class _Work implements IndexWorkSource {
  final Map<String, IndexTask> tasks = {};
  final Map<String, _Run> runs = {};

  void add(String key, String title, {int size = 0, bool long = true, int bytes = 0, (int, int)? progress}) => tasks[key] = IndexTask(
        key: key,
        title: title,
        size: size,
        long: long,
        bytesNeeded: bytes,
        progress: progress == null ? null : () => progress,
        start: () async => runs[key] = _Run(),
      );

  @override
  Future<List<IndexTask>> pending() async => tasks.values.toList();
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('the words', () {
    test('every wait says its reason and its fix', () {
      const battery = BatteryReading(percent: 12, charging: false);
      expect(indexWaitWords(IndexWait.battery, battery: battery), 'Paused · battery low (12%) · plug in to continue');
      expect(indexWaitWords(IndexWait.battery), 'Paused · battery low · plug in to continue');
      expect(indexWaitWords(IndexWait.charging), 'Waits for charging (long job)');
      expect(indexWaitWords(IndexWait.heat), 'Paused · device is warm');
      expect(indexWaitWords(IndexWait.closed), 'Paused · Cache is in the background');
      expect(indexWaitWords(IndexWait.model), 'Paused · while Ask answers');
      expect(indexWaitWords(IndexWait.storage, bytesNeeded: 1288490189), 'Needs 1.2 GB free · Free space');
      expect(indexWaitWords(IndexWait.person), 'Paused by you · Resume');
      expect(indexWaitWords(IndexWait.none), isNull);
    });

    test('running says Making with progress; queued says Waiting; held says why', () {
      expect(indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.running, progress: (340, 5768))), 'Making PDFs searchable · 340 of 5,768');
      expect(indexItemWords(const IndexItem(key: 'zim-epub/u', state: IndexState.running, progress: (40, 85))), 'Making EPUBs searchable · 40 of 85');
      expect(indexItemWords(const IndexItem(key: 'zim-captions/u', state: IndexState.running)), 'Making captions searchable');
      expect(indexItemWords(const IndexItem(key: 'zim/u', state: IndexState.running)), 'Getting the search index ready');
      expect(indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.running, slowed: true, progress: (1, 2))), 'Slowed down · device is warm · 1 of 2');
      expect(indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.running, why: IndexWait.model, progress: (1, 2))), 'Paused · while Ask answers · 1 of 2');
      expect(indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.queued, position: 2)), 'Waiting to make PDFs searchable');
      expect(indexItemWords(const IndexItem(key: 'zim-epub/u', state: IndexState.queued, position: 3)), 'Waiting to make EPUBs searchable');
      expect(
        indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.held, why: IndexWait.battery), battery: const BatteryReading(percent: 11, charging: false)),
        'Paused · battery low (11%) · plug in to continue',
      );
      expect(indexItemWords(const IndexItem(key: 'zim-pdf/u', state: IndexState.done)), isNull);
    });
  });

  group('from the scheduler', () {
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

    test('several libraries: only the one running says Making; the others wait, in the rows and the line', () async {
      work
        ..add('zim-pdf/law', 'Gutenberg Law', size: 1, progress: (340, 5768))
        ..add('zim-pdf/edu', 'Gutenberg Education', size: 2)
        ..add('zim-pdf/naval', 'Naval science', size: 3);
      s.setOpen(true);
      await _settle();
      expect(indexRowWords(s, zimIndexKeys('law')), 'Making PDFs searchable · 340 of 5,768');
      expect(indexRowWords(s, zimIndexKeys('edu')), 'Waiting to make PDFs searchable');
      expect(indexRowWords(s, zimIndexKeys('naval')), 'Waiting to make PDFs searchable');
      expect(indexRowWords(s, zimIndexKeys('other')), isNull);
      expect(s.line, 'Getting search ready · 0 of 3 done');
    });

    test('on a low battery, unplugged, every row and the line say so, with the percent and the fix', () async {
      battery = const BatteryReading(percent: 12, charging: false);
      work
        ..add('zim-pdf/army', 'Army Publishing')
        ..add('zim-epub/army', 'Army Publishing', long: false);
      s.setOpen(true);
      await _settle();
      expect(indexRowWords(s, zimIndexKeys('army')), 'Paused · battery low (12%) · plug in to continue');
      expect(s.line, 'Getting search ready · 0 of 2 done · Paused · battery low (12%) · plug in to continue');
      // the menu's EPUB line, from the same status
      expect(epubLine(const ZimSubIndex(state: 'none', needsBuild: true), null, item: s.statusOf('zim-epub/army'), battery: s.reading),
          'Paused · battery low (12%) · plug in to continue');
    });

    test('no room says how much is needed', () async {
      space = const Space(free: 21 * _gb, reserve: 20 * _gb);
      work.add('zim-pdf/a', 'A', bytes: 2 * _gb);
      s.setOpen(true);
      await _settle();
      expect(indexRowWords(s, zimIndexKeys('a')), 'Needs 2.0 GB free · Free space');
    });

    testWidgets('the overview line at the top of the Library opens the queue: running, next, done, Pause all and Resume', (tester) async {
      await tester.runAsync(() async {
        work
          ..add('zim-pdf/law', 'Gutenberg Law', size: 1, progress: (340, 5768))
          ..add('zim-pdf/edu', 'Gutenberg Education', size: 2)
          ..add('zim-epub/army', 'Army Publishing', size: 3);
        s.setOpen(true);
        await _settle();
      });
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: ListView(children: [IndexOverviewLine(scheduler: s)]))));
      expect(find.text('Getting search ready · 0 of 3 done'), findsOneWidget);
      expect(find.text('Gutenberg Law · PDFs 340 of 5,768'), findsOneWidget);
      // the bar: each source an equal share, filled by its own items (340 of 5,768 PDFs of one of three)
      final bar = tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('index-overview-bar')));
      expect(bar.value, closeTo(340 / 5768 / 3, 1e-9));
      await tester.tap(find.byKey(const ValueKey('index-overview')));
      await tester.pumpAndSettle();
      expect(find.text('RUNNING NOW'), findsOneWidget);
      expect(find.text('Gutenberg Law · PDFs'), findsOneWidget);
      expect(find.text('Making PDFs searchable · 340 of 5,768'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.text('Gutenberg Education · PDFs'), findsOneWidget);
      expect(find.text('Waiting to make EPUBs searchable'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('index-pause-all')));
        await _settle();
      });
      await tester.pump();
      expect(find.text('Paused by you · Resume'), findsNWidgets(3));
      expect(find.text('RUNNING NOW'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('index-resume-all')));
        await _settle();
      });
      await tester.pump();
      expect(find.text('Making PDFs searchable · 340 of 5,768'), findsOneWidget);

      // done work moves to Done
      await tester.runAsync(() async {
        work.tasks.remove('zim-pdf/law');
        work.runs['zim-pdf/law']!.done.complete(true);
        await _settle();
      });
      await tester.pump();
      expect(find.text('DONE'), findsOneWidget);
      expect(find.text('Gutenberg Law · PDFs'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('when everything is done the bar says "Search ready · 2 of 2" for a moment, then goes', (tester) async {
      await tester.runAsync(() async {
        work
          ..add('zim-pdf/a', 'A', size: 1)
          ..add('zim-pdf/b', 'B', size: 2);
        s.setOpen(true);
        await _settle();
      });
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: IndexOverviewLine(scheduler: s, doneFor: const Duration(milliseconds: 50))),
      ));
      expect(find.text('Getting search ready · 0 of 2 done'), findsOneWidget);
      await tester.runAsync(() async {
        work.tasks.remove('zim-pdf/a');
        work.runs['zim-pdf/a']!.done.complete(true);
        await _settle();
      });
      await tester.pump();
      expect(find.text('Getting search ready · 1 of 2 done'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('index-overview-bar'))).value, 0.5);
      await tester.runAsync(() async {
        work.tasks.remove('zim-pdf/b');
        work.runs['zim-pdf/b']!.done.complete(true);
        await _settle();
        await s.kick();
      });
      await tester.pump();
      expect(find.text('Search ready · 2 of 2'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('index-overview-bar'))).value, 1);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      expect(find.byKey(const ValueKey('index-overview')), findsNothing);
    });

    testWidgets('no work: no overview line', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: IndexOverviewLine(scheduler: s))));
      expect(find.byKey(const ValueKey('index-overview')), findsNothing);
    });
  });
}
