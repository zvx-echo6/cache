import 'dart:convert';
import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_shelves.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const classes = [
  BuildClass('200', 'Medicine', [
    BuildDivision(number: '210', name: 'First aid', classNumber: '200'),
    BuildDivision(number: '220', name: 'Care', classNumber: '200'),
    BuildDivision(number: '060', name: 'Unassigned', classNumber: '200', assigned: false),
  ]),
];

void main() {
  test('filing fields survive the device API and permanent numbers sort numerically', () async {
    final api = HttpBuildApi(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          expect(request.url.path, '/api/build/libraries/lib/books/book/place');
          expect(jsonDecode(request.body), {'division': '210'});
          return http.Response(jsonEncode({'ok': true, 'result': {}}), 200);
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'result': [
              {
                'id': 'book',
                'title': 'First aid',
                'division': '210',
                'call_number': 'CDS 210-1000',
                'suggestions': [
                  {'division': '210', 'name': 'First aid', 'score': 0.8},
                ],
                'compression': {'stored_size': 90, 'original_size': 100, 'level': 'lossless'},
              },
            ],
          }),
          200,
        );
      }),
    );
    final b = (await api.books('lib')).single;
    expect(b.division, '210');
    expect(b.suggestions.single.name, 'First aid');
    expect(b.compression!['stored_size'], 90);
    final books = [b, const BuildBook(id: 'old', title: 'Earlier', division: '210', callNumber: 'CDS 210-999')];
    books.sort(compareShelfBooks);
    expect(books.first.id, 'old');
    await api.placeBook('lib', b.id, '210');
  });

  testWidgets('placement uses stored suggestions and excludes unassigned divisions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<String>(
                context: context,
                builder: (_) => const PlaceBookDialog(
                  book: BuildBook(
                    id: 'scan',
                    title: 'A medical scan',
                    unsureReason: 'Choose where this book belongs.',
                    suggestions: [BuildSuggestion('210', 'First aid'), BuildSuggestion('060', 'Unassigned')],
                  ),
                  classes: classes,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('060'), findsNothing);
    expect(find.text('Choose where this book belongs.'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '210 First aid'));
    await tester.pumpAndSettle();
    expect(find.text('Place it in 210'), findsOneWidget);
    expect(find.textContaining('The file moves to 200 Medicine / 210 First aid.'), findsOneWidget);
    await tester.tap(find.text('Place it in 210'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaceBookDialog), findsNothing);
  });
}
