import 'dart:async';
import 'package:cache/browse/library_passage_screen.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/search/search_access.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ReaderAccess implements SearchAccess {
  ReaderAccess(this.load);
  final Future<ReadPage> Function(String) load;
  final List<String> addresses = [];
  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async => const [];
  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) {
    expect(maxChars, 6000);
    addresses.add(address);
    return load(address);
  }
}

Widget screen(ReaderAccess source, String address) => MaterialApp(
  theme: buildTheme(CacheThemeId.dark),
  home: LibraryPassageScreen(sources: source, address: address),
);

void main() {
  testWidgets('loading becomes selectable verbatim text with a page; rebuild does not read again', (tester) async {
    final pending = Completer<ReadPage>();
    final source = ReaderAccess((_) => pending.future);
    await tester.pumpWidget(screen(source, 'lib:field/passage'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(const ReadPage(title: 'Field Manual', text: '<b>Keep the exact words.</b>', truncated: false, page: 47));
    await tester.pumpAndSettle();
    expect(find.text('Field Manual'), findsOneWidget);
    expect(find.text('Page 47'), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('library-passage-text'))).data, '<b>Keep the exact words.</b>');
    await tester.pumpWidget(screen(source, 'lib:field/passage'));
    await tester.pumpAndSettle();
    expect(source.addresses, ['lib:field/passage']);
  });

  testWidgets('a failed read can be retried', (tester) async {
    var tries = 0;
    final source = ReaderAccess((_) async {
      if (++tries == 1) throw StateError('unavailable');
      return const ReadPage(title: 'Recovered passage', text: 'The saved text.', truncated: false);
    });
    await tester.pumpWidget(screen(source, 'lib:field/passage'));
    await tester.pumpAndSettle();
    expect(find.text('This passage could not be opened.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-library-passage')));
    await tester.pumpAndSettle();
    expect(find.text('The saved text.'), findsOneWidget);
    expect(tries, 2);
  });

  testWidgets('an old in-flight read cannot replace the new selection', (tester) async {
    final first = Completer<ReadPage>(), second = Completer<ReadPage>();
    final source = ReaderAccess((address) => address == 'lib:field/first' ? first.future : second.future);
    await tester.pumpWidget(screen(source, 'lib:field/first'));
    await tester.pumpWidget(screen(source, 'lib:field/second'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    second.complete(const ReadPage(title: 'New selection', text: 'New text.', truncated: false));
    await tester.pumpAndSettle();
    first.complete(const ReadPage(title: 'Old selection', text: 'Old text.', truncated: false));
    await tester.pumpAndSettle();
    expect(find.text('New text.'), findsOneWidget);
    expect(find.text('Old text.'), findsNothing);
    expect(find.text('Old selection'), findsNothing);
  });

  testWidgets('the reader returns to the Library route', (tester) async {
    final source = ReaderAccess((_) async => const ReadPage(title: 'Field Manual', text: 'Saved text.', truncated: false));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LibraryPassageScreen(sources: source, address: 'lib:field/passage'),
                ),
              ),
              child: const Text('Library'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Saved text.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to Library'));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect(find.byType(LibraryPassageScreen), findsNothing);
  });

  testWidgets('changing the source backend reloads; truncated text is labelled', (tester) async {
    final old = ReaderAccess((_) async => const ReadPage(title: 'Old', text: 'Old text.', truncated: false));
    await tester.pumpWidget(screen(old, 'lib:field/passage'));
    await tester.pumpAndSettle();
    final next = ReaderAccess((_) async => const ReadPage(title: 'New', text: 'Part of the text.', truncated: true));
    await tester.pumpWidget(screen(next, 'lib:field/passage'));
    await tester.pumpAndSettle();
    expect(find.text('Part of the text.'), findsOneWidget);
    expect(find.text('Showing part of this text.'), findsOneWidget);
    expect(next.addresses, ['lib:field/passage']);
  });
}
