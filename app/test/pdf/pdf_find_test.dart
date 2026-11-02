import 'dart:async';

import 'package:cache/pdf/pdf_find.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pages = {1: 'Boil the water. Boiled water is safe.', 2: '', 3: 'Nothing here.', 4: 'boil again'};

  test('matches come in page by page; next and previous go round; empty pages are counted', () async {
    final f = PdfFind(pageCount: 4, pageText: (p) async => pages[p]!);
    final seen = <int>[];
    f.onCurrent = (m) => seen.add(m.page);
    await f.run('boil');
    expect(f.matches.length, 3);
    expect(f.countText, '1 of 3');
    expect(f.countLabel, 'Match 1 of 3');
    expect(f.scannedSkipped, 1);
    expect(f.skippedSome, isTrue);
    f.next();
    f.next();
    expect(f.countText, '3 of 3');
    f.next();
    expect(f.countText, '1 of 3');
    expect(f.wrapped, isTrue);
    f.previous();
    expect(f.countText, '3 of 3');
    expect(seen, [1, 1, 4, 1, 4]);
    expect(f.on(1).length, 2);
    f.dispose();
  });

  test('no matches; an empty query clears', () async {
    final f = PdfFind(pageCount: 4, pageText: (p) async => pages[p]!);
    await f.run('tarp');
    expect(f.countText, 'No matches');
    f.clear();
    expect(f.countText, '');
    f.dispose();
  });

  test('while pages are still being searched: "Searching..." then "N found so far"; a new search stops the old one', () async {
    final gate = Completer<void>();
    final f = PdfFind(pageCount: 4, pageText: (p) async {
      if (p == 4) await gate.future;
      return pages[p]!;
    });
    expect(f.countText, '');
    final run = f.run('boil');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(f.searching, isTrue);
    expect(f.countText, '2 found so far');
    gate.complete();
    await run;
    expect(f.countText, '1 of 3');
    f.dispose();
  });
}
