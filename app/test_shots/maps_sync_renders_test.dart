// Deleting a region (owner's design, 2026-11-15, Maps sync): the same confirmation as deleting a book. It asks "Delete this region?"
// with Cancel and Delete and, when Maps is synced with a linked device, the line "Deleting this will delete this from all synced
// devices.". 390 wide, light. Before: the pop-up the 1.1 builds ask (what it frees, and what is removed from this device).
// flutter test test_shots/maps_sync_renders_test.dart --update-goldens  (pictures in test_shots/maps_sync/)
import 'package:cache/regions/ui/region_actions.dart' show confirmDeleteRegion;
import 'package:cache/screens/download_confirm.dart' show confirmDelete;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  const folder = 'maps_sync';

  Future<void> shot(WidgetTester tester, String name, Future<bool> Function(BuildContext) ask) async {
    phone(tester, size: const Size(390, 844), ratio: 2);
    await tester.pumpWidget(shotApp(Scaffold(
      appBar: AppBar(title: const Text('Regions')),
      body: Builder(builder: (context) => Center(child: FilledButton(key: const ValueKey('ask'), onPressed: () => ask(context), child: const Text('Delete region')))),
    )));
    await tester.tap(find.byKey(const ValueKey('ask')));
    await tester.pumpAndSettle();
    await snap(tester, folder, name);
  }

  testWidgets('before: the pop-up the 1.1 builds ask', (tester) async {
    await shot(
      tester,
      '1-before-delete-confirmation',
      (c) => confirmDelete(c, name: 'Twin Falls County', bytes: 412 << 20, again: 'Its map, directions, places and off-road data are removed from this device. Parts another region uses stay.'),
    );
  });

  testWidgets('after: the region delete, synced with another device', (tester) async {
    await shot(tester, '2-after-delete-confirmation-synced', (c) => confirmDeleteRegion(c, synced: true));
  });

  testWidgets('after: the region delete, not synced', (tester) async {
    await shot(tester, '3-after-delete-confirmation-not-synced', (c) => confirmDeleteRegion(c, synced: false));
  });
}
