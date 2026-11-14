import 'dart:async';
import 'package:cache/browse/library_document_screen.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/search/search_access.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DocumentAccess implements SearchAccess {
  DocumentAccess(this.load, {this.passage = ''});
  final Future<ReadDocument> Function(String) load;
  final String passage;
  final List<String> documentReads = [];
  @override
  Future<List<SourceResult>> search(String query, {int k = 5}) async => const [];
  @override
  Future<ReadPage> read(String address, {int maxChars = 6000}) async => ReadPage(title: 'T', text: passage, truncated: false);
  @override
  Future<ReadDocument> readDocument(String address) {
    documentReads.add(address);
    return load(address);
  }
}

Widget screen(DocumentAccess source) => MaterialApp(
  theme: buildTheme(CacheThemeId.dark),
  home: LibraryDocumentScreen(sources: source, address: 'lib:field/3'),
);

String textOf(WidgetTester tester, Key key) {
  final w = tester.widget<SelectableText>(find.byKey(key));
  return w.data ?? w.textSpan!.toPlainText();
}

ReadDocument manual({int atPage = 0, bool truncated = false}) => ReadDocument(
  title: 'Field Manual',
  atPage: atPage,
  truncated: truncated,
  pages: [
    for (var i = 0; i < 40; i++)
      DocumentPageText(
        pageLabel: i == 5 ? null : '${i + 1}',
        text: 'Page ${i + 1} first passage.\n\nPage ${i + 1} second passage.',
        addresses: ['lib:field/${i * 2}', 'lib:field/${i * 2 + 1}'],
      ),
  ],
);

void main() {
  testWidgets('pages come in order, each with its heading, and the title is in the bar', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = DocumentAccess((_) async => manual());
    await tester.pumpWidget(screen(source));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Field Manual'), findsOneWidget);
    expect(textOf(tester, const ValueKey('document-page-text-0')), 'Page 1 first passage.\n\nPage 1 second passage.');
    expect(find.text('p. 1'), findsOneWidget);
    expect(find.text('p. 2'), findsOneWidget);
    final y = [for (var i = 0; i < 3; i++) tester.getTopLeft(find.byKey(ValueKey('document-page-text-$i'))).dy];
    expect(y[0] < y[1] && y[1] < y[2], isTrue, reason: '$y');
    // the pages are built as they come into view: the last of 40 is not there yet
    expect(find.byKey(const ValueKey('document-page-text-39')), findsNothing);
    // a page without a label has no heading
    await tester.scrollUntilVisible(find.byKey(const ValueKey('document-page-text-5')), 500, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('document-page-heading-5')), findsNothing);
    expect(find.text('p. 6'), findsNothing);
    expect(source.documentReads, ['lib:field/3']);
  });

  testWidgets('opens at the page holding the opened passage, and marks that passage', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = DocumentAccess((_) async => manual(atPage: 10), passage: 'Page 11 second passage.');
    await tester.pumpWidget(screen(source));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.byKey(const ValueKey('document-page-heading-10'))).dy;
    expect(top, lessThan(120), reason: 'the opened page is at the top of the view');
    expect(find.byKey(const ValueKey('document-page-text-10')).hitTestable(), findsOneWidget);
    // only the opened passage carries the wash
    final span = tester.widget<SelectableText>(find.byKey(const ValueKey('document-page-text-10'))).textSpan!;
    final marked = [for (final c in span.children!) if ((c as TextSpan).style?.backgroundColor != null) c.text];
    expect(marked, ['Page 11 second passage.']);
    expect(textOf(tester, const ValueKey('document-page-text-10')), 'Page 11 first passage.\n\nPage 11 second passage.');
    // the pages before it are above, in order
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('p. 10'), findsOneWidget);
    // another page is not marked
    final other = tester.widget<SelectableText>(find.byKey(const ValueKey('document-page-text-9')));
    expect(other.data, isNotNull);
  });

  testWidgets('a cut document says so at the end', (tester) async {
    final source = DocumentAccess((_) async => const ReadDocument(title: 'Short', truncated: true, pages: [DocumentPageText(text: 'Only page.', pageLabel: '1')]));
    await tester.pumpWidget(screen(source));
    await tester.pumpAndSettle();
    expect(find.text('Only page.'), findsOneWidget);
    expect(find.text('The rest of this document is too long to show here.'), findsOneWidget);
  });

  testWidgets('a failed read can be retried', (tester) async {
    var tries = 0;
    final source = DocumentAccess((_) async {
      if (++tries == 1) throw StateError('unavailable');
      return const ReadDocument(title: 'Recovered', pages: [DocumentPageText(text: 'The saved text.', pageLabel: '1')]);
    });
    await tester.pumpWidget(screen(source));
    await tester.pumpAndSettle();
    expect(find.text('This document could not be opened.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-library-document')));
    await tester.pumpAndSettle();
    expect(find.text('The saved text.'), findsOneWidget);
    expect(find.text('Recovered'), findsOneWidget);
    expect(tries, 2);
  });

  testWidgets('the loading spinner shows until the document arrives', (tester) async {
    final pending = Completer<ReadDocument>();
    await tester.pumpWidget(screen(DocumentAccess((_) => pending.future)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(const ReadDocument(title: 'D', pages: [DocumentPageText(text: 'x', pageLabel: '1')]));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
