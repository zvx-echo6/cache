// What a device shares of its regions with linked devices, with one writer per file (Maps sync; see share_rules.dart). The region
// engine's own database (regions.sqlite) never syncs. Each device writes, under its own name in `<regions>/regions-share/`:
//  - `<device>.json`: its regions (name, kind, box, the parts it holds and how each stands, its map areas, off-road packs);
//  - `<device>.deletes.json`: the regions it deleted, each with the time, so every linked device deletes it too.
// A device reads its own list and every other device's, read-only: the Regions list is the union, this device's own first. A delete is
// applied by each device to its own copy (never written into another device's file); a region added after the delete is newer and
// stays. No Flutter and no package:cache_search imports.

import 'dart:convert';
import 'dart:io';

import '../files.dart';

/// The folder beside the region engine's database.
const String kRegionsShareDir = 'regions-share';

/// The file the region engine keeps this device's share name in (hidden: it never syncs).
const String kShareIdFile = '.share-id';

/// A region another device shares.
class PeerRegion {
  const PeerRegion({
    required this.id,
    required this.name,
    required this.device,
    required this.added,
    this.kind,
    this.bbox,
    this.routing = false,
    this.places = false,
    this.areas = const [],
    this.offroad = const [],
    this.terrain = const [],
    this.routingPart,
    this.placesPart,
  });

  final String id;
  final String name;
  final String device;

  /// When the other device added it (milliseconds): a delete made after this ends it.
  final int added;
  final String? kind;
  final List<double>? bbox;
  final bool routing;
  final bool places;
  final List<String> areas;
  final List<Map<String, dynamic>> offroad;
  final List<String> terrain;

  /// How the other device's parts stood when it wrote this (`state`, and `bytes` once ready).
  final Map<String, dynamic>? routingPart;
  final Map<String, dynamic>? placesPart;

  factory PeerRegion.fromJson(String device, String id, Map<String, dynamic> j) => PeerRegion(
    id: id,
    name: j['name'] as String? ?? id,
    device: device,
    added: (j['added'] as num?)?.toInt() ?? 0,
    kind: j['kind'] as String?,
    bbox: j['bbox'] is List && (j['bbox'] as List).length == 4 ? [for (final v in j['bbox'] as List) (v as num).toDouble()] : null,
    routing: j['routing'] == true,
    places: j['places'] == true,
    areas: [for (final a in (j['areas'] as List? ?? const [])) a as String],
    offroad: [for (final p in (j['offroad'] as List? ?? const [])) if (p is Map) p.cast<String, dynamic>()],
    terrain: [for (final a in (j['terrain'] as List? ?? const [])) a as String],
    routingPart: (j['routingPart'] as Map?)?.cast<String, dynamic>(),
    placesPart: (j['placesPart'] as Map?)?.cast<String, dynamic>(),
  );
}

/// A region deleted on a device, and when (milliseconds).
class RegionDelete {
  const RegionDelete(this.id, this.at);

  final String id;
  final int at;

  /// Whether this delete ends a region that was added at [added] (milliseconds).
  bool ends(int added) => at >= added;
}

/// A device name as a file name: letters, digits, `-` and `_`.
bool safeDevice(String s) => s.isNotEmpty && s.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s);

/// This device's share files in the region engine's folder [regionsDir].
class RegionsShare {
  RegionsShare(this.regionsDir);

  final Directory regionsDir;

  Directory get dir => Directory('${regionsDir.path}/$kRegionsShareDir');

  /// This device's share name (made by the region engine when it opens), or null.
  String? get ownId {
    try {
      final t = File('${regionsDir.path}/$kShareIdFile').readAsStringSync().trim();
      return safeDevice(t) ? t : null;
    } catch (_) {
      return null;
    }
  }

  String? _lastWritten;
  final Map<String, (int, DateTime, String)> _read = {};

  // The files are small, and the calls are made from the region state's refresh, which screens and tests await on the UI's own turn:
  // plain synchronous file calls, so none waits for an event loop turn that is not coming.

  /// Writes this device's regions, [regions] by id, when they differ from what was last written. Returns whether a file was written.
  bool writeOwn(Map<String, Map<String, dynamic>> regions) {
    final id = ownId;
    if (id == null) return false;
    final text = jsonEncode({'v': 1, 'regions': regions});
    final f = File('${dir.path}/$id.json');
    if (_lastWritten == text && f.existsSync()) return false;
    dir.createSync(recursive: true);
    writeStringAtomicSync(f, text);
    _lastWritten = text;
    return true;
  }

  /// The regions the other devices share, in device order (a name that is not a device, a conflict copy, a hidden or half-written
  /// file is not read).
  List<PeerRegion> readPeers() {
    final own = ownId;
    final out = <PeerRegion>[];
    if (!dir.existsSync()) return out;
    final files = <(String, File)>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.json') || name.endsWith('.deletes.json')) continue;
      final dev = name.substring(0, name.length - 5);
      if (!safeDevice(dev) || dev == own) continue;
      files.add((dev, e));
    }
    files.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (dev, f) in files) {
      final j = _json(f);
      final regions = j?['regions'];
      if (regions is! Map) continue;
      for (final e in regions.entries) {
        if (e.value is! Map) continue;
        try {
          out.add(PeerRegion.fromJson(dev, e.key as String, (e.value as Map).cast<String, dynamic>()));
        } catch (_) {}
      }
    }
    return out;
  }

  /// Every region delete shared: this device's own and, with [peers], the other devices'.
  List<RegionDelete> readDeletes({bool peers = true}) {
    final own = ownId;
    final out = <RegionDelete>[];
    if (!dir.existsSync()) return out;
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!name.endsWith('.deletes.json')) continue;
      final dev = name.substring(0, name.length - '.deletes.json'.length);
      if (!safeDevice(dev) || (dev != own && !peers)) continue;
      final j = _json(e);
      for (final d in (j?['deletes'] as List? ?? const [])) {
        if (d is Map && d['id'] is String && d['at'] is num) out.add(RegionDelete(d['id'] as String, (d['at'] as num).toInt()));
      }
    }
    return out;
  }

  /// Notes that this device deleted region [id] now, so every linked device deletes it too.
  void recordDelete(String id, {int? at}) {
    final dev = ownId;
    if (dev == null) return;
    final mine = readDeletes(peers: false).where((d) => d.id != id).toList();
    mine.add(RegionDelete(id, at ?? DateTime.now().millisecondsSinceEpoch));
    dir.createSync(recursive: true);
    writeStringAtomicSync(File('${dir.path}/$dev.deletes.json'), jsonEncode({'deletes': [for (final d in mine) {'id': d.id, 'at': d.at}]}));
  }

  Map<String, dynamic>? _json(File f) {
    try {
      final st = f.statSync();
      final key = f.path;
      final had = _read[key];
      if (had != null && had.$1 == st.size && had.$2 == st.modified) return jsonDecode(had.$3) as Map<String, dynamic>?;
      final text = f.readAsStringSync();
      _read[key] = (st.size, st.modified, text);
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}
