import '../platform/app_log.dart';
import '../settings/app_settings.dart';
import '../video/token_store.dart';
import '../weather/catalogue.dart';
import '../weather/connector.dart';
import 'credential_strip.dart';
import 'rate_limiter.dart';
import 'road_511_def.dart';
import 'road_sources.dart';
import 'wzdx_def.dart';

/// The road sources the person has: "511 road events" (one per 511 site, one key per site, everything that site documents and Cache
/// uses) and "WZDx road work" (one per registry feed or pasted address). Each is made into core definitions here and handed to the
/// weather part as ordinary connectors, so the weather list, the assistant and the map all read the same stored data as before.

/// The catalogue entries these replace. Their ids are kept by the connectors made here (Idaho), so the assistant's tool definition does
/// not change; the catalogue's own copies are left out of the list of sources.
const Set<String> kRetiredRoadIds = {'idaho511-events', 'idaho511-winter-roads', 'wzdx-idaho'};

/// The key name Idaho's 511 key had before one key per site (`live.key.idaho511`).
const String kOldIdahoAlias = 'idaho511';

/// A road source the person has.
class RoadSourceRecord {
  const RoadSourceRecord.site(String host) : kind = 'k511', id = host, url = null, name = null;
  const RoadSourceRecord.feed(this.id, {this.url, this.name}) : kind = 'wzdx';

  /// `k511` or `wzdx`.
  final String kind;

  /// The site's host, or the feed's id (`custom-...` for a pasted address).
  final String id;

  /// A WZDx feed's address without credentials.
  final String? url;

  /// A pasted feed's name.
  final String? name;

  bool get isSite => kind == 'k511';

  Map<String, dynamic> toJson() => {'k': isSite ? '511' : 'wzdx', 'id': id, 'url': ?url, 'name': ?name};

  static RoadSourceRecord? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    if (j['k'] == '511') return RoadSourceRecord.site(id);
    if (j['k'] == 'wzdx') return RoadSourceRecord.feed(id, url: j['url'] is String ? j['url'] as String : null, name: j['name'] is String ? j['name'] as String : null);
    return null;
  }
}

/// One road source as a person sees it: one row, with the connectors behind it (events, and conditions where the site has them).
class RoadSource {
  const RoadSource({required this.record, required this.title, required this.covers, required this.connectors, required this.keyAlias, required this.keyTitle, this.site, this.feed});

  final RoadSourceRecord record;

  /// "511 road events: 511.idaho.gov" or "WZDx road work: Idaho DOT".
  final String title;

  /// What it covers, for its card and the guide.
  final String covers;
  final List<Connector> connectors;

  /// The key name, or null for a feed that needs none.
  final String? keyAlias;
  final String? keyTitle;
  final RoadSite? site;
  final RoadFeed? feed;

  Iterable<String> get ids => [for (final c in connectors) c.id];
}

/// Holds the road sources: the data file, the person's list (in the settings), the limiter. Pure, so it is tested without the app.
class RoadSources {
  RoadSources({required this.settings, RoadSourcesFile? file, this.loadShipped, this.loadDownloaded, HostRateLimiter? limiter})
    : _file = file ?? RoadSourcesFile.empty,
      limiter = limiter ?? HostRateLimiter() {
    _applyLimits();
  }

  /// Reads the shipped copy of the data file (the app's asset).
  final Future<String> Function()? loadShipped;

  /// Reads a newer copy kept beside the connector catalogue, or null when there is none. Not built yet: nothing publishes one.
  final Future<String?> Function()? loadDownloaded;

  /// Reads the data file: the shipped copy, or a newer downloaded one that passes its check ([RoadSourcesFile.choose]). A copy that
  /// cannot be read is ignored with one line in the log. Call once before the sources are used.
  Future<void> load() async {
    RoadSourcesFile? shipped, down;
    try {
      final t = await loadShipped?.call();
      if (t != null) shipped = RoadSourcesFile.parse(t);
    } catch (e) {
      logError('Road sources file', error: e);
    }
    try {
      final t = await loadDownloaded?.call();
      if (t != null) down = RoadSourcesFile.parse(t);
    } catch (_) {
      logInfo('Road sources: a downloaded copy was ignored (not readable)');
    }
    if (shipped == null) return;
    useFile(RoadSourcesFile.choose(shipped, down, onIgnored: logInfo));
  }

  final AppSettings settings;
  final HostRateLimiter limiter;
  RoadSourcesFile _file;

  RoadSourcesFile get file => _file;

  /// Swaps in a newer data file ([RoadSourcesFile.choose] decides which); sources already added keep working.
  void useFile(RoadSourcesFile f) {
    _file = f;
    _applyLimits();
  }

  void _applyLimits() {
    for (final s in _file.sites) {
      limiter.setLimit(s.host, s.rateLimit);
    }
  }

  List<RoadSourceRecord> get records => [for (final m in settings.roadSources) ?RoadSourceRecord.fromJson(m)];

  /// Adds a source (one is added once). Adding turns nothing on.
  void add(RoadSourceRecord r) {
    final have = records;
    if (have.any((h) => h.kind == r.kind && h.id == r.id)) return;
    settings.setRoadSources([for (final h in [...have, r]) h.toJson()]);
  }

  void remove(RoadSourceRecord r) {
    settings.setRoadSources([for (final h in records) if (!(h.kind == r.kind && h.id == r.id)) h.toJson()]);
  }

  /// The sources, in the order they were added. A record the data file no longer lists still works if it carries what it needs (a
  /// feed's address); a site it no longer lists is left out.
  List<RoadSource> get sources => [for (final r in records) ?_make(r)];

  RoadSource? sourceFor(String connectorId) {
    for (final s in sources) {
      if (s.ids.contains(connectorId)) return s;
    }
    return null;
  }

  /// Every connector of every source.
  List<Connector> get connectors => [for (final s in sources) ...s.connectors];

  /// The rate host of a connector id, or null.
  String? rateHostOf(String connectorId) {
    for (final c in connectors) {
      if (c.id == connectorId) return c.rateHost;
    }
    return null;
  }

  RoadSource? _make(RoadSourceRecord r) {
    try {
      return r.isSite ? _site(r) : _feed(r);
    } catch (e) {
      logError('Road source ${r.id}', error: e);
      return null;
    }
  }

  RoadSource? _site(RoadSourceRecord r) {
    final site = _file.siteByHost(r.id);
    if (site == null) return null;
    const origin = Origin.catalogue('roads', 'Road events');
    Connector make(Map<String, dynamic> def, String title) => Connector.parse(
      defText(def),
      origin: origin,
      rateHost: site.host,
      entry: CatalogueEntry(
        id: '${def['id']}',
        title: title,
        description: '${def['description']}',
        category: 'roads',
        provider: '${def['provider']}',
        coverage: site.name,
        needsKey: true,
        keyAlias: site.keyAlias,
        defaultOn: false,
        featured: false,
        path: '',
        attribution: '${def['attribution']}',
        license: '',
        docs: site.keyPage,
        sha256: null,
      ),
    );
    final events = make(road511EventsDef(site), '${site.name} road events');
    final cond = road511ConditionsDef(site);
    return RoadSource(
      record: r,
      title: '511 road events: ${site.host}',
      covers: site.covers,
      connectors: [events, if (cond != null) make(cond, '${site.name} winter road conditions')],
      keyAlias: site.keyAlias,
      keyTitle: site.keyTitle,
      site: site,
    );
  }

  RoadSource? _feed(RoadSourceRecord r) {
    final feed = _file.feedById(r.id);
    final url = r.url == null ? null : stripCredentials(r.url!);
    if (url == null || !url.valid) return null;
    final keyFeed = feed != null && feed.access == 'key' && feed.auth != null ? feed : null;
    final needsKey = keyFeed != null;
    final legacy = r.id == 'iddot';
    final host = Uri.parse(url.url).host;
    final spec = WzdxSpec(
      id: legacy ? 'wzdx-idaho' : (feed == null ? 'wzdx-${_hash(url.url)}' : feed.sourceId),
      title: legacy ? 'Road work zones near the place, Idaho (WZDx)' : 'Road work zones near the place, ${feed?.area ?? r.name ?? host} (WZDx)',
      provider: legacy ? 'Idaho Transportation Department' : (feed?.publisher ?? r.name ?? host),
      area: feed?.area ?? r.name ?? host,
      url: url.url,
      auth: keyFeed?.auth,
      keyAlias: keyFeed?.keyAlias,
      updateMinutes: feed == null ? null : updateMinutesOf(feed.update),
      legacy: legacy,
    );
    final def = wzdxDef(spec);
    final c = Connector.parse(
      defText(def),
      origin: const Origin.catalogue('roads', 'Road events'),
      rateHost: feed?.rateLimit != null ? 'wzdx:${feed!.id}' : null,
      entry: CatalogueEntry(
        id: spec.id,
        title: '${spec.area} road work',
        description: '${def['description']}',
        category: 'roads',
        provider: spec.provider,
        coverage: spec.area,
        needsKey: needsKey,
        keyAlias: keyFeed?.keyAlias,
        defaultOn: false,
        featured: false,
        path: '',
        attribution: '${def['attribution']}',
        license: '',
        docs: feed?.keyPage,
        sha256: null,
      ),
    );
    if (feed?.rateLimit != null) limiter.setLimit('wzdx:${feed!.id}', feed.rateLimit!);
    return RoadSource(
      record: r,
      title: 'WZDx road work: ${feed?.publisher ?? r.name ?? host}',
      covers: 'Planned work zones and lane closures',
      connectors: [c],
      keyAlias: keyFeed?.keyAlias,
      keyTitle: keyFeed?.keyTitle,
      feed: feed,
    );
  }

  static String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final u in s.codeUnits) {
      h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return 'custom-${h.toRadixString(16)}';
  }

  /// The name a key is kept under now: Idaho's old `idaho511` is the one key of 511.idaho.gov.
  static String currentAlias(String alias) => alias == kOldIdahoAlias ? 'road511.511.idaho.gov' : alias;

  /// Today's Idaho 511 sources and their key become the one Idaho 511 source with the same key: no re-entry, no prompt, no message.
  /// Run once at start, before the keys are read; running it again changes nothing, and nothing is deleted.
  ///
  /// 1. The key `live.key.idaho511` is copied to `live.key.road511.511.idaho.gov` and read back; the old one stays (an older linked
  ///    device and the sources that still name it keep working).
  /// 2. If the key exists or `idaho511-events` or `idaho511-winter-roads` is on, the Idaho 511 source is added. Which connectors are
  ///    on stays as it was: the ids are the same.
  /// 3. If `wzdx-idaho` is on, the Idaho DOT WZDx feed is added (its address is the site's own, from the data file).
  ///
  /// Returns true when anything changed.
  Future<bool> migrateIdaho(TokenStore secrets, {String Function(String name)? secretName}) async {
    String nm(String alias) => secretName == null ? 'live.key.$alias' : secretName(alias);
    var changed = false;
    final site = _file.siteByHost('511.idaho.gov');
    if (site == null) return false;
    String? oldKey;
    try {
      oldKey = await secrets.read(nm(kOldIdahoAlias));
    } catch (_) {}
    final hasOld = oldKey != null && oldKey.isNotEmpty;
    var keyOk = true;
    if (hasOld) {
      String? now;
      try {
        now = await secrets.read(nm(site.keyAlias));
      } catch (_) {}
      if (now == null || now.isEmpty) {
        try {
          await secrets.write(nm(site.keyAlias), oldKey);
          final back = await secrets.read(nm(site.keyAlias));
          keyOk = back == oldKey;
          changed = true;
        } catch (e) {
          keyOk = false;
          logError('Idaho 511 key move', error: e);
        }
      }
    }
    if (!keyOk) return changed;
    final on = settings.liveSourcesOn;
    if (hasOld || on.contains(kLegacyIdaho.eventsId) || on.contains(kLegacyIdaho.conditionsId)) {
      final before = records.length;
      add(const RoadSourceRecord.site('511.idaho.gov'));
      if (records.length != before) changed = true;
    }
    if (on.contains('wzdx-idaho') && site.ownWzdx != null) {
      final before = records.length;
      add(RoadSourceRecord.feed('iddot', url: stripCredentials(site.ownWzdx!).url));
      if (records.length != before) changed = true;
    }
    if (changed) logInfo('Road sources: the Idaho 511 sources and key were moved to the one Idaho 511 source');
    return changed;
  }
}
