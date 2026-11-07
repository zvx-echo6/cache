import 'package:cache/browse/library_passage_screen.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/search/search_access.dart';
import 'package:cache/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'shot_kit.dart';

class PassageSource implements SearchAccess {
  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async => const [];
  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) async => const ReadPage(
    title: 'Keeping field notes',
    page: 47,
    truncated: false,
    text:
        'A useful field notebook keeps observations in the order they were made. Give each entry a date, a place and a clear heading. Leave enough room to add a sketch or a correction later.\n\nWhen you return to a subject, refer back to the earlier entry. Keeping the original observations beside the later notes makes it easier to see what changed.',
  );
}

void main() {
  setUpAll(loadShotFonts);
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('saved passage ${theme.name}', (tester) async {
      phone(tester, size: const Size(1440, 900), ratio: 1);
      await tester.pumpWidget(
        shotApp(
          LibraryPassageScreen(sources: PassageSource(), address: 'lib:field/notes'),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linux-passage', '1440-passage-${theme.name}');
    });
  }
}
