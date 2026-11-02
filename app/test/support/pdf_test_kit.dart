import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Takes the reader away and lets the PDF viewer's own delayed work run out (it waits on short timers after a document loads).
Future<void> readerDone(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// A widget test of the reader, tidied up after.
void readerTest(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await readerDone(tester);
    });
