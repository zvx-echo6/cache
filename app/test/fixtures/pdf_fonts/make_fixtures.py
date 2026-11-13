#!/usr/bin/env python3
"""Makes the PDFs of this folder: one page or two of plain text in each kind of font PDFium can be asked for, so a change to how
PDFium finds fonts (app/test/pdf/pdfium_font_mapper_test.dart) shows in the extracted text and the drawn page. Deterministic: the
same bytes every time. Fonts that are not embedded are the ones PDFium asks its font mapper about. Run from this folder."""
import os, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROBOTO = os.path.join(HERE, '..', '..', '..', 'assets', 'fonts', 'RobotoMono-Bold.ttf')

TEXT = [
    'The quick brown fox jumps over the lazy dog. Water purification in the field.',
    'Boil it for one minute; at altitude, three minutes. 1,234 liters (about 326 gallons) -- state-of-the-art.',
    "Don't store treated water for more than six months, e.g. COVID-19 U.S. FEMA-IS513.",
]


def pdf(objs, info=None):
    out = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    at = []
    for i, o in enumerate(objs):
        at.append(len(out))
        out += b'%d 0 obj\n' % (i + 1) + o + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for a in at:
        out += b'%010d 00000 n \n' % a
    out += b'trailer\n<< /Size %d /Root 1 0 R %s>>\nstartxref\n%d\n%%%%EOF\n' % (
        len(objs) + 1, (b'/Info %d 0 R ' % info) if info else b'', xref)
    return bytes(out)


def stream(d, body):
    return b'<< %s /Length %d >>\nstream\n' % (d, len(body)) + body + b'\nendstream'


def esc(b):
    return b.replace(b'\\', b'\\\\').replace(b'(', b'\\(').replace(b')', b'\\)')


def text_doc(font_objs, lines_pages, encode=lambda s: s.encode('latin-1'), size=11, title=b'Fixture'):
    """font_objs: objects 3.. (the fonts, named /F1..); lines_pages: pages, each a list of (fontindex, text)."""
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'', None]
    fonts = list(font_objs)
    nfont = len(fonts)
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'']
    objs += fonts  # objects 3 .. 3+nfont-1
    info_id = len(objs) + 1
    objs.append(b'<< /Title (' + esc(title) + b') /Producer (cache tests) /CreationDate (D:20260101000000Z) >>')
    kids = []
    fres = b' '.join(b'/F%d %d 0 R' % (i + 1, 3 + i) for i in range(nfont))
    for lines in lines_pages:
        pid = len(objs) + 1
        kids.append(b'%d 0 R' % pid)
        c = bytearray()
        for i, (fi, t) in enumerate(lines):
            c += b'BT /F%d %d Tf 40 %d Td (' % (fi + 1, size, 740 - i * 16) + esc(encode(t) if isinstance(t, str) else t) + b') Tj ET\n'
        objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << ' + fres + b' >> >> /Contents %d 0 R >>' % (pid + 1))
        objs.append(stream(b'', bytes(c)))
    objs[1] = b'<< /Type /Pages /Kids [' + b' '.join(kids) + b'] /Count %d >>' % len(kids)
    return pdf(objs, info=info_id)


def type1(name):
    return b'<< /Type /Font /Subtype /Type1 /BaseFont /' + name + b' >>'


def truetype_nonembedded(name, width, flags=32):
    d = b'<< /Type /FontDescriptor /FontName /%s /Flags %d /FontBBox [-200 -250 1200 950] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 >>' % (name, flags)
    widths = b' '.join(b'%d' % (width if c != 32 else width // 2) for c in range(32, 127))
    # the descriptor is object id+1: the caller places it right after this font
    return d, widths


def with_descriptor(font_objs_head, name, width, flags=32, enc=b'/WinAnsiEncoding'):
    """Two objects: the font, then its descriptor (the font points at the next object number, set by the caller)."""
    d, widths = truetype_nonembedded(name, width, flags)
    return d, widths


def build(path, data):
    open(os.path.join(HERE, path), 'wb').write(data)


def lines(font, texts=TEXT):
    return [(font, t) for t in texts]


def main():
    # 1 Times (base 14), 3 Courier (base 14), Helvetica
    build('times.pdf', text_doc([type1(b'Times-Roman')], [lines(0)], title=b'Times'))
    build('courier.pdf', text_doc([type1(b'Courier')], [lines(0)], title=b'Courier'))
    build('helvetica.pdf', text_doc([type1(b'Helvetica')], [lines(0), lines(0)], title=b'Helvetica'))
    # Symbol: Greek letters by their Symbol codes
    build('symbol.pdf', text_doc([type1(b'Symbol'), type1(b'Helvetica')], [[(0, b'abgdez hqiklmnxoprstufcyw ABGDEZ'), (1, 'alpha beta gamma delta')]], title=b'Symbol'))

    # a TrueType font that is NOT embedded: Arial, Calibri, Wingdings (symbolic): PDFium asks its font mapper for them
    def truetype(name, width, flags):
        # font object (3), descriptor object (next): returned in order so object numbers follow the caller's list
        return name, width, flags

    def doc_with_descriptors(specs, pages, **kw):
        # specs: [(basefont, width, flags)]; objects: 3.. = fonts, then the descriptors
        n = len(specs)
        fonts, descs = [], []
        for i, (name, w, flags) in enumerate(specs):
            widths = b' '.join(b'%d' % (w if c != 32 else w // 2) for c in range(32, 127))
            fonts.append(b'<< /Type /Font /Subtype /TrueType /BaseFont /%s /FirstChar 32 /LastChar 126 /Widths [%s] /Encoding /WinAnsiEncoding /FontDescriptor %d 0 R >>' % (name, widths, 3 + n + 1 + i))
            descs.append(b'<< /Type /FontDescriptor /FontName /%s /Flags %d /FontBBox [-200 -250 1200 950] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 >>' % (name, flags))
        return text_doc_with_extra(fonts, descs, pages, **kw)

    def text_doc_with_extra(fonts, extra, pages, title=b'Fixture', size=11):
        nfont = len(fonts)
        objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b''] + fonts
        info_id = len(objs) + 1
        objs.append(b'<< /Title (' + esc(title) + b') /Producer (cache tests) /CreationDate (D:20260101000000Z) >>')
        objs += extra
        kids = []
        fres = b' '.join(b'/F%d %d 0 R' % (i + 1, 3 + i) for i in range(nfont))
        for lns in pages:
            pid = len(objs) + 1
            kids.append(b'%d 0 R' % pid)
            c = bytearray()
            for i, (fi, t) in enumerate(lns):
                c += b'BT /F%d %d Tf 40 %d Td (' % (fi + 1, size, 740 - i * 16) + esc(t.encode('latin-1') if isinstance(t, str) else t) + b') Tj ET\n'
            objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << ' + fres + b' >> >> /Contents %d 0 R >>' % (pid + 1))
            objs.append(stream(b'', bytes(c)))
        objs[1] = b'<< /Type /Pages /Kids [' + b' '.join(kids) + b'] /Count %d >>' % len(kids)
        return pdf(objs, info=info_id)

    build('arial.pdf', doc_with_descriptors([(b'Arial', 556, 32)], [lines(0)], title=b'Arial'))
    build('calibri.pdf', doc_with_descriptors([(b'Calibri', 500, 32)], [lines(0)], title=b'Calibri'))
    build('wingdings.pdf', doc_with_descriptors([(b'Wingdings', 700, 4), (b'Arial', 556, 32)], [[(0, b'abcdefghijklmnop ABCDEFGHIJKLMNOP'), (1, 'a line in Arial')]], title=b'Wingdings'))
    build('mixed.pdf', doc_with_descriptors([(b'Arial', 556, 32), (b'Calibri', 500, 32), (b'TimesNewRoman', 480, 34)],
                                              [[(0, TEXT[0]), (1, TEXT[1]), (2, TEXT[2])], [(2, TEXT[0]), (0, TEXT[1]), (1, TEXT[2])]], title=b'Mixed'))

    # a CJK font that is not embedded: Adobe-Japan1, text in Shift-JIS
    jp = '日本語のテキスト。水の浄化は一分間沸騰させます。'.encode('shift_jis')
    cid = b'<< /Type /Font /Subtype /CIDFontType2 /BaseFont /MS-Mincho /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 6 0 R /DW 1000 >>'
    t0 = b'<< /Type /Font /Subtype /Type0 /BaseFont /MS-Mincho /Encoding /90ms-RKSJ-H /DescendantFonts [5 0 R] >>'
    # objects: 3 = Type0 font, 4 = Helvetica, then 5 = CIDFont, 6 = descriptor (extra objects follow the info)
    fonts = [t0, type1(b'Helvetica')]
    # the info object comes right after the fonts, so the extras start at 3 + 2 + 1 = 6: place them accordingly
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'', t0, type1(b'Helvetica')]
    objs.append(b'<< /Title (CJK) /Producer (cache tests) /CreationDate (D:20260101000000Z) >>')  # 5
    objs.append(b'<< /Type /Font /Subtype /CIDFontType2 /BaseFont /MS-Mincho /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 2 >> /FontDescriptor 7 0 R /DW 1000 >>')  # 6
    objs.append(b'<< /Type /FontDescriptor /FontName /MS-Mincho /Flags 6 /FontBBox [0 -137 1000 859] /ItalicAngle 0 /Ascent 859 /Descent -137 /CapHeight 700 /StemV 80 >>')  # 7
    objs[2] = b'<< /Type /Font /Subtype /Type0 /BaseFont /MS-Mincho /Encoding /90ms-RKSJ-H /DescendantFonts [6 0 R] >>'
    c = b'BT /F1 14 Tf 40 740 Td (' + esc(jp) + b') Tj ET\nBT /F2 11 Tf 40 700 Td (Japanese text with a Latin line.) Tj ET\n'
    objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents 9 0 R >>')  # 8
    objs.append(stream(b'', c))  # 9
    objs[1] = b'<< /Type /Pages /Kids [8 0 R] /Count 1 >>'
    build('cjk.pdf', pdf(objs, info=5))

    # an embedded TrueType font (Roboto Mono Bold from the app's assets)
    ttf = open(ROBOTO, 'rb').read()
    widths = b' '.join(b'600' for _ in range(32, 127))
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'']
    objs.append(b'<< /Type /Font /Subtype /TrueType /BaseFont /RobotoMono-Bold /FirstChar 32 /LastChar 126 /Widths [' + widths + b'] /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>')  # 3
    objs.append(b'<< /Title (Embedded) /Producer (cache tests) /CreationDate (D:20260101000000Z) >>')  # 4
    objs.append(b'<< /Type /FontDescriptor /FontName /RobotoMono-Bold /Flags 33 /FontBBox [-200 -250 1200 950] /ItalicAngle 0 /Ascent 1048 /Descent -271 /CapHeight 710 /StemV 100 /FontFile2 6 0 R >>')  # 5
    objs.append(stream(b'/Length1 %d' % len(ttf), ttf))  # 6
    c = bytearray()
    for i, t in enumerate(TEXT):
        c += b'BT /F1 11 Tf 40 %d Td (' % (740 - i * 16) + esc(t.encode('latin-1')) + b') Tj ET\n'
    objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents 8 0 R >>')  # 7
    objs.append(stream(b'', bytes(c)))  # 8
    objs[1] = b'<< /Type /Pages /Kids [7 0 R] /Count 1 >>'
    build('embedded.pdf', pdf(objs, info=4))

    # a scanned page: only a picture, no text layer
    w, h = 200, 100
    pix = bytes((40 if (i % w) < 100 else 220) for i in range(w * h))
    draw = b'q 500 0 0 250 56 400 cm /Im1 Do Q\n'
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>',
            stream(b'', draw),
            stream(b'/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 8' % (w, h), pix)]
    build('scanned.pdf', pdf(objs))


if __name__ == '__main__':
    main()
