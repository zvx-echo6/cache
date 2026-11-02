import 'dart:convert';
import 'dart:typed_data';

/// One page of a test PDF: lines of text (drawn in the standard Helvetica, so the page has a text layer), or none and a few
/// grey shapes (a "scanned" page: a picture with no text). [wide] makes a landscape page.
class SamplePage {
  const SamplePage({this.lines = const [], this.heading, this.shapes = false, this.wide = false});

  final String? heading;
  final List<String> lines;
  final bool shapes;
  final bool wide;
}

/// The text of the sample handbook's pages: the project's own words about water and shelter (no personal data, free to use).
const List<String> kSampleParagraph = [
  'Water that looks clear can still carry germs. Bring it to a rolling boil',
  'for one minute, or three minutes above two thousand metres, and let it',
  'cool in a covered pot. Boiled water tastes flat; pour it between two clean',
  'containers a few times to put air back into it before drinking.',
  'If you cannot boil water, filter it through a clean cloth, then add',
  'household bleach without scent: two drops to each litre, stir, and wait',
  'thirty minutes. A faint smell of chlorine means it is ready to drink.',
  'Store treated water in clean, closed containers away from sunlight and',
  'mark each one with the date. Replace stored water every six months.',
  'A tarp shelter needs a ridge line tied tight between two trees at chest',
  'height. Stake the corners low on the side the wind comes from, and leave',
  'a gap at the top so warm, damp air can escape during the night.',
];

/// A page of the sample handbook: its number at the top, then [kSampleParagraph] (with a word broken across two lines by a
/// hyphen on page 3, as printed books do).
SamplePage sampleTextPage(int n) => SamplePage(
      heading: 'Water and Shelter Handbook, page $n',
      lines: n == 3
          ? [
              ...kSampleParagraph.take(4),
              'Every family should keep a three day supply of water: four litres for',
              'each person each day, more in hot weather. Keep the supply in a prepared-',
              'ness kit with a pot, a lid, bleach and a clean cloth for filtering.',
              ...kSampleParagraph.skip(4),
            ]
          : kSampleParagraph,
    );

/// A PDF with [pages], written by hand (a few hundred bytes a page): the header, one object per catalogue, page tree, font, page
/// and content stream, the cross-reference table and the trailer.
Uint8List samplePdf(List<SamplePage> pages, {String title = 'Water and Shelter Handbook'}) {
  final out = BytesBuilder(copy: false);
  final offsets = <int>[];
  void add(String s) => out.add(latin1.encode(s));
  void obj(String body) {
    offsets.add(out.length);
    add('${offsets.length} 0 obj\n$body\nendobj\n');
  }

  String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

  add('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
  // 1 catalogue, 2 pages, 3 font, 4 info; then a page and its content for each page.
  final kids = [for (var i = 0; i < pages.length; i++) '${5 + i * 2} 0 R'].join(' ');
  obj('<< /Type /Catalog /Pages 2 0 R >>');
  obj('<< /Type /Pages /Kids [$kids] /Count ${pages.length} >>');
  obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
  obj('<< /Title (${esc(title)}) /Producer (Cache tests) >>');
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    final w = p.wide ? 792 : 612;
    final h = p.wide ? 612 : 792;
    final c = StringBuffer();
    if (p.shapes) {
      // A "photograph": grey blocks and a darker band, no text at all.
      c.write('0.82 g 54 ${h - 360} ${w - 108} 300 re f\n0.55 g 54 ${h - 200} ${w - 108} 40 re f\n0.7 g 90 ${h - 560} 200 160 re f\n');
    }
    if (p.heading != null || p.lines.isNotEmpty) {
      c.write('0 g BT /F1 16 Tf 54 ${h - 64} Td (${esc(p.heading ?? '')}) Tj ET\n');
      c.write('BT /F1 13 Tf 17 TL 54 ${h - 100} Td\n');
      for (final l in p.lines) {
        c.write('(${esc(l)}) Tj T*\n');
      }
      c.write('ET\n');
    }
    final content = latin1.encode(c.toString());
    obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] /Resources << /Font << /F1 3 0 R >> >> /Contents ${6 + i * 2} 0 R >>');
    offsets.add(out.length);
    add('${offsets.length} 0 obj\n<< /Length ${content.length} >>\nstream\n');
    out.add(content);
    add('\nendstream\nendobj\n');
  }
  final xref = out.length;
  add('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    add('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R /Info 4 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.takeBytes();
}

/// The sample handbook: [count] pages of text, with the pages in [scanned] as pictures with no text.
Uint8List sampleHandbook({int count = 340, Set<int> scanned = const {}}) => samplePdf([
      for (var n = 1; n <= count; n++) scanned.contains(n) ? const SamplePage(shapes: true) : sampleTextPage(n),
    ]);
