import 'dart:async';

import 'package:flutter/material.dart';

import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart';
import '../../settings/data_policy.dart';
import '../problem_words.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_page.dart';

/// "Map, directions, places and off-road.": the parts a download brings, as one sentence.
String partsSentence({bool map = false, bool routing = false, bool places = false, bool offroad = false}) {
  final p = [if (map) 'map', if (routing) 'directions', if (places) 'places', if (offroad) 'off-road'];
  if (p.isEmpty) return '';
  final words = p.length == 1 ? p.single : '${p.sublist(0, p.length - 1).join(', ')} and ${p.last}';
  return '${words[0].toUpperCase()}${words.substring(1)}.';
}

/// The size words of a download: "1.0 GB", or "Size unknown" when the catalogue has none for it.
String sizeWords(int? bytes) => bytes == null ? 'Size unknown' : formatBytes(bytes);

/// Says [text] at the bottom of the screen, with [action] when given: a button's result is always shown at once.
void tell(ScaffoldMessengerState m, String text, {SnackBarAction? action}) {
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
  final offer = regions.offer(rec);
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
  final summary = [
    if (one != null)
      partsSentence(map: one.$2.map, routing: one.$2.routing, places: one.$2.places, offroad: one.$2.offroad)
    else
      [for (final t in todo) t.$1.name].join(', '),
    if (shared) "Off-road data for the state is already on this phone; only this area's terrain is new.",
    sizeWords(bytes),
  ].where((l) => l.isNotEmpty).toList();
  final m = ScaffoldMessenger.of(context);
  final choice = await askToDownload(
    context,
    title: one != null ? 'Download ${one.$1.name}?' : 'Download ${todo.length} regions?',
    summary: summary,
    bytes: bytes,
    name: one?.$1.name ?? '${todo.length} regions',
    dir: dir.path,
    policy: regions.policy,
  );
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
    }, retry: () => askDownloadRegions(context, regions, [rec])));
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
  final addOffroad = (o?.offroad ?? false) && rec != null;
  final choice = await askToDownload(
    context,
    title: again ? 'Try again with $name?' : 'Carry on with $name?',
    summary: [
      if (left != null) '${formatBytes(left)} to go.' else 'The size of what is left is not known.',
      if ((o?.already ?? 0) > 0) '${formatBytes(o!.already)} is already here.',
      if (addOffroad) "Off-road is not on this phone yet${o!.addBytes > 0 ? ' (${formatBytes(o.addBytes)})' : ''}. Add it from $name's page.",
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
  final choice = await askToDownload(
    context,
    title: 'Add $adds to ${rec.name}?',
    summary: [
      if (have.isNotEmpty) '$have ${have.contains(' and ') ? 'are' : 'is'} already here.',
      if (o.offroad && o.offroadShared) "The state's off-road data is already on this phone; only this area's terrain is new.",
      '${sizeWords(o.bytes)} to download.',
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

/// Adds off-road to a region on the phone, from its page or its menu.
Future<void> askAddOffroad(BuildContext context, RegionsState regions, String id) async {
  final rec = await regions.recordOf(id);
  if (rec == null || !context.mounted) return;
  final o = regions.offer(rec);
  await _askAddParts(context, regions, rec, RegionOffer(RegionOfferKind.addParts, offroad: true, bytes: o.kind == RegionOfferKind.addParts ? o.bytes : regions.costOf(rec).offroad, offroadShared: o.offroadShared));
}

/// Runs a region action, and when it fails says what happened and the next step in plain words, with "Try again".
Future<void> _run(ScaffoldMessengerState m, String what, Future<void> Function() f, {Future<void> Function()? retry}) async {
  try {
    await f();
  } on MobileDataBlocked catch (e) {
    tell(m, e.message);
  } catch (e) {
    tell(m, downloadProblemWords(e, what: what), action: retry == null ? null : SnackBarAction(label: 'Try again', onPressed: () => unawaited(retry())));
  }
}

/// Deletes a region after asking, with what it frees.
Future<bool> askDeleteRegion(BuildContext context, RegionsState regions, LocalRegion l) async {
  final yes = await confirmDelete(
    context,
    name: l.name,
    bytes: l.bytes,
    again: l.isArea ? 'Its map is removed from this phone.' : 'Its map, directions, places and off-road data are removed from this phone. Parts another region uses stay.',
  );
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
  try {
    await regions.checkUpdates();
    await regions.updateRegion(l.id, anyway: anyway);
  } on MobileDataBlocked catch (e) {
    tell(m, e.message, action: SnackBarAction(label: 'Download anyway', onPressed: () => unawaited(checkRegionUpdate(context, regions, l, anyway: true))));
  } catch (e) {
    tell(m, downloadProblemWords(e, what: 'update ${l.name}'), action: SnackBarAction(label: 'Try again', onPressed: () => unawaited(checkRegionUpdate(context, regions, l))));
  }
}

/// What can be done with a region on the phone, in the order the menu lists it.
enum RegionAction { open, carryOn, tryAgain, addOffroad, update, delete }

/// The actions for [l]: a stopped or failed region's fix first, then off-road when it has none, update when it is complete, delete.
List<RegionAction> regionActions(RegionsState regions, LocalRegion l, {bool open = true}) => [
  if (open) RegionAction.open,
  if (l.phase == RegionPhase.stopped) RegionAction.carryOn,
  if (l.phase == RegionPhase.failed) RegionAction.tryAgain,
  if (!l.hasOffroad && !l.isArea && regions.offroadCatalogue != null) RegionAction.addOffroad,
  if (l.phase == RegionPhase.ready) RegionAction.update,
  RegionAction.delete,
];

String regionActionLabel(RegionAction a) => switch (a) {
  RegionAction.open => 'Open',
  RegionAction.carryOn => 'Carry on',
  RegionAction.tryAgain => 'Try again',
  RegionAction.addOffroad => 'Add off-road',
  RegionAction.update => 'Check for update',
  RegionAction.delete => 'Delete',
};

IconData regionActionIcon(RegionAction a) => switch (a) {
  RegionAction.open => Icons.open_in_new,
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
  final chosen = await showModalBottomSheet<RegionAction>(
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
