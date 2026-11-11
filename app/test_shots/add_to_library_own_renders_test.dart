// Add to Library with the YOUR OWN group at the top of Discover's Resources, and Discover opened normally (unchanged), at 390 x 844
// and 1440 x 900 in light, dark and Tactical, drawn by the app's own widgets with sample data.
// flutter test test_shots/add_to_library_own_renders_test.dart --update-goldens  (pictures in test_shots/add_to_library_own/)

import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/discover/ui/discover_screen.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/add_pdf/add_pdf_world.dart';
import '../test/support/discover_fakes.dart';
import 'shot_kit.dart';

const _out = 'add_to_library_own';

const Map<String, Size> kSizes = {'390': Size(390, 844), '1440': Size(1440, 900)};

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(loadShotFonts);

  late AddPdfWorld w;
  tearDown(() => w.dispose());

  for (final size in kSizes.keys) {
    testWidgets('Add to Library and Discover at $size', (tester) async {
      await tester.runAsync(() async => w = await AddPdfWorld.make());
      final dev = FakeDiscoverDevice();
      final d = await makeDiscover(dev);
      for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
        for (final (name, page) in <(String, Widget Function())>[
          (
            'add-to-library',
            () => DiscoverScreen(
              discover: d,
              face: DiscoverFace.resources,
              yourOwn: YourOwnGroup.forBrowse(w.browse),
              links: DiscoverLinks(allLibraries: (_) {}, allMaps: (_) {}, ownSource: (_) {}),
            ),
          ),
          ('discover', () => DiscoverScreen(discover: d, links: DiscoverLinks(allLibraries: (_) {}, allMaps: (_) {}))),
        ]) {
          phone(tester, size: kSizes[size]!, ratio: size == '390' ? 2 : 1);
          await tester.pumpWidget(shotApp(page(), theme: theme, insets: size == '390' ? const EdgeInsets.only(top: 44, bottom: 30) : EdgeInsets.zero));
          await _settle(tester);
          await snap(tester, _out, '$size-$name-${theme.name}');
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
