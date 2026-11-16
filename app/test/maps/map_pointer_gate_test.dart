import 'dart:async';

import 'package:cache/layout/modal_watch.dart';
import 'package:cache/maps/ui/map_pointer_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<bool> calls;

  Widget app({bool web = true, bool extraBlock = false}) {
    calls = [];
    return MaterialApp(
      navigatorObservers: [ModalWatchObserver()],
      home: MapPointerGate(setter: calls.add, web: web, extraBlock: extraBlock, child: const Scaffold(body: Text('the map'))),
    );
  }

  setUp(modalWatch.reset);

  group('the browser map lets pointer events through while a sheet, dialog or menu is open over it', () {
    testWidgets('a dialog: the map ignores pointer events, then takes them back', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      expect(calls.isEmpty || calls.last == false, isTrue);
      final closed = showDialog<void>(context: tester.element(find.text('the map')), builder: (_) => const AlertDialog(title: Text('Remove it?')));
      await tester.pumpAndSettle();
      expect(find.text('Remove it?'), findsOneWidget);
      expect(calls.last, isTrue);
      Navigator.of(tester.element(find.text('Remove it?'))).pop();
      await closed;
      await tester.pumpAndSettle();
      expect(calls.last, isFalse);
    });

    testWidgets('a bottom sheet: ignored while it is open, taken back when its scrim is tapped', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      unawaited(showModalBottomSheet<void>(context: tester.element(find.text('the map')), builder: (_) => const SizedBox(height: 120, child: Text('Layers'))));
      await tester.pumpAndSettle();
      expect(calls.last, isTrue);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Layers'), findsNothing);
      expect(calls.last, isFalse);
    });

    testWidgets('a map made while a dialog is already open starts out ignoring pointer events', (tester) async {
      modalWatch.pushed(RawDialogRoute<void>(pageBuilder: (_, _, _) => const SizedBox()));
      await tester.pumpWidget(app());
      await tester.pump();
      expect(calls, isNotEmpty);
      expect(calls.last, isTrue);
    });

    testWidgets('a page pushed over the map is not a sheet, dialog or menu: the map is left alone', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      final before = calls.length;
      unawaited(Navigator.of(tester.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('a page')))));
      await tester.pumpAndSettle();
      expect(find.text('a page'), findsOneWidget);
      expect(calls.length, before);
    });

    testWidgets('extraBlock (the ring is open): the map ignores pointer events with no modal open, and takes them back when it is off', (tester) async {
      await tester.pumpWidget(app(extraBlock: true));
      await tester.pump();
      expect(modalWatch.isOpen, isFalse);
      expect(calls.last, isTrue);
      await tester.pumpWidget(app(extraBlock: false));
      await tester.pump();
      expect(calls.last, isFalse);
    });

    testWidgets('extraBlock stays on while a dialog opens and closes over the ring', (tester) async {
      await tester.pumpWidget(app(extraBlock: true));
      await tester.pump();
      final closed = showDialog<void>(context: tester.element(find.text('the map')), builder: (_) => const AlertDialog(title: Text('Remove it?')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Remove it?'))).pop();
      await closed;
      await tester.pumpAndSettle();
      expect(calls.last, isTrue);
    });

    testWidgets('not a browser (a phone): the map element is never touched', (tester) async {
      await tester.pumpWidget(app(web: false, extraBlock: true));
      await tester.pump();
      unawaited(showDialog<void>(context: tester.element(find.text('the map')), builder: (_) => const AlertDialog(title: Text('Remove it?'))));
      await tester.pumpAndSettle();
      expect(find.text('Remove it?'), findsOneWidget);
      expect(calls, isEmpty);
    });
  });
}
