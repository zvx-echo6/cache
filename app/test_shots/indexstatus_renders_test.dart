// 1.0.30 build 33: search index progress that says what it is doing (owner feedback on build 32: it was not clear whether
// indexing was running or what it was doing). Drawn by the app's own widgets from a real index scheduler over sample work (no personal data): the
// Library rows, a library's menu, the progress bar at the top of the Library (and in Settings), and its queue sheet. Light and
// dark. flutter test test_shots/indexstatus_renders_test.dart --update-goldens  (pictures in test_shots/indexstatus/)

import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_screen.dart' show LibraryRow;
import 'package:cache/browse/library_actions.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/pdf/index/pdf_index_ui.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/screens/settings/log_page.dart';
import 'package:cache/search/epub_index_row.dart';
import 'package:cache/search/index_overview.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/index_status.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart' show ZimSubIndex;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const _out = 'indexstatus';
const _gb = 1 << 30;

String _t(CacheThemeId t) => t == CacheThemeId.light ? 'light' : 'dark';

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

  void add(String key, String title, {int size = 0, bool long = true, (int, int)? progress}) => tasks[key] = IndexTask(
    key: key,
    title: title,
    size: size,
    long: long,
    progress: progress == null ? null : () => progress,
    start: () async => runs[key] = _Run(),
  );

  @override
  Future<List<IndexTask>> pending() async => tasks.values.toList();
}

/// The owner's libraries from the build 32 screenshots, as sample work: PDFs, EPUBs and captions.
const _libs = [
  ('army', 'Army Publishing', '6.2 GB'),
  ('law', 'Gutenberg Law', '2.1 GB'),
  ('edu', 'Gutenberg Education', '1.4 GB'),
  ('naval', 'Naval science', '880 MB'),
];

/// A scheduler with the sample work, at [battery], after its first look; [done] libraries finished first.
Future<IndexScheduler> _scheduler(WidgetTester tester, BatteryReading battery, {List<String> done = const []}) async {
  final work = _Work();
  for (final (id, title, _) in _libs) {
    work.add('zim-pdf/$id', title, size: _libs.indexWhere((l) => l.$1 == id) + 1, progress: id == 'army' ? (340, 5768) : (0, 1200));
  }
  work
    ..add('zim-epub/army', 'Army Publishing', size: 10, progress: (40, 85))
    ..add('zim-captions/naval', 'Naval science', size: 11);
  final s = IndexScheduler(sources: [work], space: () => const Space(free: 100 * _gb, reserve: 20 * _gb), battery: () async => battery, every: const Duration(hours: 1));
  addTearDown(s.dispose);
  await tester.runAsync(() async {
    s.setOpen(true);
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final id in done) {
      work.tasks.remove('zim-pdf/$id');
      work.runs['zim-pdf/$id']?.done.complete(true);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  });
  return s;
}

Widget _library(IndexScheduler s) => Scaffold(
  appBar: AppBar(title: const Text('Library')),
  body: ListView(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
    children: [
      IndexOverviewLine(scheduler: s),
      for (final (id, title, size) in _libs)
        LibraryRow(title: title, detail: [size, ?indexRowWords(s, zimIndexKeys(id))].join(' · '), onTap: () {}, onHold: () {}),
      const LibraryRow(title: 'Wikivoyage', detail: '840 MB', onTap: null, onHold: null),
    ],
  ),
);

Future<void> _show(WidgetTester tester, Widget page, CacheThemeId theme) async {
  phone(tester);
  await tester.pumpWidget(shotApp(page, theme: theme));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _snap(WidgetTester tester, String name, CacheThemeId theme) => snap(tester, _out, '$name-${_t(theme)}');

void main() {
  setUpAll(loadShotFonts);

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('1: the Library: one runs and says so with progress, the rest wait (${_t(theme)})', (tester) async {
      final s = await _scheduler(tester, const BatteryReading(percent: 80, charging: true));
      await _show(tester, _library(s), theme);
      await _snap(tester, '1a-library-one-running', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('2: the Library on a low battery, unplugged: every row and the bar say why and the fix (${_t(theme)})', (tester) async {
      final s = await _scheduler(tester, const BatteryReading(percent: 12, charging: false));
      await _show(tester, _library(s), theme);
      await _snap(tester, '2a-library-battery-low', theme);

      // Army Publishing's menu: its PDFs and EPUBs, held for the battery
      final ctx = tester.element(find.byType(ListView));
      final pdf = s.statusOf('zim-pdf/army')!;
      unawaited(showLibraryMenu(
        ctx,
        LibraryActions(
          title: 'Army Publishing',
          bytes: 6 << 30,
          delete: () async {},
          checkUpdate: () async {},
          parts: (_) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PdfPartView(
                part: const PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.held, hold: PdfHold.battery),
                line: indexItemWords(pdf, battery: s.reading),
                onResume: () {},
              ),
              EpubIndexRow(epub: const ZimSubIndex(state: 'none', needsBuild: true), progress: null, item: s.statusOf('zim-epub/army'), battery: s.reading),
            ],
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await _snap(tester, '2b-menu-battery-low', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('3: the queue sheet from the bar: running with its bar, next in order, done; Pause all (${_t(theme)})', (tester) async {
      final s = await _scheduler(tester, const BatteryReading(percent: 80, charging: true), done: const ['army']);
      await _show(tester, _library(s), theme);
      await tester.tap(find.byKey(const ValueKey('index-overview')));
      await tester.pumpAndSettle();
      await _snap(tester, '3a-queue-sheet', theme);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('index-pause-all')));
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await tester.pump();
      await _snap(tester, '3b-queue-sheet-paused-by-you', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('5: Details of a job in the queue: its last log lines (${_t(theme)})', (tester) async {
      final s = await _scheduler(tester, const BatteryReading(percent: 80, charging: true));
      for (final l in [
        'Index job starts',
        'PDF 339 of 5,768 (412 KB) starts',
        'PDF 339 of 5,768 done in 1840 ms',
        'PDF 340 of 5,768 (2,048 KB) starts',
      ]) {
        appLog.add(LogLevel.standard, 'INFO', l, job: 'zim-pdf/army');
      }
      await _show(tester, _library(s), theme);
      await tester.tap(find.byKey(const ValueKey('index-overview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('index-details-zim-pdf/army')));
      await tester.pumpAndSettle();
      await _snap(tester, '5a-job-details', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('6: Settings > Log: the log level, Share log, Clear log (${_t(theme)})', (tester) async {
      final dir = Directory.systemTemp.createTempSync('log-renders');
      addTearDown(() => dir.deleteSync(recursive: true));
      final log = AppLog(echo: (_) {});
      await tester.runAsync(() => log.open(Directory('${dir.path}/logs')));
      phone(tester);
      await tester.pumpWidget(shotApp(LogPage(log: log), theme: theme));
      await tester.pump(const Duration(milliseconds: 300));
      await _snap(tester, '6a-settings-log', theme);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('4: the bar on its own: waits for charging (${_t(theme)})', (tester) async {
      final s = await _scheduler(tester, const BatteryReading(percent: 40, charging: false));
      await _show(tester, Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: IndexOverviewLine(scheduler: s))), theme);
      await _snap(tester, '4a-bar-waits-for-charging', theme);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
