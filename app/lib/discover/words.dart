import '../maps/ui/format.dart' show formatBytes;
import 'discover_state.dart';
import 'ledger.dart';
import 'recipe.dart';

/// The words Discover's pages use for items, settings and groups, in one place so the Get sheet, Customize, the wizard's summary
/// and the Remove sheet always agree.

/// The group an item is listed under in Customize and the progress page.
String groupOf(ItemKind k) => switch (k) {
  ItemKind.library => 'Libraries',
  ItemKind.mapRegion => 'Map',
  ItemKind.liveSource => 'Weather and alerts',
  ItemKind.notebook || ItemKind.checklist => 'Checklists and notebooks',
  ItemKind.askStarters => 'Ask starter questions',
};

/// The groups in the order the pages show them.
const List<ItemKind> kGroupOrder = [ItemKind.library, ItemKind.mapRegion, ItemKind.liveSource, ItemKind.notebook, ItemKind.askStarters];

/// Kinds listed together (notebooks and checklists).
bool sameGroup(ItemKind a, ItemKind b) => groupOf(a) == groupOf(b);

String _n(int n, String one, String many) => '$n ${n == 1 ? one : many}';

/// What an activity includes, as chips: "2 libraries", "1 map", "Weather and alerts", "2 checklists", "12 starter questions".
List<String> includesChips(Iterable<RecipeItem> items) {
  final list = items.toList();
  int count(ItemKind k) => list.where((i) => i.kind == k).length;
  final qs = list.where((i) => i.kind == ItemKind.askStarters).fold<int>(0, (s, i) => s + i.lines.length);
  return [
    if (count(ItemKind.library) > 0) _n(count(ItemKind.library), 'library', 'libraries'),
    if (count(ItemKind.mapRegion) > 0) _n(count(ItemKind.mapRegion), 'map', 'maps'),
    if (count(ItemKind.liveSource) > 0) 'Weather and alerts',
    if (count(ItemKind.checklist) > 0) _n(count(ItemKind.checklist), 'checklist', 'checklists'),
    if (count(ItemKind.notebook) > 0) _n(count(ItemKind.notebook), 'notebook', 'notebooks'),
    if (qs > 0) _n(qs, 'starter question', 'starter questions'),
  ];
}

/// An item's name on Discover's pages.
String itemTitle(DiscoverState d, RecipeItem i) => switch (i.kind) {
  ItemKind.askStarters => _n(i.lines.length, 'starter question', 'starter questions'),
  ItemKind.notebook when i.title.isEmpty => notebookTitle(i.id),
  _ => d.titleOf(i),
};

/// A starter log's or template's name from its id ("starter.water_rotation" -> "Water rotation log"), until the templates are read.
String notebookTitle(String id) {
  final base = id.startsWith('starter.') ? id.substring(8) : id;
  final words = base.replaceAll('_', ' ');
  return '${words[0].toUpperCase()}${words.substring(1)} log';
}

/// An item's size in a list ("210 MB"); null for an item that downloads nothing worth saying.
String? itemSize(DiscoverState d, RecipeItem i) => i.kind.downloads ? formatBytes(d.bytesOf(i)) : null;

/// A setting in a list: "Weather alerts (NWS, by point) on", "Weather card shown on Home".
String settingWords(DiscoverState d, String key, Object? value) {
  final on = value == true;
  if (key.startsWith('live:')) {
    final i = d.itemByKey(key) ?? RecipeItem(kind: ItemKind.liveSource, id: key.substring(5), title: key.substring(5));
    return '${d.titleOf(i)} ${on ? 'on' : 'off'}';
  }
  return switch (key) {
    'home:weather' => on ? 'Weather card shown on Home' : 'Weather card hidden on Home',
    'home:shortcuts' => on ? 'Shortcuts shown on Home' : 'Shortcuts hidden on Home',
    'home:ask' => on ? 'Search box shown on Home' : 'Search box hidden on Home',
    'watch:here' => on ? 'Weather and alerts watch where you are' : 'Weather and alerts stop watching where you are',
    _ => key,
  };
}

/// One line for all of a plan's changes: "Turns on weather and alerts".
String? changesSummary(List<SettingChange> changes) {
  if (changes.isEmpty) return null;
  final live = changes.where((c) => c.key.startsWith('live:') && c.after == true).length;
  final home = changes.where((c) => c.key.startsWith('home:') && c.after == true).length;
  final parts = [
    if (live > 0) 'Turns on weather and alerts',
    if (home > 0 && live == 0) 'Shows the weather card on Home',
  ];
  return parts.isEmpty ? '${changes.length} settings' : parts.join(', ');
}

/// What a plan downloads and makes, one line each: "Medical encyclopedia · 1.4 GB".
List<String> planDownloadLines(DiscoverState d, InstallPlan p) => [
  for (final x in p.adds)
    if (x.item.kind != ItemKind.liveSource) [itemTitle(d, x.item), ?itemSize(d, x.item)].join(' · '),
];

/// The status line of an item in Customize: its size, or that it is here already and who shares it.
(String, bool) customizeLine(DiscoverState d, PlannedItem p) {
  final i = p.item;
  if (p.already || p.sharedWith.isNotEmpty) {
    final shared = p.sharedWith.isEmpty ? '' : ' · shared with ${p.sharedWith.map(d.activityTitle).join(', ')}';
    return ('Already on Cache$shared', true);
  }
  if (i.kind == ItemKind.liveSource) return (d.device.providerOf(i) ?? 'Live data', false);
  return (itemSize(d, i) ?? 'Made on this device', false);
}
