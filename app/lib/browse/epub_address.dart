import 'dart:convert';

import 'package:cache_search/cache_search.dart' show ZimBytes;
import 'package:xml/xml.dart';

/// EPUB entries of a ZIM, read in the reader like the rest of the ZIM. The core serves the files inside an EPUB at
/// `zim:<uuid>/<epub path>!/<inner path>` (XHTML, CSS, images) through the same entry read, and marks each block element of a
/// chapter with `id="cache-b<n>"`, so a citation `zim:<uuid>/<epub path>!/<chapter>#cache-b<n>` is an ordinary page with an
/// anchor (captions-epub-interface v1).
const String kEpubInner = '!/';

String _path(String address) {
  var p = address;
  final h = p.indexOf('#');
  if (h >= 0) p = p.substring(0, h);
  final q = p.indexOf('?');
  if (q >= 0) p = p.substring(0, q);
  return p;
}

/// True for an EPUB entry itself (`...book.epub`), which the reader opens at its first chapter instead of downloading it.
bool isEpubEntryAddress(String address) {
  final p = _path(address);
  return !p.contains(kEpubInner) && p.toLowerCase().endsWith('.epub');
}

/// True for a file inside an EPUB (`...book.epub!/OEBPS/ch1.xhtml`).
bool isEpubInnerAddress(String address) => _path(address).toLowerCase().contains('.epub$kEpubInner');

/// The block a citation points at (`#cache-b12` gives 12), or null.
int? epubBlockOfAddress(String address) {
  final h = address.indexOf('#');
  if (h < 0) return null;
  final m = RegExp(r'^cache-b(\d{1,7})$').firstMatch(address.substring(h + 1));
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// [rel] (an href in an EPUB file, which may climb with `..`) resolved against the folder of [base] (a path inside the EPUB).
String resolveEpubPath(String base, String rel) {
  final r = rel.split('#').first;
  final parts = <String>[...base.split('/')..removeLast()];
  if (r.startsWith('/')) parts.clear();
  for (final s in r.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(s);
    }
  }
  return parts.join('/');
}

/// The address of an EPUB entry's first chapter: META-INF/container.xml names the package (OPF), whose spine's first item
/// in reading order (linear) is the first chapter. Null when the EPUB does not say (the caller then leaves it to the reader).
Future<String?> epubFirstChapter(String epubAddress, Future<ZimBytes> Function(String address) get) async {
  final epub = _path(epubAddress);
  try {
    final container = XmlDocument.parse(utf8.decode((await get('$epub${kEpubInner}META-INF/container.xml')).bytes, allowMalformed: true));
    final opfPath = container.descendants.whereType<XmlElement>().where((e) => e.localName == 'rootfile').map((e) => e.getAttribute('full-path')).nonNulls.firstOrNull;
    if (opfPath == null || opfPath.isEmpty) return null;
    final opf = XmlDocument.parse(utf8.decode((await get('$epub$kEpubInner$opfPath')).bytes, allowMalformed: true));
    final items = <String, String>{
      for (final e in opf.descendants.whereType<XmlElement>().where((e) => e.localName == 'item'))
        if (e.getAttribute('id') != null && e.getAttribute('href') != null) e.getAttribute('id')!: e.getAttribute('href')!,
    };
    final spine = opf.descendants.whereType<XmlElement>().where((e) => e.localName == 'itemref').toList();
    final first = spine.where((e) => e.getAttribute('linear') != 'no').firstOrNull ?? spine.firstOrNull;
    final href = first == null ? null : items[first.getAttribute('idref')];
    if (href == null) return null;
    return '$epub$kEpubInner${resolveEpubPath(opfPath, href)}';
  } catch (_) {
    return null;
  }
}

/// The first words of a citation's quote, which the reader finds and marks on the page it opened (a whole passage seldom
/// matches the page's text exactly across its elements).
String quoteProbe(String quote, {int words = 8}) => quote.trim().split(RegExp(r'\s+')).take(words).join(' ');
