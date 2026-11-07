import 'package:cache/browse/web/build_page.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/compression_settings_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test/browse/web_compression_upload_test.dart' show CompressionTestApi;
import '../test/browse/web_fakes.dart' show FakeLocalFile;
import 'shot_kit.dart';

void main() {
  setUpAll(loadShotFonts);
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('Linux compression settings and single book ${theme.name}', (tester) async {
      phone(tester, size: const Size(1440, 1000), ratio: 1);
      final api = CompressionTestApi();
      final c = BuildController(api: api, poll: false);
      await tester.pumpWidget(
        shotApp(
          CompressionSettingsPage(build: c),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linux-compression', '1440-settings-${theme.name}');
      await tester.tap(find.text('Smaller scans'));
      await tester.pumpAndSettle();
      await snap(tester, 'linux-compression', '1440-settings-scans-${theme.name}');
      await tester.pumpWidget(
        shotApp(
          BuildPage(build: c, initialFiles: [FakeLocalFile('Wilderness first aid.pdf', 58000000)]),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('library-name')), 'Field books');
      await tester.pumpAndSettle();
      await snap(tester, 'linux-compression', '1440-single-${theme.name}');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
