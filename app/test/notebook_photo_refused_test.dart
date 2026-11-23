import 'package:cache/notebook/media.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'support/notebook_fake.dart';

void main() {
  final before = pickPhoto;
  tearDown(() => pickPhoto = before);

  Future<FakeNotebookBackend> open(WidgetTester tester) async {
    final store = FakeNotebookBackend();
    final nb = fakeNotebook(store);
    await tester.runAsync(nb.start);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: EntryEditor(notebook: nb, book: nb.journal!, places: PlaceChoices.none)));
    await tester.pump();
    return store;
  }

  for (final code in ['camera_access_denied', 'camera_access_restricted']) {
    testWidgets('Take photo with the camera refused ($code) says so plainly, and the entry still works and saves', (tester) async {
      ImageSource? asked;
      pickPhoto = (source) async {
        asked = source;
        throw PlatformException(code: code, message: 'The user did not allow camera access.');
      };
      final store = await open(tester);
      await tester.enterText(find.byKey(const ValueKey('editor-title')), 'Fuel stop');
      await tester.tap(find.byKey(const ValueKey('add-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take photo'));
      await tester.pumpAndSettle();
      expect(asked, ImageSource.camera);
      expect(find.text("Cache can't use the camera. You can still choose a photo from your phone."), findsOneWidget);
      expect(find.byKey(const ValueKey('add-photo')), findsOneWidget, reason: 'no photo was added; the editor is as it was');
      // the rest of the editor works: more text, then Done saves the entry
      await tester.enterText(find.byKey(const ValueKey('editor-text')), 'Filled up');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('editor-done')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(store.entries, hasLength(1));
      expect(store.entries.single['title'], 'Fuel stop');
      expect(store.entries.single['body'], 'Filled up');
    });
  }

  testWidgets('another picker error keeps its own message', (tester) async {
    pickPhoto = (source) async => throw PlatformException(code: 'other', message: 'boom');
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take photo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not add the photo'), findsOneWidget);
  });
}
