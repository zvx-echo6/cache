// The Library's index line and queue sheet in a browser: fed by the server's `index.state` `_queue`, with the same words as on a
// phone, and Pause all, Resume and Retry going to the server (index.pause, index.retry).
import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_list.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/search/index_overview.dart';
import 'package:cache/search/server_index_progress.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/build_fakes.dart';

/// The server's ops, recorded.
class _Server {
  final List<String> calls = [];
  late final ServerIndexProgress progress = ServerIndexProgress(
    setPaused: (p) async => calls.add('index.pause {paused: $p}'),
    retryKey: (k) async => calls.add('index.retry {key: $k}'),
    titleOf: (key) => key.endsWith('/army') || key == '/docs/army.zim' ? 'Army Publishing' : null,
  );
}

Map<String, dynamic> _q(List<Map<String, dynamic>> items, int done, int total) => {'items': items, 'done': done, 'total': total};

Map<String, dynamic> _item(String key, String state, {int? done, int? total, String? step}) => {'key': key, 'state': state, 'done': done, 'total': total, 'step': step};

Widget _app(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: SingleChildScrollView(child: child)));

Future<void> _open(WidgetTester tester, ServerIndexProgress p) async {
  await tester.pumpWidget(_app(IndexOverviewLine(scheduler: p)));
  await tester.tap(find.byKey(const ValueKey('index-overview')));
  await tester.pumpAndSettle();
}

void main() {
  // the server's order: running, queued, done, stuck, failed; keys as the server writes them
  final threeOfWork = _q([
    _item('zim-epub/army', 'running', done: 3, total: 12, step: 'epubs'),
    _item('zim-captions/army', 'queued', step: 'captions'),
    _item('/docs/army.zim', 'done', done: 4, total: 4, step: 'keywords'),
  ], 1, 3);

  testWidgets('a queue with running and queued work gives the headline', (tester) async {
    final s = _Server()..progress.update(threeOfWork);
    await tester.pumpWidget(_app(IndexOverviewLine(scheduler: s.progress)));
    expect(find.text('Getting search ready · 1 of 3 done'), findsOneWidget);
    expect(find.text('Army Publishing · EPUBs 3 of 12'), findsOneWidget);
  });

  testWidgets('the sheet shows Running now, Next and Done', (tester) async {
    final s = _Server()..progress.update(threeOfWork);
    await _open(tester, s.progress);
    expect(find.text('Search indexes'), findsOneWidget);
    expect(find.text('RUNNING NOW'), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('Making EPUBs searchable · 3 of 12'), findsOneWidget);
    expect(find.text('Waiting to make captions searchable'), findsOneWidget);
    expect(find.text('Pause all'), findsOneWidget);
  });

  testWidgets('a stuck item says where it stopped, and Retry goes to the server', (tester) async {
    final s = _Server()..progress.update(_q([_item('zim-epub/army', 'queued', step: 'epubs'), _item('/docs/c.zim', 'stuck', done: 1, total: 4, step: 'keywords')], 0, 2));
    await _open(tester, s.progress);
    expect(find.text('Stuck at: getting the search index ready · Retry'), findsOneWidget);
    await tester.tap(find.text('Stuck at: getting the search index ready · Retry'));
    await tester.pump();
    expect(s.calls, ['index.retry {key: /docs/c.zim}']);
  });

  testWidgets('a failed job says it could not do its step, never Stuck, and Retry goes to the server', (tester) async {
    final s = _Server()..progress.update(_q([_item('zim-captions/army', 'failed', done: 1, total: 4, step: 'captions'), _item('/docs/c.zim', 'stuck', step: 'keywords')], 0, 2));
    await _open(tester, s.progress);
    expect(find.text("Couldn't make captions searchable · Retry"), findsOneWidget);
    expect(find.text('Stuck at: getting the search index ready · Retry'), findsOneWidget, reason: 'the genuine no-progress state keeps its own words');
    expect(find.textContaining('Stuck at: making captions'), findsNothing);
    await tester.tap(find.text("Couldn't make captions searchable · Retry"));
    await tester.pump();
    expect(s.calls, ['index.retry {key: zim-captions/army}']);
  });

  testWidgets('Pause all and Resume go to the server as index.pause', (tester) async {
    final s = _Server()..progress.update(threeOfWork);
    await _open(tester, s.progress);
    await tester.tap(find.byKey(const ValueKey('index-pause-all')));
    await tester.pumpAndSettle();
    expect(s.calls.last, 'index.pause {paused: true}');
    expect(find.byKey(const ValueKey('index-resume-all')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('index-resume-all')));
    await tester.pumpAndSettle();
    expect(s.calls.last, 'index.pause {paused: false}');
    expect(find.byKey(const ValueKey('index-pause-all')), findsOneWidget);
  });

  testWidgets('a hold for memory says Waiting for free memory; heat says the phone\'s words', (tester) async {
    final s = _Server()..progress.update(threeOfWork, hold: 'memory');
    await tester.pumpWidget(_app(IndexOverviewLine(scheduler: s.progress)));
    expect(find.text('Getting search ready · 1 of 3 done · Waiting for free memory'), findsOneWidget);
    s.progress.update(threeOfWork, hold: 'heat');
    await tester.pump();
    expect(find.text('Getting search ready · 1 of 3 done · Paused · keeping the device cool'), findsOneWidget);
  });

  testWidgets('an empty queue says everything is searchable', (tester) async {
    final s = _Server()..progress.update(_q([], 0, 0));
    await tester.pumpWidget(_app(IndexQueueSheet(scheduler: s.progress)));
    expect(find.text('Everything is searchable.'), findsOneWidget);
  });

  testWidgets('a server with no _queue shows nothing', (tester) async {
    final s = _Server()..progress.update(null);
    await tester.pumpWidget(_app(IndexOverviewLine(scheduler: s.progress)));
    expect(find.byKey(const ValueKey('index-overview')), findsNothing);
    expect(s.progress.busy, isFalse);
  });

  testWidgets('when all is done it says Search ready for a moment', (tester) async {
    final s = _Server()..progress.update(threeOfWork);
    await tester.pumpWidget(_app(IndexOverviewLine(scheduler: s.progress, doneFor: const Duration(seconds: 1))));
    s.progress.update(_q([_item('seal:zim/army', 'done', step: 'seal'), _item('zim-epub/army', 'done', step: 'epubs'), _item('/docs/army.zim', 'done', step: 'keywords')], 3, 3));
    await tester.pump();
    expect(find.text('Search ready · 3 of 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('index-overview')), findsNothing);
  });

  group('a library the server is building from PDFs (read from the Library\'s own build poll)', () {
    QueueItem book(String id, String state, {int pieces = 0, int? total}) => QueueItem(id: id, libraryId: 'proof', fileName: '$id.pdf', state: state, progress: QueueProgress(pieces: pieces, piecesTotal: total));

    Future<(FakeBuildApi, BuildController, ServerIndexProgress)> setup(WidgetTester tester) async {
      final api = FakeBuildApi()..libs = [const BuildLibrary(id: 'proof', title: 'Proof-Library', building: true)];
      final ctl = BuildController(api: api, poll: false);
      final p = _Server().progress..attachBuilds(ctl);
      await tester.runAsync(ctl.refresh);
      return (api, ctl, p);
    }

    testWidgets('a build in progress gives the line and a row in the sheet; finished gives the done state', (tester) async {
      final (api, ctl, p) = await setup(tester);
      api.q = BuildQueue(items: [for (var n = 1; n <= 11; n++) book('b$n', 'done'), book('b12', 'building', pieces: 16, total: 308)]);
      await tester.runAsync(ctl.refresh);
      await tester.pumpWidget(_app(IndexOverviewLine(scheduler: p, doneFor: const Duration(seconds: 1))));
      expect(find.text('Getting search ready · 0 of 1 done'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('index-overview')));
      await tester.pumpAndSettle();
      expect(find.text('RUNNING NOW'), findsOneWidget);
      expect(find.text('Proof-Library · the search index'), findsOneWidget);
      expect(find.text('Building passages · 16 of 308'), findsOneWidget);
      // finished
      api.q = BuildQueue(items: [for (var n = 1; n <= 12; n++) book('b$n', 'done')]);
      await tester.runAsync(ctl.refresh);
      await tester.pump();
      expect(find.text('DONE'), findsOneWidget);
      expect(p.busy, isFalse);
      expect(p.doneCount, 1);
    });

    testWidgets('a build and the server queue count together', (tester) async {
      final (api, ctl, p) = await setup(tester);
      api.q = BuildQueue(items: [book('b1', 'queued')]);
      await tester.runAsync(ctl.refresh);
      p.update(threeOfWork);
      await tester.pumpWidget(_app(IndexOverviewLine(scheduler: p)));
      expect(find.text('Getting search ready · 1 of 4 done'), findsOneWidget);
    });

    testWidgets('Pause all and Resume also pause and resume the server\'s library build queue', (tester) async {
      final api = FakeBuildApi()
        ..libs = [const BuildLibrary(id: 'proof', title: 'Proof-Library', building: true)]
        ..q = BuildQueue(items: [book('b1', 'building', pieces: 2, total: 10), book('b2', 'queued')]);
      final ctl = BuildController(api: api, poll: false);
      final server = _Server();
      final p = server.progress..attachBuilds(ctl);
      await tester.runAsync(ctl.refresh);
      await _open(tester, p);
      await tester.tap(find.byKey(const ValueKey('index-pause-all')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(server.calls, contains('index.pause {paused: true}'));
      expect(api.calls, contains('pause'));
      expect(p.pausedAll, isTrue);
      // the build's row says the same paused words as any paused work
      expect(find.text('Paused by you · Resume'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('index-resume-all')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(server.calls.last, 'index.pause {paused: false}');
      expect(api.calls, contains('resume'));
      expect(p.pausedAll, isFalse);
    });

    testWidgets('a build paused from the Library banner alone counts as paused, and Resume resumes it', (tester) async {
      final api = FakeBuildApi()
        ..libs = [const BuildLibrary(id: 'proof', title: 'Proof-Library', building: true)]
        ..q = BuildQueue(paused: true, items: [book('b1', 'queued')]);
      final ctl = BuildController(api: api, poll: false);
      final server = _Server();
      final p = server.progress..attachBuilds(ctl);
      await tester.runAsync(ctl.refresh);
      expect(p.pausedAll, isTrue);
      await tester.runAsync(p.resumeAll);
      expect(api.calls, contains('resume'));
      // Resume clears both pauses, whichever one the person set
      expect(server.calls, ['index.pause {paused: false}']);
    });

    testWidgets('Pause all, then Resume from the build panel clears both pauses', (tester) async {
      final api = FakeBuildApi()
        ..libs = [const BuildLibrary(id: 'proof', title: 'Proof-Library', building: true)]
        ..q = BuildQueue(items: [book('b1', 'building', pieces: 2, total: 10), book('b2', 'queued')]);
      final ctl = BuildController(api: api, poll: false);
      final server = _Server();
      final p = server.progress..attachBuilds(ctl);
      await tester.runAsync(ctl.refresh);
      await tester.runAsync(p.pauseAll);
      expect(server.calls, ['index.pause {paused: true}']);
      expect(api.calls, ['pause']);
      expect(p.pausedAll, isTrue);
      await tester.pumpWidget(_app(ListenableBuilder(listenable: ctl, builder: (_, _) => BuildListCards(ctl: ctl))));
      await tester.tap(find.byKey(const ValueKey('list-resume-proof')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(server.calls.last, 'index.pause {paused: false}');
      expect(api.calls.last, 'resume');
      expect(p.pausedAll, isFalse);
    });

    testWidgets('Pause all, then Resume from the queue sheet clears both pauses', (tester) async {
      final api = FakeBuildApi()
        ..libs = [const BuildLibrary(id: 'proof', title: 'Proof-Library', building: true)]
        ..q = BuildQueue(items: [book('b1', 'building', pieces: 2, total: 10), book('b2', 'queued')]);
      final ctl = BuildController(api: api, poll: false);
      final server = _Server();
      final p = server.progress..attachBuilds(ctl);
      await tester.runAsync(ctl.refresh);
      await tester.runAsync(p.pauseAll);
      await _open(tester, p);
      await tester.tap(find.byKey(const ValueKey('index-resume-all')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(server.calls.last, 'index.pause {paused: false}');
      expect(api.calls.last, 'resume');
      expect(p.pausedAll, isFalse);
    });
  });
}
