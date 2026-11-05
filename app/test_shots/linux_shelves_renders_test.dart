import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_library_page.dart';
import 'package:cache/browse/web/build_shelves.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test/browse/build_fakes.dart';
import 'shot_kit.dart';

const shelves = [
  BuildClass('200', 'Medicine', [
    BuildDivision(number: '210', name: 'First aid', classNumber: '200'),
    BuildDivision(number: '220', name: 'Medical care', classNumber: '200'),
  ]),
  BuildClass('500', 'Water and food', [BuildDivision(number: '530', name: 'Water treatment', classNumber: '500')]),
];

class ShelfApi extends FakeBuildApi implements BuildFilingApi {
  @override
  Future<List<BuildClass>> classes(String libraryId) async => shelves;
  @override
  Future<void> placeBook(String libraryId, String bookId, String division) async {}
}

void main() {
  setUpAll(loadShotFonts);
  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('Linux shelves and placement ${theme.name}', (tester) async {
      phone(tester, size: const Size(1440, 900), ratio: 1);
      final api = ShelfApi()
        ..libs = [const BuildLibrary(id: 'sample', title: 'Field library', books: 3, passages: 958, pages: 660)]
        ..bookMap['sample'] = [
          const BuildBook(
            id: 'a',
            title: 'Wilderness First Aid',
            division: '210',
            callNumber: 'CDS 210-001',
            pages: 230,
            passages: 340,
            size: 41000000,
          ),
          const BuildBook(
            id: 'b',
            title: 'The Water Purification Handbook',
            division: '530',
            callNumber: 'CDS 530-001',
            pages: 312,
            passages: 465,
            size: 28000000,
          ),
          const BuildBook(
            id: 'c',
            title: 'Practical Medical Notes',
            pages: 118,
            passages: 153,
            size: 15000000,
            unsureReason: 'More than one subject could fit this book.',
            suggestions: [BuildSuggestion('210', 'First aid'), BuildSuggestion('220', 'Medical care')],
          ),
        ];
      final controller = BuildController(api: api, poll: false);
      await controller.start();
      await tester.pumpWidget(
        shotApp(
          BuiltLibraryPage(build: controller, libraryId: 'sample'),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linux-shelves', '1440-library-${theme.name}');
      await tester.pumpWidget(
        shotApp(
          const Scaffold(
            body: PlaceBookDialog(
              book: BuildBook(
                id: 'c',
                title: 'Practical Medical Notes',
                unsureReason: 'More than one subject could fit this book.',
                suggestions: [BuildSuggestion('210', 'First aid'), BuildSuggestion('220', 'Medical care')],
              ),
              classes: shelves,
            ),
          ),
          theme: theme,
          insets: EdgeInsets.zero,
        ),
      );
      await tester.pumpAndSettle();
      await snap(tester, 'linux-shelves', '1440-place-${theme.name}');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
