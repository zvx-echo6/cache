import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../net/fetch.dart' show kUserAgent;

/// Kiwix's public catalogue, read through its documented OPDS API (library.kiwix.org, "catalog/v2").
/// The catalogue is Atom XML: `entries` (filter with lang, category, tag, name, q, count, start),
/// `categories` and `languages`. Nothing else is read from the web site.
const String kiwixCatalogHost = 'https://opds.library.kiwix.org';
const String kiwixCatalogPath = '/catalog/v2';

/// What the app tells a server about itself. No person, device or place.

/// The variants Kiwix publishes, in words for people.
String flavourLabel(String flavour) => switch (flavour) {
  'mini' => 'Mini',
  'nopic' => 'No pictures',
  'maxi' => 'Full',
  '' => 'Full',
  _ => flavour,
};

/// One catalogue entry: a ZIM that can be downloaded.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.title,
    required this.summary,
    required this.language,
    required this.name,
    required this.flavour,
    required this.category,
    required this.tags,
    required this.updated,
    required this.size,
    required this.articleCount,
    required this.downloadUrl,
    required this.iconUrl,
    this.author = '',
  });

  /// The catalogue's UUID for this entry.
  final String id;
  final String title;
  final String summary;

  /// ISO 639-3, for example "eng".
  final String language;

  /// Kiwix's machine name, for example "wikivoyage_en_europe". The same for every release and variant.
  final String name;

  /// "maxi", "mini", "nopic" or "" (a single variant).
  final String flavour;
  final String category;
  final List<String> tags;

  /// The release date, "2026-09-14".
  final String updated;

  /// Bytes, as the catalogue lists them.
  final int size;
  final int articleCount;

  /// The direct .zim address (the catalogue links the .meta4 metalink; this is the same address without it).
  final Uri downloadUrl;
  final Uri? iconUrl;
  final String author;

  String get fileName => downloadUrl.pathSegments.last;

  /// "2026-09": the release month, which is what Kiwix puts in the file name.
  String get release =>
      releaseOfFileName(fileName) ??
      (updated.length >= 7 ? updated.substring(0, 7) : updated);

  /// Where the file's checksums are published (next to the file, on Kiwix's own download host).
  Uri get sha256Url => downloadUrl.replace(path: '${downloadUrl.path}.sha256');
  Uri get md5Url => downloadUrl.replace(path: '${downloadUrl.path}.md5');

  String get flavourText => flavourLabel(flavour);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'language': language,
    'name': name,
    'flavour': flavour,
    'category': category,
    'tags': tags,
    'updated': updated,
    'size': size,
    'articleCount': articleCount,
    'downloadUrl': downloadUrl.toString(),
    'iconUrl': iconUrl?.toString(),
    'author': author,
  };

  static CatalogEntry fromJson(Map<String, dynamic> j) => CatalogEntry(
    id: j['id'] as String,
    title: (j['title'] ?? '') as String,
    summary: (j['summary'] ?? '') as String,
    language: (j['language'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    flavour: (j['flavour'] ?? '') as String,
    category: (j['category'] ?? '') as String,
    tags: ((j['tags'] as List?) ?? const []).cast<String>(),
    updated: (j['updated'] ?? '') as String,
    size: (j['size'] ?? 0) as int,
    articleCount: (j['articleCount'] ?? 0) as int,
    downloadUrl: Uri.parse(j['downloadUrl'] as String),
    iconUrl: j['iconUrl'] == null ? null : Uri.parse(j['iconUrl'] as String),
    author: (j['author'] ?? '') as String,
  );
}

/// "wikivoyage_en_europe_nopic_2026-09.zim" -> "2026-09", or null.
String? releaseOfFileName(String fileName) {
  final m = RegExp(
    r'_(\d{4}-\d{2})(?:\.zim)?(?:\.[a-z0-9]+)?$',
    caseSensitive: false,
  ).firstMatch(fileName);
  return m?.group(1);
}

/// What a ZIM file is, in the catalogue's terms: enough to tell whether a newer release exists.
class ZimOrigin {
  const ZimOrigin({
    required this.name,
    required this.flavour,
    required this.release,
    this.language = '',
    this.title = '',
    this.catalogId = '',
    this.summary = '',
  });

  final String name;
  final String flavour;

  /// "2026-09".
  final String release;
  final String language;
  final String title;
  final String catalogId;

  /// The catalogue's one-line description ("Medical encyclopedia"), kept for the Library list.
  final String summary;

  /// Reads Kiwix's file naming: {name}_{flavour}_{YYYY-MM}.zim, the flavour being maxi, mini, nopic or absent.
  /// Null for a file that does not follow it.
  static ZimOrigin? fromFileName(String fileName) {
    final base = fileName.replaceFirst(
      RegExp(r'\.zim$', caseSensitive: false),
      '',
    );
    final m = RegExp(r'^(.+)_(\d{4}-\d{2})$').firstMatch(base);
    if (m == null) return null;
    var name = m.group(1)!;
    var flavour = '';
    final f = RegExp(r'^(.+)_(maxi|mini|nopic)$').firstMatch(name);
    if (f != null) {
      name = f.group(1)!;
      flavour = f.group(2)!;
    }
    return ZimOrigin(name: name, flavour: flavour, release: m.group(2)!);
  }

  factory ZimOrigin.fromEntry(CatalogEntry e) => ZimOrigin(
    name: e.name,
    flavour: e.flavour,
    release: e.release,
    language: e.language,
    title: e.title,
    catalogId: e.id,
    summary: e.summary,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'flavour': flavour,
    'release': release,
    'language': language,
    'title': title,
    'catalogId': catalogId,
    if (summary.isNotEmpty) 'summary': summary,
  };

  static ZimOrigin fromJson(Map<String, dynamic> j) => ZimOrigin(
    name: j['name'] as String,
    flavour: (j['flavour'] ?? '') as String,
    release: (j['release'] ?? '') as String,
    language: (j['language'] ?? '') as String,
    title: (j['title'] ?? '') as String,
    catalogId: (j['catalogId'] ?? '') as String,
    summary: (j['summary'] ?? '') as String,
  );

  /// True when [e] is a later release of this same ZIM and variant.
  bool isOlderThan(CatalogEntry e) =>
      e.name == name &&
      e.flavour == flavour &&
      e.release.compareTo(release) > 0;
}

/// One page of entries.
class CatalogPage {
  const CatalogPage({
    required this.entries,
    required this.total,
    required this.start,
  });

  final List<CatalogEntry> entries;
  final int total;
  final int start;

  int get next => start + entries.length;
  bool get hasMore => entries.isNotEmpty && next < total;
}

class CatalogLanguage {
  const CatalogLanguage({
    required this.code,
    required this.name,
    required this.count,
  });

  final String code;
  final String name;
  final int count;
}

class CatalogCategory {
  const CatalogCategory({required this.id});

  /// The value of the catalogue's `category` filter, for example "stack_exchange".
  final String id;

  String get label => categoryLabel(id);
}

const Map<String, String> _categoryLabels = {
  'wikipedia': 'Wikipedia',
  'wikivoyage': 'Wikivoyage',
  'wikibooks': 'Wikibooks',
  'wikiquote': 'Wikiquote',
  'wikisource': 'Wikisource',
  'wikiversity': 'Wikiversity',
  'wiktionary': 'Wiktionary',
  'stack_exchange': 'Stack Exchange',
  'gutenberg': 'Gutenberg',
  'iFixit': 'iFixit',
  'ted': 'TED',
  'phet': 'PhET',
  'mooc': 'Courses',
  'vikidia': 'Vikidia',
  'psiram': 'Psiram',
  'other': 'Other',
};

String categoryLabel(String id) {
  final l = _categoryLabels[id];
  if (l != null) return l;
  if (id.isEmpty) return id;
  return id[0].toUpperCase() + id.substring(1).replaceAll('_', ' ');
}

/// The catalogue is unreachable or answered with something that is not a catalogue.
class CatalogException implements Exception {
  const CatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches one address and returns the body. A function so tests can give recorded responses.
typedef CatalogFetch = Future<String> Function(Uri url);

/// Kiwix's feed keeps its own client: it follows redirects itself and says each failure in the words the guide quotes.
Future<String> httpFetchText(Uri url) async {
  final client = HttpClient()
    ..userAgent = kUserAgent
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    var u = url;
    for (var hop = 0; hop < 6; hop++) {
      final req = await client.getUrl(u);
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.isRedirect) {
        await res.drain<void>();
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null) {
          throw const CatalogException(
            'The library sent a redirect with no address.',
          );
        }
        u = u.resolve(loc);
        continue;
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw CatalogException('The library answered ${res.statusCode}.');
      }
      return await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 60));
    }
    throw const CatalogException('The library redirected too many times.');
  } on SocketException {
    throw const CatalogException(
      'Cannot reach the Kiwix library. Check the connection.',
    );
  } on HandshakeException {
    throw const CatalogException(
      'Cannot make a secure connection to the Kiwix library.',
    );
  } on HttpException catch (e) {
    throw CatalogException('The library could not be read: ${e.message}');
  } on TimeoutException {
    throw const CatalogException('The Kiwix library took too long to answer.');
  } finally {
    client.close(force: true);
  }
}

/// The catalogue client: builds the OPDS addresses and reads the Atom answers.
class KiwixCatalog {
  KiwixCatalog({CatalogFetch? fetch, this.base = kiwixCatalogHost})
    : _fetch = fetch ?? httpFetchText;

  final CatalogFetch _fetch;
  final String base;

  /// `/catalog/v2/entries` with the filters of Kiwix's search description (q, lang, category, tag, name, count, start).
  Uri entriesUrl({
    String? query,
    String? language,
    String? category,
    String? tag,
    String? name,
    int count = 30,
    int start = 0,
  }) {
    final params = <String, String>{
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      if (language != null && language.isNotEmpty) 'lang': language,
      if (category != null && category.isNotEmpty) 'category': category,
      if (tag != null && tag.isNotEmpty) 'tag': tag,
      if (name != null && name.isNotEmpty) 'name': name,
      'count': '$count',
      if (start > 0) 'start': '$start',
    };
    return Uri.parse(
      '$base$kiwixCatalogPath/entries',
    ).replace(queryParameters: params);
  }

  Uri get categoriesUrl => Uri.parse('$base$kiwixCatalogPath/categories');
  Uri get languagesUrl => Uri.parse('$base$kiwixCatalogPath/languages');

  Future<CatalogPage> entries({
    String? query,
    String? language,
    String? category,
    String? tag,
    String? name,
    int count = 30,
    int start = 0,
  }) async {
    final body = await _fetch(
      entriesUrl(
        query: query,
        language: language,
        category: category,
        tag: tag,
        name: name,
        count: count,
        start: start,
      ),
    );
    return parseEntries(body, base: Uri.parse(base));
  }

  Future<List<CatalogCategory>> categories() async =>
      parseCategories(await _fetch(categoriesUrl));

  Future<List<CatalogLanguage>> languages() async =>
      parseLanguages(await _fetch(languagesUrl));
}

XmlDocument _parse(String body) {
  try {
    return XmlDocument.parse(body);
  } on XmlException {
    throw const CatalogException(
      'The library answered with something that is not a catalogue.',
    );
  }
}

String _text(XmlElement parent, String local) {
  for (final c in parent.childElements) {
    if (c.name.local == local) return c.innerText.trim();
  }
  return '';
}

/// Reads an OPDS entries feed. Entries without a download link are skipped.
CatalogPage parseEntries(String body, {Uri? base}) {
  final doc = _parse(body);
  final feed = doc.rootElement;
  if (feed.name.local != 'feed') {
    throw const CatalogException(
      'The library answered with something that is not a catalogue.',
    );
  }
  final root = base ?? Uri.parse(kiwixCatalogHost);
  final out = <CatalogEntry>[];
  for (final e in feed.childElements.where((c) => c.name.local == 'entry')) {
    Uri? zim;
    int length = 0;
    Uri? icon;
    for (final l in e.childElements.where((c) => c.name.local == 'link')) {
      final rel = l.getAttribute('rel') ?? '';
      final href = l.getAttribute('href');
      if (href == null) continue;
      if (rel.contains('acquisition')) {
        var u = root.resolve(href);
        if (u.path.endsWith('.meta4')) {
          u = u.replace(
            path: u.path.substring(0, u.path.length - '.meta4'.length),
          );
        }
        zim = u;
        length = int.tryParse(l.getAttribute('length') ?? '') ?? 0;
      } else if (rel.endsWith('/image/thumbnail') || rel.endsWith('/image')) {
        icon = root.resolve(href);
        // Ask for a sharper icon than the 48 px the catalogue links.
        if (icon.queryParameters['size'] == '48') {
          icon = icon.replace(
            queryParameters: {...icon.queryParameters, 'size': '96'},
          );
        }
      }
    }
    if (zim == null) continue;
    final id = _text(e, 'id').replaceFirst('urn:uuid:', '');
    final issued = _text(e, 'issued');
    final updated = _text(e, 'updated');
    String author = '';
    for (final a in e.childElements.where((c) => c.name.local == 'author')) {
      author = _text(a, 'name');
    }
    out.add(
      CatalogEntry(
        id: id,
        title: _text(e, 'title'),
        summary: _text(e, 'summary'),
        language: _text(e, 'language'),
        name: _text(e, 'name'),
        flavour: _text(e, 'flavour'),
        category: _text(e, 'category'),
        tags: _text(
          e,
          'tags',
        ).split(';').where((t) => t.isNotEmpty && !t.startsWith('_')).toList(),
        updated: (issued.isNotEmpty ? issued : updated).split('T').first,
        size: length,
        articleCount: int.tryParse(_text(e, 'articleCount')) ?? 0,
        downloadUrl: zim,
        iconUrl: icon,
        author: author,
      ),
    );
  }
  return CatalogPage(
    entries: out,
    total: int.tryParse(_text(feed, 'totalResults')) ?? out.length,
    start: int.tryParse(_text(feed, 'startIndex')) ?? 0,
  );
}

List<CatalogCategory> parseCategories(String body) {
  final feed = _parse(body).rootElement;
  final out = <CatalogCategory>[];
  for (final e in feed.childElements.where((c) => c.name.local == 'entry')) {
    final id = _text(e, 'title');
    if (id.isNotEmpty) out.add(CatalogCategory(id: id));
  }
  out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return out;
}

List<CatalogLanguage> parseLanguages(String body) {
  final feed = _parse(body).rootElement;
  final out = <CatalogLanguage>[];
  for (final e in feed.childElements.where((c) => c.name.local == 'entry')) {
    final code = _text(e, 'language');
    if (code.isEmpty) continue;
    out.add(
      CatalogLanguage(
        code: code,
        name: _text(e, 'title'),
        count: int.tryParse(_text(e, 'count')) ?? 0,
      ),
    );
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// The catalogue's language code (ISO 639-3) for a phone language (ISO 639-1, for example "fr"); "eng" when unknown.
String catalogLanguageFor(String phoneLanguage) =>
    _iso1to3[phoneLanguage.toLowerCase()] ?? 'eng';

const Map<String, String> _iso1to3 = {
  'af': 'afr',
  'ar': 'ara',
  'bg': 'bul',
  'bn': 'ben',
  'ca': 'cat',
  'cs': 'ces',
  'da': 'dan',
  'de': 'deu',
  'el': 'ell',
  'en': 'eng',
  'es': 'spa',
  'et': 'est',
  'fa': 'fas',
  'fi': 'fin',
  'fr': 'fra',
  'he': 'heb',
  'hi': 'hin',
  'hr': 'hrv',
  'hu': 'hun',
  'id': 'ind',
  'it': 'ita',
  'ja': 'jpn',
  'ko': 'kor',
  'lt': 'lit',
  'lv': 'lav',
  'ms': 'msa',
  'nl': 'nld',
  'no': 'nor',
  'nb': 'nob',
  'pl': 'pol',
  'pt': 'por',
  'ro': 'ron',
  'ru': 'rus',
  'sk': 'slk',
  'sl': 'slv',
  'sr': 'srp',
  'sv': 'swe',
  'sw': 'swa',
  'ta': 'tam',
  'th': 'tha',
  'tl': 'fil',
  'tr': 'tur',
  'uk': 'ukr',
  'ur': 'urd',
  'vi': 'vie',
  'zh': 'zho',
};
