// The Library's index line and queue sheet in a browser: fed by the server's `index.state` `_queue`, with the same words as on a
// phone, and Pause all, Resume and Retry going to the server (index.pause, index.retry).
import 'package:cache/search/index_overview.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/search/server_index_progress.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The server's ops, recorded.
class _Server {
  final List<(String, Map<String, dynamic>)> calls = [];
  late final ServerIndexProgress progress = ServerIndexProgress(
    setPaused: (p) async => calls.add(('index.pause', {'paused': p})),
    retryKey: (k) async => calls.add(('index.retry', {'key': k})),
    titleOf: (id) => {'army': 'Army Publishing'}[id],
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
  final threeOfWork = _q([
    _item('zim-pdf/army', 'done', step: 'pdfs'),
    _item('zim-epub/army', 'running', done: 3, total: 12, step: 'epubs'),
    _item('zim-captions/army', 'queued', step: 'captions'),
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
    final s = _Server()..progress.update(_q([_item('zim-pdf/army', 'stuck', step: 'pdfs'), _item('zim-epub/army', 'queued', step: 'epubs')], 0, 2));
    await _open(tester, s.progress);
    expect(find.text('Stuck at: making PDFs searchable · Retry'), findsOneWidget);
    await tester.tap(find.text('Stuck at: making PDFs searchable · Retry'));
    await tester.pump();
    expect(s.calls, [('index.retry', {'key': 'zim-pdf/army'})]);
  });

  testWidgets('Pause all and Resume go to the server as index.pause', (tester) async {
    final s = _Server()..progress.update(threeOfWork);
    await _open(tester, s.progress);
    await tester.tap(find.byKey(const ValueKey('index-pause-all')));
    await tester.pumpAndSettle();
    expect(s.calls.last, ('index.pause', {'paused': true}));
    expect(find.byKey(const ValueKey('index-resume-all')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('index-resume-all')));
    await tester.pumpAndSettle();
    expect(s.calls.last, ('index.pause', {'paused': false}));
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
    s.progress.update(_q([_item('zim-pdf/army', 'done'), _item('zim-epub/army', 'done'), _item('zim-captions/army', 'done')], 3, 3));
    await tester.pump();
    expect(find.text('Search ready · 3 of 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('index-overview')), findsNothing);
  });
}
