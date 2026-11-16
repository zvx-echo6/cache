import 'dart:io';

import 'package:cache/platform/exit_reasons.dart';
import 'package:cache/platform/run_mark.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('run-mark');
    file = File('${dir.path}/running');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // The lifecycle listener follows the legal steps only, so each move goes through every state on the way (as Android does).
  void go(List<AppLifecycleState> steps) => steps.forEach(binding.handleAppLifecycleStateChanged);
  const toBack = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused];
  const toFront = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];
  const closed = [AppLifecycleState.detached];
  void front() {
    go(toFront);
  }


  // What the next start does with the mark the last run left.
  LastRun nextStart({List<Map<Object?, Object?>>? exits = const []}) {
    final next = RunMark(file);
    return next.left ? lastRunEnd(next.leftAt, exits) : throw StateError('no mark: nothing is written');
  }

  test('in front, then to the back, then the process is killed: no mark, so no line at the next start', () {
    front();
    final mark = RunMark(file);
    final listener = mark.follow();
    addTearDown(listener.dispose);
    expect(file.existsSync(), isTrue, reason: 'a screen is in front');
    go(const [AppLifecycleState.inactive, AppLifecycleState.hidden]);
    expect(file.existsSync(), isFalse, reason: 'hidden: the app is in the back');
    // the kill (an install replacing the app, the system ending it): nothing runs, the next start finds no mark
    expect(RunMark(file).left, isFalse);
    go(const [AppLifecycleState.paused, AppLifecycleState.detached]);
    expect(file.existsSync(), isFalse);
  });

  test('the screen closed (detached) with the engine kept alive: no mark either', () {
    front();
    final listener = RunMark(file).follow();
    addTearDown(listener.dispose);
    go(toBack);
    go(closed);
    expect(RunMark(file).left, isFalse);
  });

  test('a start with no phone screen (the car started Cache) leaves no mark', () {
    go(toBack);
    go(closed);
    final listener = RunMark(file).follow();
    addTearDown(listener.dispose);
    expect(RunMark(file).left, isFalse);
  });

  test('a crash while a screen is in front leaves the mark, and the next start writes it as an error', () {
    front();
    final listener = RunMark(file).follow();
    addTearDown(listener.dispose);
    expect(nextStart(exits: [
      {'time': DateTime.now().millisecondsSinceEpoch + 1000, 'code': 4}
    ]), LastRun.unexpected);
    expect(nextStart(), LastRun.unexpected, reason: 'no record of the end: unexpected, as before');
  });

  test('coming back to the front sets the mark again; an update with a screen in front is "ended", not an error', () {
    front();
    final listener = RunMark(file).follow();
    addTearDown(listener.dispose);
    go(toBack);
    expect(file.existsSync(), isFalse);
    go(toFront);
    expect(file.existsSync(), isTrue);
    expect(nextStart(exits: [
      {'time': DateTime.now().millisecondsSinceEpoch + 1000, 'code': 16}
    ]), LastRun.ended);
  });

  test('records that could not be read are not taken for a crash', () {
    file.writeAsStringSync(DateTime.now().toIso8601String());
    expect(nextStart(exits: null), LastRun.reasonUnknown);
  });
}
