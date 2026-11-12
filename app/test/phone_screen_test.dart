// The phone's interface is built anew for each phone screen. On Android the app outlives its screen (the engine is kept for the
// life of the process), so a screen that Android closed is followed by a new one on the same running app: the new screen must
// come up on the first page, built from the start, with everything the old screen's interface held disposed first.

import 'package:cache/platform/phone_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A piece of the interface that writes down when it is made and when it goes, and holds a number of its own.
class _Probe extends StatefulWidget {
  const _Probe(this.log);

  final List<String> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static int made = 0;
  late final int id;
  int taps = 0;

  @override
  void initState() {
    super.initState();
    id = ++made;
    widget.log.add('made $id');
  }

  @override
  void dispose() {
    widget.log.add('gone $id');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => taps++),
        child: Text('probe $id taps $taps', textDirection: TextDirection.ltr),
      );
}

/// The states Flutter goes through when Android closes the phone's screen (the activity is destroyed).
const _closing = [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached];

void _go(WidgetTester tester, List<AppLifecycleState> states) {
  for (final s in states) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  late List<String> log;
  late int screens;

  setUp(() {
    log = [];
    screens = 0;
    _ProbeState.made = 0;
  });

  Widget scope({WidgetBuilder? builder}) => PhoneScreenScope(
        onScreen: () => screens++,
        placeholder: const Text('between screens', textDirection: TextDirection.ltr),
        builder: builder ?? (context) => _Probe(log),
      );

  testWidgets('a new screen after the last one went gets the interface built from the start, the old one disposed first', (tester) async {
    await tester.pumpWidget(scope());
    _go(tester, [AppLifecycleState.resumed]);
    await tester.pump();
    await tester.tap(find.byType(_Probe));
    await tester.pump();
    expect(find.text('probe 1 taps 1'), findsOneWidget);
    expect(log, ['made 1']);

    // Android closes the screen. The app goes on running: nothing is built or disposed while it has no screen.
    _go(tester, _closing);
    await tester.pump();
    expect(log, ['made 1']);

    // A new screen: the old interface goes in one frame...
    _go(tester, [AppLifecycleState.resumed]);
    await tester.pump();
    expect(log, ['made 1', 'gone 1']);
    expect(find.text('between screens'), findsOneWidget);
    expect(find.byType(_Probe), findsNothing);
    // ...and the new one is built in the next, with nothing of the old in it.
    await tester.pump();
    expect(log, ['made 1', 'gone 1', 'made 2']);
    expect(find.text('probe 2 taps 0'), findsOneWidget);
    expect(find.text('between screens'), findsNothing);
  });

  testWidgets('the new screen opens on the first page: pages opened on the old screen are closed', (tester) async {
    await tester.pumpWidget(scope(
      builder: (context) => MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                _Probe(log),
                TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('a page opened on top')))),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    _go(tester, [AppLifecycleState.resumed]);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('a page opened on top'), findsOneWidget);

    _go(tester, _closing);
    _go(tester, [AppLifecycleState.resumed]);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('a page opened on top'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(log, ['made 1', 'gone 1', 'made 2']);
  });

  testWidgets('the same screen going to the back and coming to the front again keeps its interface', (tester) async {
    await tester.pumpWidget(scope());
    _go(tester, [AppLifecycleState.resumed]);
    await tester.tap(find.byType(_Probe));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      _go(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
      await tester.pump();
      _go(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
      await tester.pump();
      await tester.pump();
    }
    expect(log, ['made 1']);
    expect(find.text('probe 1 taps 1'), findsOneWidget);
    expect(screens, 1, reason: 'the screen came once');
  });

  testWidgets('each screen that comes to the front for the first time is told of, once', (tester) async {
    await tester.pumpWidget(scope());
    expect(screens, 0, reason: 'no screen yet: the car may have started the app');
    // Shown but not in front yet (the window has no focus): not counted until it is.
    _go(tester, [AppLifecycleState.inactive]);
    expect(screens, 0);
    _go(tester, [AppLifecycleState.resumed]);
    expect(screens, 1);
    await tester.pump();
    expect(log, ['made 1'], reason: 'the first screen takes the interface that was built for it');
    // The second and the third screen.
    for (var n = 2; n <= 3; n++) {
      _go(tester, _closing);
      _go(tester, [AppLifecycleState.resumed]);
      // A new screen that comes up without focus is "resumed, inactive", then resumed again when it has it.
      _go(tester, [AppLifecycleState.inactive, AppLifecycleState.resumed]);
      expect(screens, n);
      await tester.pump();
      await tester.pump();
    }
    expect(log, ['made 1', 'gone 1', 'made 2', 'gone 2', 'made 3']);
  });

  testWidgets('a screen that was already in front when the app started is not told of again', (tester) async {
    _go(tester, [AppLifecycleState.resumed]);
    await tester.pumpWidget(scope());
    _go(tester, [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect(screens, 0);
    expect(log, ['made 1']);
  });

  // The car started the app with the phone app closed and has left: the car side says inactive, paused and detached, never
  // resumed (android/.../car/SharedEngine.kt). The first phone screen after that is a new screen like any other.
  testWidgets('after the car that started the app has left, the first phone screen gets the interface built from the start', (tester) async {
    await tester.pumpWidget(scope());
    _go(tester, _closing);
    await tester.pump();
    expect(screens, 0);
    expect(log, ['made 1']);
    _go(tester, [AppLifecycleState.resumed]);
    expect(screens, 1);
    await tester.pump();
    await tester.pump();
    expect(log, ['made 1', 'gone 1', 'made 2']);
  });

  testWidgets('a screen that goes again before its interface was built still ends with one interface, for the last screen', (tester) async {
    await tester.pumpWidget(scope());
    _go(tester, [AppLifecycleState.resumed]);
    _go(tester, _closing);
    _go(tester, [AppLifecycleState.resumed]);
    // Gone again before a frame was drawn for it.
    _go(tester, _closing);
    _go(tester, [AppLifecycleState.resumed]);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(log, ['made 1', 'gone 1', 'made 2']);
    expect(find.byType(_Probe), findsOneWidget);
    expect(screens, 3);
  });
}
