import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart';
import 'package:cache/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Newer implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => const AppUpdate(version: '9.9.9', build: 999);
}

void main() {
  // build 46: the first letter typed in Home's search box closed the keyboard. The update banner left the list while typing, the
  // search box moved up one place and was made again, and its focus was lost.
  testWidgets('typing in Home search keeps the field and its focus while the update banner hides', (tester) async {
    final dir = Directory.systemTemp.createTempSync('home-focus');
    final layout = LayoutState(settingsDirOverride: dir);
    await tester.runAsync(layout.init);
    final updates = AppUpdates(source: _Newer(), openUrl: (_) async {}, android: true);
    await tester.runAsync(updates.check);
    expect(updates.bannerShown, isTrue);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: HomeScreen(layout: layout, updates: updates, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-banner')), findsOneWidget);

    final field = find.byKey(const ValueKey('home-search'));
    await tester.tap(field);
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
    expect(editable.widget.focusNode.hasFocus, isTrue);

    var text = '';
    for (final ch in 'water'.split('')) {
      text += ch;
      // Typed into the field that has the keyboard, as a person does (tester.enterText would focus the field again first).
      tester.testTextInput.enterText(text);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final now = tester.state<EditableTextState>(find.descendant(of: field, matching: find.byType(EditableText)));
      expect(identical(now, editable), isTrue, reason: 'the text field was made again after "$text"');
      expect(now.widget.focusNode.hasFocus, isTrue, reason: 'focus lost after "$text"');
    }
    expect(find.byKey(const ValueKey('update-banner')), findsNothing, reason: 'the banner hides while typing');
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the keyboard stays open');

    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    updates.dispose();
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
