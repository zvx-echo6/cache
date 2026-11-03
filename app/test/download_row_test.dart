import 'package:cache/downloads/download_row.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1 << 30;
const _mb = 1 << 20;

void main() {
  group('the status line (UX-downloads-29 wording)', () {
    final total = (4.6 * _gb).round(), done = (1.7 * _gb).round();
    test('every state', () {
      expect(dlLine(DlState(DlPhase.idle, total: total), idle: '4.6 GB · May be tight on this device'), '4.6 GB · May be tight on this device');
      expect(dlLine(DlState(DlPhase.starting, total: total)), 'Starting…');
      expect(dlLine(DlState(DlPhase.running, done: done, total: total, speed: 6.2 * _mb)), '1.7 of 4.6 GB · 6.2 MB/s · about 8 min left');
      expect(dlLine(DlState(DlPhase.running, done: done, total: total)), '1.7 of 4.6 GB', reason: 'no speed before 5 seconds of data');
      expect(dlLine(DlState(DlPhase.running, done: done, total: total, speed: 0)), '1.7 of 4.6 GB · Waiting for the server', reason: 'measured, and nothing came');
      expect(dlLine(DlState(DlPhase.pausing, done: done, total: total)), 'Pausing…');
      expect(dlLine(DlState(DlPhase.paused, done: done, total: total)), 'Paused · 1.7 of 4.6 GB');
      expect(dlLine(DlState(DlPhase.failed, done: done, total: total, reason: DlReason.noConnection)), 'Stopped: no connection · 1.7 of 4.6 GB');
      expect(dlLine(const DlState(DlPhase.failed, reason: DlReason.noConnection, part: 'Places')), 'Stopped: no connection · Places');
      expect(dlLine(const DlState(DlPhase.waiting, waitingFor: 'Idaho map')), 'Waiting for Idaho map to finish');
      expect(dlLine(const DlState(DlPhase.verifying)), 'Checking the file…');
      expect(dlLine(const DlState(DlPhase.unpacking)), 'Unpacking…');
      expect(dlLine(DlState(DlPhase.done, total: total)), 'On this device · 4.6 GB');
    });
    test('bytes, an unknown total and time left', () {
      expect(dlBytes(650 * _mb, total), '650 MB of 4.6 GB');
      expect(dlBytes(done, 0), '1.7 GB so far');
      expect(dlTimeLeft(const Duration(seconds: 40)), 'less than a minute');
      expect(dlTimeLeft(const Duration(minutes: 8)), 'about 8 min');
      expect(dlTimeLeft(const Duration(hours: 2, minutes: 10)), 'about 2 hr');
    });
    test('reasons from the engines\' own words', () {
      expect(DlReason.of('The device is out of space. Free some and try again.'), DlReason.full);
      expect(DlReason.of('no_space'), DlReason.full);
      expect(DlReason.of('The connection failed: connection reset'), DlReason.noConnection);
      expect(DlReason.of('The download server took too long to answer.'), DlReason.noAnswer);
      expect(DlReason.of('The download stopped early (1 MB of 2 MB). Try again to continue.'), DlReason.cutOff);
    });
  });

  test('speed shows only after 5 seconds of data', () {
    var t = DateTime(2026, 11, 1);
    DlMeter.now = () => t;
    addTearDown(() => DlMeter.now = DateTime.now);
    expect(DlMeter.speed('k', 0), isNull);
    t = t.add(const Duration(seconds: 3));
    expect(DlMeter.speed('k', 30 * _mb), isNull);
    t = t.add(const Duration(seconds: 3));
    expect(DlMeter.speed('k', 60 * _mb)! / _mb, closeTo(10, 0.01));
  });

  Widget host(Widget row) => MaterialApp(theme: buildTheme(CacheThemeId.light), home: Scaffold(body: row));

  testWidgets('one control per state: Pause only while running; Resume and Remove when paused; Free space when full', (tester) async {
    var paused = 0, resumed = 0, removed = 0, freed = 0;
    final a = DlActions(pause: () => paused++, resume: () => resumed++, remove: () async => removed++, freeSpace: () => freed++);
    Future<void> show(DlState s) => tester.pumpWidget(host(DownloadRow(title: 'Gemma', state: s, actions: a, keyBase: 'm')));
    await show(DlState(DlPhase.running, done: _gb, total: 2 * _gb));
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Remove'), findsNothing, reason: 'never beside Pause');
    await tester.tap(find.text('Pause'));
    expect(paused, 1);
    await show(DlState(DlPhase.paused, done: _gb, total: 2 * _gb));
    expect(find.text('Resume'), findsOneWidget);
    expect(find.byKey(const ValueKey('m-remove')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('m-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remove the 1.0 GB already downloaded?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('remove-download-yes')));
    await tester.pumpAndSettle();
    expect(removed, 1);
    await show(DlState(DlPhase.failed, done: _gb, total: 2 * _gb, reason: DlReason.full));
    expect(find.text('Free space'), findsOneWidget);
    expect(find.text('Stopped: this device is full · 1.0 of 2.0 GB'), findsOneWidget);
    await show(const DlState(DlPhase.starting));
    expect(find.byKey(const ValueKey('m-busy')), findsOneWidget);
    expect(find.text('Starting…'), findsOneWidget);
    // Press and hold on an active row: Pause or Resume, and Remove download.
    await show(DlState(DlPhase.running, done: _gb, total: 2 * _gb));
    await tester.longPress(find.byKey(const ValueKey('m-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('download-menu')), findsOneWidget);
    expect(find.text('Remove download'), findsOneWidget);
    expect(resumed + freed, 0);
  });
}
