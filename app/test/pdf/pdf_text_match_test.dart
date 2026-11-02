import 'package:cache/pdf/pdf_text_match.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _norms(String s) => [for (final w in pdfWords(s)) w.norm];

void main() {
  test('words: case and punctuation go, a word broken at a line end is one word, ligatures are letters', () {
    expect(_norms('Boil it, then COOL it.'), ['boil', 'it', 'then', 'cool', 'it']);
    expect(_norms('in a prepared-\nness kit'), ['in', 'a', 'preparedness', 'kit']);
    expect(_norms('a prepared\u0002ness kit'), ['a', 'preparedness', 'kit']);
    expect(_norms('well-known'), ['well', 'known']);
    expect(_norms('\uFB01lter the water'), ['filter', 'the', 'water']);
    final w = pdfWords('ab cd');
    expect([w[1].start, w[1].end], [3, 5]);
  });

  const page = 'Water and Shelter Handbook, page 3\n'
      'Every family should keep a three day supply of water: four litres for\n'
      'each person each day, more in hot weather. Keep the supply in a prepared-\n'
      'ness kit with a pot, a lid, bleach and a clean cloth for filtering.\n'
      'Store treated water in clean, closed containers away from sunlight.';

  test('a quote is found despite line breaks, hyphenation and capitals', () {
    const quote = 'every family should keep a three-day supply of water, four litres for each person each day, more in hot '
        'weather. keep the supply in a preparedness kit with a pot';
    final spans = findQuote(quote, pageNumber: 3, page: pdfWords(page));
    expect(spans, isNotNull);
    expect(spans!.length, 1);
    expect(page.substring(spans.first.start, spans.first.end), startsWith('Every family'));
    expect(page.substring(spans.first.start, spans.first.end), endsWith('a pot'));
  });

  test('a passage that runs on to the next page is matched there too, over the running head', () {
    const next = 'Water and Shelter Handbook, page 4\nmark each one with the date and replace it every six months.';
    const quote = 'Store treated water in clean, closed containers away from sunlight and mark each one with the date';
    final spans = findQuote(quote, pageNumber: 3, page: pdfWords(page), next: pdfWords(next));
    expect(spans, isNotNull);
    expect(spans!.map((s) => s.page), [3, 4]);
    expect(next.substring(spans[1].start, spans[1].end), 'mark each one with the date');
  });

  test('text that is not on the page, or only partly, is not found', () {
    expect(findQuote('Nothing like this is printed anywhere in the handbook at all', pageNumber: 3, page: pdfWords(page)), isNull);
    // Half of the first words: too little to count.
    expect(findQuote('every family should keep their goats inside a fenced barn overnight please', pageNumber: 3, page: pdfWords(page)), isNull);
    expect(findQuote('', pageNumber: 3, page: pdfWords(page)), isNull);
    expect(findQuote('water', pageNumber: 3, page: const []), isNull);
  });

  test('find looks for the words in order, across line breaks and punctuation', () {
    final p = findPattern('supply  of WATER four');
    expect(p.allMatches(page).length, 1);
    expect(findPattern('prepared ness').hasMatch(page), isTrue);
    expect(findPattern('%').hasMatch('100%'), isTrue);
    expect(quoteOpening('Every family, should keep a three day supply.', n: 4), 'Every family should keep');
  });
}
