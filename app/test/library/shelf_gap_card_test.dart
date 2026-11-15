// A library made before Cache could shelve books: the card says so and that they are still searchable. It used to say "Update
// the library", which points to an action no library has (only ZIMs have Check for update): words that point somewhere link
// there, and these pointed nowhere.

import 'package:cache/library/shelf_source.dart' show ShelfGap;
import 'package:cache/library/shelves_pages.dart' show ShelfGapCard;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the not-on-your-shelves card names the library and says the books are searchable, and points nowhere else', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: const Scaffold(body: ShelfGapCard(gap: ShelfGap('Field library', 2)))));
    expect(find.text("2 books in Field library aren't on your shelves"), findsOneWidget);
    expect(find.text('This library was made before Cache could shelve books. They are still searchable.'), findsOneWidget);
    expect(find.textContaining('Update the library'), findsNothing);
  });
}
