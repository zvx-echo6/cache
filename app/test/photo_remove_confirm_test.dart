import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/screens/notebooks/field_inputs.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

void main() {
  Future<List<List<String>>> pump(WidgetTester tester) async {
    final NotebookState nb = fakeNotebook(FakeNotebookBackend());
    final calls = <List<String>>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(body: PhotoStrip(notebook: nb, ids: const ['a', 'b'], onChanged: calls.add)),
    ));
    await tester.longPress(find.byKey(const ValueKey('photo-a')));
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('hold on a photo asks; Cancel keeps it and removes nothing', (tester) async {
    final calls = await pump(tester);
    expect(find.text('Remove this photo?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(calls, isEmpty, reason: 'nothing is removed before the answer');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byKey(const ValueKey('photo-a')), findsOneWidget);
  });

  testWidgets('dismissing the question keeps the photo', (tester) async {
    final calls = await pump(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Remove this photo?'), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('hold, then Remove takes that photo out', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(calls, [
      ['b']
    ]);
  });
}
