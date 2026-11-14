// The Delete book sheet on a phone (owner decisions, 2026-11-14): one red button, "Delete from all your devices", with the book's
// title, its size and "can't be undone"; and the sheet for a book of a library the person did not make. 390 and 320 wide, light and
// dark. The words are drafts (lib/library/book_pages.dart; the two marked WORDING QUESTION). Sample data: a made-up book.
// flutter test test_shots/delete_book_renders_test.dart --update-goldens  (pictures in test_shots/delete_book/)
import 'package:cache/library/book_pages.dart';
import 'package:cache/library/shelf_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

class _Files extends ChangeNotifier implements BookFiles {
  _Files({this.yours = true});
  final bool yours;
  @override
  BookFileState stateOf(ShelfBook book) => BookFileState.unknown;
  @override
  Future<void> Function()? download(ShelfBook book) => null;
  @override
  bool get canRemove => false;
  @override
  Future<(RemoveOutcome, int, int)> removeFromDevice(List<ShelfBook> books) async => (RemoveOutcome.noLinkedDevice, 0, books.length);
  @override
  bool get canDeleteEverywhere => true;
  @override
  bool canDeleteBook(ShelfBook book) => yours;
  @override
  Future<void> deleteEverywhere(ShelfBook book) async {}
}

const _book = ShelfBook(id: 'water', title: 'The water purification handbook', shelf: '530', callNumber: 'CDS 530-001', bytes: 18 << 20, libraryName: 'My books');

void main() {
  setUpAll(loadShotFonts);
  for (final (width, height) in [(390.0, 844.0), (320.0, 640.0)]) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      for (final yours in [true, false]) {
        if (!yours && width != 390) continue;
        final name = '${yours ? 'delete' : 'not-yours'}-${width.toInt()}-${theme.name}';
        testWidgets('the Delete book sheet: $name', (tester) async {
          phone(tester, size: Size(width, height), ratio: 2);
          await tester.pumpWidget(shotApp(
            Builder(
              builder: (context) => Scaffold(
                appBar: AppBar(title: const Text('Bookshelves')),
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open'),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      builder: (_) => DeleteBookSheet(files: _Files(yours: yours), book: _book),
                    ),
                    child: const Text('Delete book'),
                  ),
                ),
              ),
            ),
            theme: theme,
          ));
          await tester.tap(find.byKey(const ValueKey('open')));
          await tester.pumpAndSettle();
          await snap(tester, 'delete_book', name);
        });
      }
    }
  }
}
