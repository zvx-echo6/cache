import 'dart:convert';

/// The road sources data file (assets/roads/road_sources.json): the 511 sites, the WZDx feeds the registry lists, the steps of a key
/// sheet and each site's rate limit. One file feeds the pickers, the key sheets, the key rows in Map settings and the guide tables.
///
/// It carries `schema` (the layout, an integer this app understands), `version` (only goes up) and `updated`. The copy that ships in the
/// app always works; a newer copy placed beside the connector catalogue can override it later: [RoadSourcesFile.choose] takes the one
/// with the higher version (the shipped one when equal) and only when the other passes [RoadSourcesFile.checkDownloaded]. Copies are
/// never merged. Feed web addresses are deliberately not in the file (see road_registry.dart).

/// The layout of the file this version of Cache reads.
const int kRoadSourcesSchema = 1;

/// Where the shipped copy is in the app's assets.
const String kRoadSourcesAsset = 'assets/roads/road_sources.json';

/// How a key goes onto a request: a query parameter, a header (with an optional prefix put before the key) or HTTP Basic.
class FeedAuth {
  const FeedAuth({required this.where, required this.name, this.prefix = '', this.inferred = false, this.alt});

  /// `query`, `header` or `basic`.
  final String where;

  /// The parameter or header name.
  final String name;
  final String prefix;
  final bool inferred;

  /// The documented alternative.
  final FeedAuth? alt;

  static FeedAuth? fromJson(Object? j) {
    if (j is! Map) return null;
    final w = j['in'], n = j['name'];
    if (w is! String || n is! String || !const {'query', 'header', 'basic'}.contains(w)) return null;
    return FeedAuth(where: w, name: n, prefix: j['prefix'] is String ? j['prefix'] as String : '', inferred: j['inferred'] == true, alt: fromJson(j['alt']));
  }
}

/// A rate limit: [calls] in [window].
class RateLimit {
  const RateLimit(this.calls, this.window);

  final int calls;
  final Duration window;

  /// Reads "10 calls per 60 seconds" and "60 requests per hour" (a machine format, written by the data file).
  static RateLimit? parse(String? text) {
    if (text == null) return null;
    final m = RegExp(r'^\s*(\d+)\s+(?:calls?|requests?)\s+(?:per|every)\s+(?:(\d+)\s+)?(second|seconds|minute|minutes|hour|hours)\s*$', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    final k = m.group(2) == null ? 1 : int.parse(m.group(2)!);
    final unit = m.group(3)!.toLowerCase();
    final secs = unit.startsWith('second') ? 1 : unit.startsWith('minute') ? 60 : 3600;
    if (n <= 0 || k <= 0) return null;
    return RateLimit(n, Duration(seconds: secs * k));
  }

  @override
  String toString() => '$calls per ${window.inSeconds} s';
}

/// A 511 platform site: one source, one key, everything the site documents that Cache uses (events, and winter road conditions where
/// the site offers them).
class RoadSite {
  const RoadSite({
    required this.id,
    required this.name,
    required this.country,
    required this.host,
    required this.keyPage,
    required this.rateLimit,
    required this.lacks,
    this.ownWzdx,
    this.conditions,
    this.conditionsNote,
  });

  factory RoadSite.fromJson(Map<String, dynamic> j) => RoadSite(
    id: '${j['id']}',
    name: '${j['name']}',
    country: '${j['country']}',
    host: '${j['host']}',
    keyPage: '${j['keyPage']}',
    rateLimit: RateLimit.parse(j['rateLimit'] as String?) ?? const RateLimit(10, Duration(seconds: 60)),
    lacks: [for (final l in (j['lacks'] as List? ?? const [])) '$l'],
    ownWzdx: j['ownWzdx'] as String?,
    conditions: j['conditions'] as String?,
    conditionsNote: j['conditionsNote'] as String?,
  );

  final String id;
  final String name;

  /// `US` or `CA`.
  final String country;
  final String host;
  final String keyPage;
  final RateLimit rateLimit;

  /// Documented fields this site does not list (a missing field is never shown).
  final List<String> lacks;
  final String? ownWzdx;

  /// The conditions resource this site documents (`winterroads` or `roadconditions`), or null for none.
  final String? conditions;
  final String? conditionsNote;

  /// The name of the key row: "511 key (511.idaho.gov)".
  String get keyTitle => '511 key ($host)';

  /// What the key is kept as in secure storage (`live.key.<alias>`).
  String get keyAlias => 'road511.$host';

  /// The source's id: the connector id pattern has no dots.
  String get sourceId => 'road511-${_slug(host)}';
  String get conditionsId => '$sourceId-conditions';

  /// What the site's one card says it covers.
  String get covers => conditions == null ? 'Closures, crashes and road work' : 'Closures, crashes, road work and winter road conditions';
}

/// One WZDx feed of the registry. A feed with `access` `open`, `key` or `request` is listed as supported; `request` ones are listed but
/// not usable (the publisher gives access on request), `unverified` and `unsupported` ones are greyed with a reason.
class RoadFeed {
  const RoadFeed({
    required this.id,
    required this.area,
    required this.publisher,
    required this.version,
    required this.keyNeeded,
    required this.keyPage,
    required this.update,
    required this.supported,
    required this.unsupportedReason,
    required this.access,
    this.auth,
    this.rateLimit,
    this.accessNote,
  });

  factory RoadFeed.fromJson(Map<String, dynamic> j) => RoadFeed(
    id: '${j['id']}',
    area: '${j['area']}',
    publisher: '${j['publisher']}',
    version: '${j['version']}',
    keyNeeded: j['keyNeeded'] == true,
    keyPage: j['keyPage'] as String?,
    update: '${j['update'] ?? ''}',
    supported: j['supported'] == true,
    unsupportedReason: j['unsupportedReason'] as String?,
    access: '${j['access']}',
    auth: FeedAuth.fromJson(j['auth']),
    rateLimit: RateLimit.parse(j['rateLimit'] as String?),
    accessNote: j['accessNote'] as String?,
  );

  final String id;
  final String area;
  final String publisher;
  final String version;
  final bool keyNeeded;
  final String? keyPage;
  final String update;
  final bool supported;
  final String? unsupportedReason;

  /// `open`, `key`, `request`, `unverified` or `unsupported`.
  final String access;
  final FeedAuth? auth;
  final RateLimit? rateLimit;
  final String? accessNote;

  /// WZDx versions Cache reads.
  static const Set<String> versions = {'4', '4.0', '4.1', '4.2'};

  /// Can be added and used: a supported version, and open or with a key a person can get on their own. By-request and unverified feeds
  /// are listed but not usable.
  bool get usable => supported && (access == 'open' || access == 'key') && versions.contains(version);

  bool get byRequest => access == 'request';

  /// The name of the key row: "WZDx key (Ohio DOT)".
  String get keyTitle => 'WZDx key ($publisher)';
  String get keyAlias => 'wzdx.$id';
  String get sourceId => 'wzdx-${_slug(id)}';
}

String _slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// The parsed data file.
class RoadSourcesFile {
  const RoadSourcesFile({required this.schema, required this.version, required this.updated, required this.keySteps, required this.sites, required this.feeds, required this.raw});

  /// Throws [FormatException] when the text is not a readable file of a schema this app understands.
  factory RoadSourcesFile.parse(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const FormatException('The road sources file is not readable.');
    }
    if (j is! Map<String, dynamic>) throw const FormatException('The road sources file is not readable.');
    final schema = j['schema'];
    if (schema is! int || schema != kRoadSourcesSchema) throw const FormatException('The road sources file has a layout this version does not read.');
    final version = j['version'];
    if (version is! int) throw const FormatException('The road sources file has no version.');
    final platform = j['platform'];
    final steps = platform is Map ? platform['keySteps'] : null;
    final wz = j['wzdx'];
    return RoadSourcesFile(
      schema: schema,
      version: version,
      updated: '${j['updated'] ?? ''}',
      keySteps: [for (final s in (steps is List ? steps : const [])) '$s'],
      sites: [for (final s in (j['sites'] as List? ?? const [])) RoadSite.fromJson((s as Map).cast<String, dynamic>())],
      feeds: [for (final f in ((wz is Map ? wz['feeds'] : null) as List? ?? const [])) RoadFeed.fromJson((f as Map).cast<String, dynamic>())],
      raw: j,
    );
  }

  /// No sites and no feeds: what is used until the shipped copy has been read.
  static const RoadSourcesFile empty = RoadSourcesFile(schema: kRoadSourcesSchema, version: 0, updated: '', keySteps: [], sites: [], feeds: [], raw: {});

  final int schema;
  final int version;
  final String updated;

  /// The steps of every 511 key sheet.
  final List<String> keySteps;
  final List<RoadSite> sites;
  final List<RoadFeed> feeds;
  final Map<String, dynamic> raw;

  RoadSite? siteByHost(String host) {
    final h = host.toLowerCase();
    for (final s in sites) {
      if (s.host == h || s.id == h) return s;
    }
    return null;
  }

  RoadFeed? feedById(String id) {
    for (final f in feeds) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Sites by country, in the file's order: United States then Canada.
  List<RoadSite> sitesIn(String country) => [for (final s in sites) if (s.country == country) s];

  /// The reasons a copy that was downloaded cannot be used (empty: it can). It must have a known schema (checked by [parse]), every
  /// site a key page and steps exist, every feed whose access is `key` an `auth` entry, and no feed address and no credential-looking
  /// query parameter anywhere in it.
  List<String> checkDownloaded() {
    final bad = <String>[];
    if (keySteps.isEmpty) bad.add('no key steps');
    for (final s in sites) {
      if (s.keyPage.isEmpty || s.keyPage == 'null') bad.add('site ${s.host} has no key page');
    }
    for (final f in feeds) {
      if (f.access == 'key' && f.auth == null) bad.add('feed ${f.id} needs a key but has no auth');
    }
    final text = jsonEncode(raw);
    if (RegExp(r'[?&](?:[A-Za-z0-9_-]*(?:key|token|secret|password|auth)[A-Za-z0-9_-]*)=(?!\{)', caseSensitive: false).hasMatch(text)) {
      bad.add('a credential-looking query parameter');
    }
    for (final m in RegExp(r'"url"\s*:').allMatches(text)) {
      bad.add('a feed address at ${m.start}');
      break;
    }
    return bad;
  }

  /// The copy to use: [downloaded] when it has a higher version than [shipped] and passes [checkDownloaded], else [shipped]. Equal
  /// versions: the shipped copy. [onIgnored] gets one line, never a value from the copy, when a downloaded copy is not used because
  /// it failed the check.
  static RoadSourcesFile choose(RoadSourcesFile shipped, RoadSourcesFile? downloaded, {void Function(String line)? onIgnored}) {
    if (downloaded == null || downloaded.version <= shipped.version) return shipped;
    final bad = downloaded.checkDownloaded();
    if (bad.isNotEmpty) {
      onIgnored?.call('Road sources: a downloaded copy was ignored (${bad.length} problem${bad.length == 1 ? '' : 's'})');
      return shipped;
    }
    return downloaded;
  }
}
