// "Update Cache to use it" (a source list in a newer format) goes to the update: everything that points to something links to it.

import 'package:cache/screens/settings/weather_page.dart' show CatalogueErrorNote;
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart' show AppUpdate, AppUpdateSource;
import 'package:cache/update/update_ui.dart' show AppUpdates, currentAppUpdates;
import 'package:cache/weather/catalogue.dart' show kNewerCatalogueFormat;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoUpdate implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => null;
}

void main() {
  testWidgets('the newer-format note carries Update Cache, which opens the update; any other note stays a note', (tester) async {
    final opened = <String>[];
    final before = currentAppUpdates;
    currentAppUpdates = AppUpdates(source: _NoUpdate(), openUrl: (u) async => opened.add(u), android: true);
    addTearDown(() => currentAppUpdates = before);
    Future<void> show(String text) => tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: Scaffold(body: CatalogueErrorNote(text))));
    await show("Couldn't load the list of sources.");
    expect(find.text('Update Cache'), findsNothing);
    await show(kNewerCatalogueFormat);
    expect(find.text(kNewerCatalogueFormat), findsOneWidget);
    await tester.tap(find.text('Update Cache'));
    expect(opened.single, startsWith('market://details?id='));
  });
}
