import 'dart:async';

import 'package:cache_search/cache_search.dart' show GeoPoint;
import 'package:flutter/material.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart';
import '../../settings/data_policy.dart';
import '../../theme.dart';
import '../problem_words.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_page.dart';
import 'regions_list_sheet.dart';
import '../../layout/adaptive.dart' show showFittedSheet;

/// "Map, directions, places and off-road.": the parts a download brings, as one sentence.
String partsSentence({bool map = false, bool routing = false, bool places = false, bool offroad = false}) {
  final p = [if (map) 'map', if (routing) 'directions', if (places) 'places', if (offroad) 'off-road'];
  if (p.isEmpty) return '';
  final words = p.length == 1 ? p.single : '${p.sublist(0, p.length - 1).join(', ')} and ${p.last}';
  return '${words[0].toUpperCase()}${words.substring(1)}.';
}

/// The size words of a download: "1.0 GB", or "Size unknown" when the catalogue has none for it.
String sizeWords(int? bytes) => bytes == null ? 'Size unknown' : formatBytes(bytes);

/// WORDING (cache-pm, approved): with the core's plan, the size on the device and what is fetched; without one (offline), only
/// the catalogue's download figure.
String regionSizeLine({int? onDevice, int? download}) {
  // WORDING (cache-pm, approved): "Takes" says it is what it will need, not what is already there.
  if (onDevice != null && download != null) return 'Takes ${formatBytes(onDevice)} on this device (${formatBytes(download)} to download)';
  if (download != null) return '${formatBytes(download)} to download';
  return 'Size unknown';
}

/// How a layer is named in the pop-up's notes: the base map is "the map"; another layer by its own name without a trailing
/// bracket ("Hillshade", "Contour lines").
String _layerWords(LayerDef d) => d.isBase ? 'the map' : d.title.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '');

/// "Hillshade and contour lines", "The map and hillshade": [names] as a sentence start (the first one capitalised, the others as
/// written after "and").
String _namesSentence(List<String> names) {
  String low(String n) => n == 'the map' || n.isEmpty ? n : n[0].toLowerCase() + n.substring(1);
  final parts = [for (var i = 0; i < names.length; i++) i == 0 ? names[i] : low(names[i])];
  final joined = parts.length == 1 ? parts.single : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  return joined[0].toUpperCase() + joined.substring(1);
}

/// The notes under a region's size in the download pop-up (at most two lines), from its plan's map layers:
/// - a layer that is too big at every zoom tried is left out of the download: "Hillshade is left out: too big for one download.";
/// - a layer that was stepped down to a lower top zoom to fit: "The map is less detailed at close zoom to fit one download.";
/// - none when everything fits at full detail. Left out comes first. A layer that shares another layer's tiles (contour lines with
///   hillshade) goes with it.
List<String> regionMapNotes(RegionPlan p) {
  final left = <LayerDef>[], less = <LayerDef>[];
  for (final m in p.map) {
    if (!m.estimate.allowed) {
      left.add(m.def);
    } else if (m.estimate.maxZoom < m.def.maxZoom) {
      less.add(m.def);
    }
  }
  for (final s in p.sharing) {
    final owner = p.map.where((m) => m.def.id == s.ownerId).firstOrNull;
    if (owner == null) continue;
    if (!owner.estimate.allowed) {
      left.add(s.def);
    } else if (owner.estimate.maxZoom < owner.def.maxZoom) {
      less.add(s.def);
    }
  }
  return [
    if (left.isNotEmpty) '${_namesSentence([for (final d in left) _layerWords(d)])} ${left.length == 1 ? 'is' : 'are'} left out: too big for one download.',
    if (less.isNotEmpty) '${_namesSentence([for (final d in less) _layerWords(d)])} ${less.length == 1 ? 'is' : 'are'} less detailed at close zoom to fit one download.',
  ];
}

/// What downloading [list] would put on the device and fetch, from the core's plan (routing and places as the core counts them, the
/// map layers' estimates, the off-road packs); null when any plan cannot be made (offline, the index out of reach). It is asked in the
/// background and never waited for by the pop-up: the dialog
/// then shows the catalogue's download figure alone.
Future<({int onDevice, int download, List<String> notes})?> planSizeOf(RegionsState regions, List<(RegionRecord, RegionOffer)> list) async {
  var onDevice = 0, download = 0;
  final notes = <String>[];
  for (final (rec, o) in list) {
    try {
      final p = await regions.plan(rec);
      if (o.routing) {
        final r = p.routing;
        if (r == null || p.routingProblem != null) return null;
        onDevice += r.bytes;
        download += r.downloadBytes;
      }
      if (o.places) {
        final pl = p.places;
        if (pl == null || p.placesProblem != null) return null;
        onDevice += pl.bytes;
        download += pl.downloadBytes;
      }
      if (o.map) {
        // Every layer too big for one download (a country): the plan has no map figure, and the part is not planned.
        if (p.mapAllowed.isEmpty) return null;
        for (final n in regionMapNotes(p)) {
          if (!notes.contains(n)) notes.add(n);
        }
        onDevice += p.mapBytes + p.mapBytesAlready;
        download += p.mapBytes;
      }
      if (o.offroad && p.offroadAllowed) {
        onDevice += p.offroad!.downloadBytes + p.offroad!.bytesAlready;
        download += p.offroad!.downloadBytes;
      }
    } catch (_) {
      return null;
    }
  }
  // Nothing planned (a country whose roads are not published and whose map is too big): never "0 B"; the catalogue's figure stays.
  if (onDevice <= 0) return null;
  return (onDevice: onDevice, download: download, notes: notes);
}

/// Says [text] at the bottom of the screen, with [action] when given: a button's result is always shown at once.
/// A screen that has closed meanwhile (the answer came after it went) is told nothing.
void tell(ScaffoldMessengerState m, String text, {SnackBarAction? action}) {
  if (!m.mounted) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(text), action: action));
}

/// Taps on a region of the catalogue (the Regions sheet, Downloads) all come here: one pop-up for every case, from what [RegionsState.offer]
/// says. A region not on the phone downloads; one that stopped part way carries on (and can add off-road); one on the phone without
/// off-road adds it; one that is downloading or complete opens its own page. Sizes come from the catalogue; only an area drawn on
/// the map is worked out on the phone ([drawnSize]).
Future<void> openRegionOffer(BuildContext context, RegionsState regions, RegionRecord rec, {Future<int?> Function()? drawnSize}) async {
  // The search field it was opened from would take the focus (and the keyboard) back when the pop-up closes.
  FocusManager.instance.primaryFocus?.unfocus();
  var offer = regions.offer(rec);
  // Add off-road where no pack covers the region: no offer to confirm, but never silent either: it says why (the same words as the
  // greyed rows), whichever row or button asked.
  if (offer.kind == RegionOfferKind.addParts && offer.offroad && !offer.places) {
    final covered = await regions.offroadCoveredNow(rec.id);
    if (!context.mounted) return;
    if (covered == false) {
      tell(ScaffoldMessenger.of(context), kNoOffroadLine);
      return;
    }
  }
  offer = regions.offer(rec);
  switch (offer.kind) {
    case RegionOfferKind.busy || RegionOfferKind.onPhone:
      await openRegionPage(context, regions, rec.id);
    case RegionOfferKind.carryOn || RegionOfferKind.tryAgain:
      await askCarryOn(context, regions, rec.id, name: rec.name, offer: offer, record: rec);
    case RegionOfferKind.addParts:
      await _askAddParts(context, regions, rec, offer);
    case RegionOfferKind.download:
      await askDownloadRegions(context, regions, [rec], drawnSize: drawnSize);
  }
}

/// The size of an area drawn on the map, worked out on the phone (the only region that is): road routing and off-road from their
/// indexes, the map from the layers' sources. Says it is working while it does; null when it cannot be worked out.
Future<int?> drawnSizeOf(BuildContext context, RegionsState regions, RegionRecord rec) async {
  final m = ScaffoldMessenger.of(context);
  tell(m, 'Working out the size of the area');
  try {
    final p = await regions.plan(rec);
    m.hideCurrentSnackBar();
    return (p.routing?.downloadBytes ?? 0) + p.mapBytes + (p.offroadAllowed ? p.offroad!.downloadBytes : 0);
  } catch (_) {
    m.hideCurrentSnackBar();
    return null;
  }
}

/// The download pop-up for regions not on the phone, then each starts (now, or once on Wi-Fi). One region: "Download Jerome County?",
/// "Map, directions, places and off-road." and its size; several: "Download 3 regions?" and their sizes in all.
Future<void> askDownloadRegions(BuildContext context, RegionsState regions, List<RegionRecord> list, {Future<int?> Function()? drawnSize}) async {
  final offers = [for (final r in list) (r, regions.offer(r))];
  final todo = [for (final o in offers) if (o.$2.kind == RegionOfferKind.download) o];
  if (todo.isEmpty) return;
  var bytes = todo.every((t) => t.$2.bytes != null) ? todo.fold<int>(0, (s, t) => s + t.$2.bytes!) : null;
  if (bytes == null && drawnSize != null && todo.length == 1) bytes = await drawnSize();
  final dir = await regions.supportDir();
  if (!context.mounted) return;
  final one = todo.length == 1 ? todo.single : null;
  final shared = todo.any((t) => t.$2.offroad && t.$2.offroadShared);
  List<String> summaryWith(String size, [List<String> notes = const []]) => [
    if (one != null)
      partsSentence(map: one.$2.map, routing: one.$2.routing, places: one.$2.places, offroad: one.$2.offroad)
    else
      [for (final t in todo) t.$1.name].join(', '),
    if (shared) "Off-road data for the state is already on this device; only this area's terrain is new.",
    size,
    ...notes,
  ].where((l) => l.isNotEmpty).toList();
  // The pop-up opens at once with the catalogue's figure, said to be the download (never room on the device). The core's plan is
  // asked meanwhile, not waited for (1.0.27 worked the size out for up to a minute before it opened, and said "Can't be downloaded
  // here" when that failed); when it arrives the pop-up changes in place to what the region takes on the device and what is
  // fetched. Offline there is no plan and the line stays as it was.
  final live = ValueNotifier<DownloadUpdate?>(null);
  var closed = false;
  unawaited(planSizeOf(regions, todo).then((planned) {
    if (planned == null || closed) return;
    live.value = (summary: summaryWith(regionSizeLine(onDevice: planned.onDevice, download: planned.download), planned.notes), bytes: planned.onDevice);
  }));
  final m = ScaffoldMessenger.of(context);
  final choice = await askToDownload(
    context,
    title: one != null ? 'Download ${one.$1.name}?' : 'Download ${todo.length} regions?',
    summary: summaryWith(bytes != null ? regionSizeLine(download: bytes) : sizeWords(null)),
    bytes: bytes,
    name: one?.$1.name ?? '${todo.length} regions',
    dir: dir.path,
    policy: regions.policy,
    updates: live,
  );
  closed = true;
  if (choice == DownloadChoice.cancel) return;
  final names = one?.$1.name ?? '${todo.length} regions';
  tell(m, choice == DownloadChoice.now ? 'Downloading $names' : '$names will download on Wi-Fi');
  for (final (rec, o) in todo) {
    unawaited(_run(m, 'download ${rec.name}', () async {
      if (choice == DownloadChoice.now) {
        await regions.download(rec, routing: o.routing, map: o.map, places: o.places, offroad: o.offroad, anyway: true);
      } else {
        await regions.downloadOnWifi(rec, routing: o.routing, map: o.map, places: o.places, offroad: o.offroad);
      }
    }, retry: () => askDownloadRegions(context, regions, [rec]), resume: (e) => regions.resumeAndStart(e.region)));
  }
}

/// "Carry on with Idaho?": what is left and what is already here, and, when the region has no off-road data yet, a second button to
/// add it too. Then only what stopped starts again ([RegionsState.carryOn]).
Future<void> askCarryOn(BuildContext context, RegionsState regions, String id, {required String name, RegionOffer? offer, RegionRecord? record}) async {
  final rec = record ?? await regions.recordOf(id);
  final o = offer ?? (rec == null ? null : regions.offer(rec));
  final dir = await regions.supportDir();
  if (!context.mounted) return;
  final again = o?.kind == RegionOfferKind.tryAgain;
  final left = o?.bytes;
  final m = ScaffoldMessenger.of(context);
  // Nothing left to download: a pop-up of 0 B asks nothing, so it carries on at once.
  if (left == 0) {
    await carryOnNow(m, regions, id, name: name, again: again);
    return;
  }
  final addOffroad = (o?.offroad ?? false) && rec != null;
  final choice = await askToDownload(
    context,
    title: again ? 'Try again with $name?' : 'Carry on with $name?',
    summary: [
      if (left != null) '${formatBytes(left)} to download.' else 'The size of what is left is not known.',
      if ((o?.already ?? 0) > 0) '${formatBytes(o!.already)} is already here.',
      if (addOffroad) "Off-road is not on this device yet${o!.addBytes > 0 ? ' (${formatBytes(o.addBytes)})' : ''}. Add it from $name's page.",
    ],
    bytes: left,
    name: name,
    action: again ? 'Try again' : 'Carry on',
    dir: dir.path,
    policy: regions.policy,
  );
  if (choice == DownloadChoice.cancel) return;
  await carryOnNow(m, regions, id, name: name, again: again, anyway: choice == DownloadChoice.now, wifi: choice == DownloadChoice.whenWifi);
}

/// Carries on with region [id] at once (a fix button: the tap was the person's go), saying so and, if it cannot, why with the next
/// step ("Try again", or "Download anyway" on mobile data with mobile-data downloads off). [wifi] leaves it to start on Wi-Fi.
Future<void> carryOnNow(ScaffoldMessengerState m, RegionsState regions, String id, {required String name, bool again = false, bool anyway = false, bool wifi = false}) async {
  if (wifi) {
    regions.carryOnOnWifi(id);
    tell(m, '$name will carry on on Wi-Fi');
    return;
  }
  tell(m, again ? 'Trying again with $name' : 'Carrying on with $name');
  if (again) regions.noteTry(id);
  try {
    await regions.carryOn(id, anyway: anyway);
  } on MobileDataBlocked catch (e) {
    tell(m, e.message, action: SnackBarAction(label: 'Download anyway', onPressed: () => unawaited(carryOnNow(m, regions, id, name: name, again: again, anyway: true))));
  } catch (e) {
    tell(m, downloadProblemWords(e, what: again ? 'try again with $name' : 'carry on with $name'),
        action: SnackBarAction(label: 'Try again', onPressed: () => unawaited(carryOnNow(m, regions, id, name: name, again: again, anyway: anyway))));
  }
}

Future<void> _askAddParts(BuildContext context, RegionsState regions, RegionRecord rec, RegionOffer o) async {
  final dir = await regions.supportDir();
  if (!context.mounted) return;
  final l = regions.regionOf(rec.id);
  final have = l == null ? '' : partsSentence(map: l.hasMap, routing: l.hasRouting, places: l.hasPlaces).replaceFirst(RegExp(r'\.$'), '');
  final adds = [if (o.offroad) 'off-road', if (o.places) 'places'].join(' and ');
  final m = ScaffoldMessenger.of(context);
  if (o.bytes == 0) {
    tell(m, 'Adding $adds to ${rec.name}');
    await _run(m, 'add $adds to ${rec.name}', () => regions.addParts(rec, offroad: o.offroad, places: o.places));
    return;
  }
  final choice = await askToDownload(
    context,
    title: 'Add $adds to ${rec.name}?',
    summary: [
      if (have.isNotEmpty) '$have ${have.contains(' and ') ? 'are' : 'is'} already here.',
      if (o.offroad && o.offroadShared) "The state's off-road data is already on this device; only this area's terrain is new.",
      o.bytes == null ? 'Its size is not known yet.' : '${sizeWords(o.bytes)} to download.',
    ],
    bytes: o.bytes,
    name: rec.name,
    dir: dir.path,
    policy: regions.policy,
  );
  if (choice == DownloadChoice.cancel) return;
  tell(m, 'Adding $adds to ${rec.name}');
  await _run(m, 'add $adds to ${rec.name}', () => regions.addParts(rec, offroad: o.offroad, places: o.places, anyway: choice == DownloadChoice.now),
      retry: () => _askAddParts(context, regions, rec, o));
}

/// Adds places to a region downloaded before they were published for its area (its page's "Now available" row).
Future<void> askAddPlaces(BuildContext context, RegionsState regions, String id) async {
  final rec = await regions.recordOf(id);
  if (rec == null || !context.mounted) return;
  await _askAddParts(context, regions, rec, RegionOffer(RegionOfferKind.addParts, places: true, bytes: regions.costOf(rec).places));
}

/// Adds off-road to a region on the phone, from its page or its menu.
Future<void> askAddOffroad(BuildContext context, RegionsState regions, String id) async {
  final rec = await regions.recordOf(id);
  if (rec == null || !context.mounted) return;
  final o = regions.offer(rec);
  await _askAddParts(context, regions, rec, RegionOffer(RegionOfferKind.addParts, offroad: true, bytes: o.kind == RegionOfferKind.addParts ? o.bytes : regions.costOf(rec).offroad, offroadShared: o.offroadShared));
}

/// "Download this area" under a route that is outside the downloaded maps: of the route's places ([ends], where to first), the
/// first that no region with directions on this phone holds; the catalogue's region there ([RegionCatalogue.regionAt], as Download
/// this area from the map's search) gets the one download pop-up ([openRegionOffer]). Where the catalogue names none, the Regions
/// sheet at that place, to choose from.
Future<void> getRouteArea(BuildContext context, RegionsState regions, List<GeoPoint> ends) async {
  if (ends.isEmpty) return;
  final at = ends.where((p) => regions.regionHolding(p.lat, p.lon, routing: true) == null).firstOrNull ?? ends.first;
  await _offerAt(context, regions, at);
}

/// "Add off-road data" under an off-road route with no off-road data: the region on this phone that holds the first of the route's
/// places ([ends], where to first) and has no off-road yet gets Add off-road ([askAddOffroad]). With none on the phone there, as
/// [getRouteArea] at where to: the catalogue's region there (its pop-up adds off-road, or downloads it with the rest), else the
/// Regions sheet at that place.
Future<void> addRouteOffroad(BuildContext context, RegionsState regions, List<GeoPoint> ends) async {
  if (ends.isEmpty) return;
  for (final p in ends) {
    final l = regions.regionHolding(p.lat, p.lon, withoutOffroad: true);
    if (l != null) return askAddOffroad(context, regions, l.id);
  }
  await _offerAt(context, regions, ends.first);
}

/// The catalogue's region at [at] in its download pop-up, or the Regions sheet at [at] when the catalogue cannot name one.
Future<void> _offerAt(BuildContext context, RegionsState regions, GeoPoint at) async {
  RegionRecord? rec;
  try {
    await regions.catalogue.readShardAt(at.lat, at.lon);
    rec = regions.catalogue.regionAt(at.lat, at.lon);
  } catch (_) {}
  if (!context.mounted) return;
  if (rec != null) return openRegionOffer(context, regions, rec);
  await showRegionsSheet(context, regions, lat: at.lat, lon: at.lon);
}

/// Show on map for a region on this phone: the Maps tab with the map fitted to the region ([MapsState.showAreaOnMap]); false when
/// its box is not known.
bool showRegionOnMap(RegionsState regions, String id) {
  final b = regions.boundsOf(id);
  if (b == null) return false;
  regions.maps.showAreaOnMap(b);
  return true;
}

/// Runs a region action, and when it fails says what happened and the next step in plain words, with "Try again".
Future<void> _run(ScaffoldMessengerState m, String what, Future<void> Function() f, {Future<void> Function()? retry, Future<void> Function(DownloadsPaused)? resume}) async {
  try {
    await f();
  } on MobileDataBlocked catch (e) {
    tell(m, e.message);
  } on DownloadsPaused catch (e) {
    // Paused: one tap on Resume clears the pause and starts the download.
    tell(m, e.message, action: resume == null ? null : SnackBarAction(label: 'Resume', onPressed: () => unawaited(_run(m, 'start ${e.region.name}', () => resume(e)))));
  } catch (e) {
    tell(m, downloadProblemWords(e, what: what), action: retry == null ? null : SnackBarAction(label: 'Try again', onPressed: () => unawaited(retry())));
  }
}

/// "Delete and start again", offered on a region's page once Try again has not worked twice: one pop-up with what downloads again,
/// then the region is deleted and downloaded again (the parts it had).
Future<void> askStartAgain(BuildContext context, RegionsState regions, LocalRegion l) async {
  final rec = await regions.recordOf(l.id);
  if (rec == null || !context.mounted) return;
  final cost = regions.costOf(rec);
  final routing = l.hasRouting, map = l.hasMap, places = l.hasPlaces && !l.placesNotAvailable, offroad = l.hasOffroad;
  final sizes = [if (map) cost.map, if (routing) cost.routing, if (places) cost.places, if (offroad) cost.offroad];
  final bytes = sizes.contains(null) ? null : sizes.fold<int>(0, (s, b) => s + b!);
  final dir = await regions.supportDir();
  if (!context.mounted) return;
  final m = ScaffoldMessenger.of(context);
  final choice = await askToDownload(
    context,
    title: 'Delete and start again with ${l.name}?',
    summary: ['What is on this device for ${l.name} is deleted, then downloaded again.', sizeWords(bytes)],
    bytes: bytes,
    name: l.name,
    action: 'Start again',
    dir: dir.path,
    policy: regions.policy,
  );
  if (choice == DownloadChoice.cancel) return;
  tell(m, 'Starting ${l.name} again');
  await _run(m, 'start ${l.name} again', () async {
    // a repair on this device: it does not take the other devices' copies away
    await regions.remove(l.id, everywhere: false);
    if (choice == DownloadChoice.now) {
      await regions.download(rec, routing: routing, map: map, places: places, offroad: offroad, anyway: true);
    } else {
      await regions.downloadOnWifi(rec, routing: routing, map: map, places: places, offroad: offroad);
    }
  });
}

// WORDING (for cache-pm): the region delete's confirmation, the same shape as deleting a book (owner's design, 2026-11-15): the question,
// and under it, only when the delete reaches other devices (the Maps share is on and a device is linked), the line.
const String kDeleteRegionQuestion = 'Delete this region?';
const String kDeleteRegionSyncedLine = 'Deleting this will delete this from all synced devices.';

/// Asks "Delete this region?" with Cancel and Delete, and, when [synced] (Maps shared with at least one linked device), the line
/// "Deleting this will delete this from all synced devices.". True to delete.
Future<bool> confirmDeleteRegion(BuildContext context, {required bool synced}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('delete-region-confirm'),
      title: const Text(kDeleteRegionQuestion),
      content: synced ? const Text(kDeleteRegionSyncedLine, key: ValueKey('delete-region-synced-line')) : null,
      actions: [
        TextButton(key: const ValueKey('delete-region-cancel'), onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('delete-region-confirm-button'),
          style: TextButton.styleFrom(foregroundColor: ctx.t.emergency),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return yes == true;
}

/// Deletes a region after asking. There is no delete for one device: with Maps synced the region goes from every linked device.
Future<bool> askDeleteRegion(BuildContext context, RegionsState regions, LocalRegion l) async {
  final yes = await confirmDeleteRegion(context, synced: regions.deleteReachesOtherDevices);
  if (!yes || !context.mounted) return false;
  final m = ScaffoldMessenger.of(context);
  try {
    await regions.remove(l.id);
    tell(m, '${l.name} deleted');
    return true;
  } catch (e) {
    tell(m, downloadProblemWords(e, what: 'delete ${l.name}'));
    return false;
  }
}

/// Checks a region on the phone for newer map, directions and places, and fetches them.
Future<void> checkRegionUpdate(BuildContext context, RegionsState regions, LocalRegion l, {bool anyway = false}) async {
  final m = ScaffoldMessenger.of(context);
  tell(m, 'Checking ${l.name} for updates');
  final noPlaces = l.placesNotAvailable || (!l.hasPlaces && !l.isArea);
  try {
    await regions.checkUpdates();
    await regions.updateRegion(l.id, anyway: anyway);
    // Places that were not published for the area are added by the update once they are: say so.
    final now = regions.regionOf(l.id);
    if (noPlaces && now != null && !now.placesNotAvailable) tell(m, 'Places are now available for ${l.name}.');
  } on MobileDataBlocked catch (e) {
    tell(m, e.message, action: SnackBarAction(label: 'Download anyway', onPressed: () => unawaited(checkRegionUpdate(context, regions, l, anyway: true))));
  } catch (e) {
    tell(m, downloadProblemWords(e, what: 'update ${l.name}'), action: SnackBarAction(label: 'Try again', onPressed: () => unawaited(checkRegionUpdate(context, regions, l))));
  }
}

/// WORDING (owner, exact): where no off-road pack covers a region, Add off-road is greyed with this line (the region page, the
/// Regions sheet and the region's menu).
const String kNoOffroadLine = 'No off-road data is published for this area.';

/// What can be done with a region on the phone, in the order the menu lists it.
enum RegionAction { open, showOnMap, carryOn, tryAgain, addOffroad, update, delete }

/// The actions for [l]: Show on map when its box is known, a stopped or failed region's fix, then off-road when it has none, update
/// when it is complete, delete.
List<RegionAction> regionActions(RegionsState regions, LocalRegion l, {bool open = true}) => [
  if (open) RegionAction.open,
  if (regions.boundsOf(l.id) != null) RegionAction.showOnMap,
  if (l.phase == RegionPhase.stopped) RegionAction.carryOn,
  if (l.phase == RegionPhase.failed) RegionAction.tryAgain,
  if (!l.hasOffroad && !l.isArea && regions.offroadCatalogue != null) RegionAction.addOffroad,
  if (l.phase == RegionPhase.ready) RegionAction.update,
  RegionAction.delete,
];

String regionActionLabel(RegionAction a) => switch (a) {
  RegionAction.open => 'Open',
  RegionAction.showOnMap => 'Show on map',
  RegionAction.carryOn => 'Carry on',
  RegionAction.tryAgain => 'Try again',
  RegionAction.addOffroad => 'Add off-road',
  RegionAction.update => 'Check for update',
  RegionAction.delete => 'Delete',
};

IconData regionActionIcon(RegionAction a) => switch (a) {
  RegionAction.open => Icons.open_in_new,
  RegionAction.showOnMap => Icons.map_outlined,
  RegionAction.carryOn => Icons.play_arrow,
  RegionAction.tryAgain => Icons.refresh,
  RegionAction.addOffroad => Icons.terrain_outlined,
  RegionAction.update => Icons.sync,
  RegionAction.delete => Icons.delete_outline,
};

/// Does [a] for [l].
Future<void> runRegionAction(BuildContext context, RegionsState regions, LocalRegion l, RegionAction a) async {
  switch (a) {
    case RegionAction.open:
      await openRegionPage(context, regions, l.id);
    case RegionAction.showOnMap:
      showRegionOnMap(regions, l.id);
    case RegionAction.carryOn || RegionAction.tryAgain:
      await carryOnNow(ScaffoldMessenger.of(context), regions, l.id, name: l.name, again: a == RegionAction.tryAgain);
    case RegionAction.addOffroad:
      await askAddOffroad(context, regions, l.id);
    case RegionAction.update:
      await checkRegionUpdate(context, regions, l);
    case RegionAction.delete:
      await askDeleteRegion(context, regions, l);
  }
}

/// The press-and-hold menu of a region on the phone: the same actions wherever the region is listed.
Future<void> showRegionActions(BuildContext context, RegionsState regions, LocalRegion l, {bool open = true}) async {
  final chosen = await showFittedSheet<RegionAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(l.name, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final a in regionActions(regions, l, open: open))
            if (a == RegionAction.addOffroad)
              // The same check as the region page: where no pack covers the region the item is greyed and says why.
              ListenableBuilder(
                listenable: regions,
                builder: (_, _) {
                  final none = regions.offroadCovered(l.id) == false;
                  return ListTile(
                    key: ValueKey('region-action-${a.name}'),
                    leading: Icon(regionActionIcon(a)),
                    title: Text(regionActionLabel(a)),
                    subtitle: none ? const Text(kNoOffroadLine) : null,
                    enabled: !none,
                    onTap: none ? null : () => Navigator.pop(ctx, a),
                  );
                },
              )
            else
              ListTile(
                key: ValueKey('region-action-${a.name}'),
                leading: Icon(regionActionIcon(a)),
                title: Text(regionActionLabel(a)),
                onTap: () => Navigator.pop(ctx, a),
              ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (chosen != null && context.mounted) await runRegionAction(context, regions, l, chosen);
}
