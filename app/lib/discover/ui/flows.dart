import 'package:flutter/material.dart';

import '../discover_state.dart';
import '../recipe.dart';
import 'kit.dart';
import 'progress_page.dart';
import 'sheets.dart';

/// Get on an activity, wherever it is tapped: the Get sheet first (nothing installs before the person approves it), then the
/// progress page.
Future<void> getActivity(BuildContext context, DiscoverState d, Activity a) async {
  final data = await activitySheetData(d, a);
  if (!context.mounted) return;
  if (!await showGetSheet(context, data) || !context.mounted) return;
  await d.get(a);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProgressPage(discover: d, activities: [a])));
}

/// Update on an activity: the same sheet, saying what the newer recipe adds and changes.
Future<void> updateActivity(BuildContext context, DiscoverState d, Activity a) async {
  final data = await activitySheetData(d, a, verb: 'Update');
  if (!context.mounted) return;
  if (!await showGetSheet(context, data) || !context.mounted) return;
  await d.updateActivity(a);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProgressPage(discover: d, activities: [a])));
}

/// Remove on an added activity: the Remove sheet first.
Future<void> removeActivity(BuildContext context, DiscoverState d, Activity a) async {
  final data = await removeSheetData(d, a);
  if (!context.mounted) return;
  if (!await showRemoveSheet(context, data) || !context.mounted) return;
  await d.remove(a);
  if (!context.mounted) return;
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text('${a.title} removed')));
}

/// Get on a library tile or a collection: the person's own, after the same sheet.
Future<void> getItems(BuildContext context, DiscoverState d, {required String title, required String icon, required List<RecipeItem> items}) async {
  final data = await itemsSheetData(d, title: title, icon: discoverIcon(icon), items: items);
  if (!context.mounted) return;
  if (data.downloads.isEmpty) return;
  if (!await showGetSheet(context, data) || !context.mounted) return;
  await d.getOwn(await d.missing(items));
  if (!context.mounted) return;
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text('Downloading $title. It shows in the Library.')));
}

/// Get on a map tile.
Future<void> getMap(BuildContext context, DiscoverState d, MapOffer o) async {
  final data = GetSheetData(icon: discoverIcon('map'), title: 'Add ${o.title}', bytes: o.bytes ?? 0, free: d.device.freeBytes(), downloads: ['${o.title} map, routes and places']);
  if (!await showGetSheet(context, data) || !context.mounted) return;
  await d.device.getMap(o);
}

/// Done in Customize on an added activity: what is switched on now is approved on the Get sheet before it installs; what is
/// switched off is released. False when the person cancelled.
Future<bool> applyCustomize(BuildContext context, DiscoverState d, Activity a) async {
  final data = await activitySheetData(d, a);
  if (!context.mounted) return false;
  if (data.downloads.isNotEmpty || data.changes.isNotEmpty) {
    if (!await showGetSheet(context, data)) return false;
  }
  await d.get(a);
  return true;
}
