import 'package:flutter/material.dart';

import '../../layout/adaptive.dart' show ContentWidth;
import '../../maps/ui/format.dart' show formatBytes;
import '../../theme.dart';
import '../discover_state.dart';
import '../recipe.dart';
import 'activity_page.dart';
import 'flows.dart';
import 'kit.dart';
import 'wizard.dart';

/// Which face of Discover a page shows: the whole store, or Resources (libraries, maps and collections, as the Library's Add to
/// Library opens it).
enum DiscoverFace { store, resources }

/// Where Discover's links go in the rest of the app (the frame sets them): the full catalogue of libraries, the Regions screen,
/// Add your own source, and the device link.
class DiscoverLinks {
  const DiscoverLinks({this.allLibraries, this.allMaps, this.ownSource, this.linkDevice, this.searchLibraries, this.askLocation, this.choosePlace});

  /// The wizard's "Where I am now": asks for the location (the system's prompt) and reads a position.
  final Future<void> Function(BuildContext context)? askLocation;

  /// The wizard's "Choose a place": a place chosen by name; null when the person went back.
  final Future<DiscoverPlace?> Function(BuildContext context)? choosePlace;

  /// "See all" under Libraries: the Kiwix catalogue and your own library (Add to Library's full list).
  final void Function(BuildContext context)? allLibraries;

  /// "See all" under Maps: Regions.
  final void Function(BuildContext context)? allMaps;

  /// "Add your own source".
  final void Function(BuildContext context)? ownSource;

  /// The wizard's "Link another device": Sharing and sync.
  final Future<void> Function(BuildContext context)? linkDevice;

  /// "Search all libraries" under a search: the catalogue searched for the words.
  final void Function(BuildContext context, String query)? searchLibraries;
}

/// The links the frame set for every Discover page; empty in tests.
DiscoverLinks discoverLinks = const DiscoverLinks();

/// Opens Discover (the store), or the wizard first while first run is not done.
Future<void> openDiscover(BuildContext context, DiscoverState d, {DiscoverFace face = DiscoverFace.store}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiscoverScreen(discover: d, face: face)));

/// Discover, laid out like an app store: search, a featured card (the first activity not added yet), and rows of tiles with Get,
/// Added or Update. A wide window shows the rows as a grid. While first run is not done the store's first screen is the wizard.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.discover, this.face = DiscoverFace.store, this.links, this.yourOwn});

  final DiscoverState discover;
  final DiscoverFace face;

  /// The links; [discoverLinks] when null.
  final DiscoverLinks? links;

  /// The YOUR OWN group (Your own library, Add a PDF and the rest), shown at the top when Add to Library opens Discover's
  /// Resources; null in Discover opened any other way.
  final Widget? yourOwn;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _query = TextEditingController();

  DiscoverState get d => widget.discover;
  DiscoverLinks get links => widget.links ?? discoverLinks;
  bool get resources => widget.face == DiscoverFace.resources;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      if (!resources && d.started && !d.firstRunDone) return DiscoverWizard(discover: d, links: links);
      return LayoutBuilder(builder: (context, c) => c.maxWidth >= 1000 ? _wide(context, c.maxWidth) : _narrow(context));
    },
  );

  // ---- the phone

  Widget _narrow(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Discover')),
    body: LayoutBuilder(
      builder: (context, c) => ListView(
        key: const ValueKey('discover-list'),
        padding: ContentWidth.padFor(c.maxWidth, min: 12).copyWith(top: 4, bottom: 24),
        children: [
          DSearchBox(hint: resources ? 'Search resources' : 'Search Discover', controller: _query, onChanged: (_) => setState(() {})),
          if (_query.text.trim().isNotEmpty)
            ..._results(context)
          else ...[
            if (resources && widget.yourOwn != null) widget.yourOwn!,
            if (!resources) ..._updates(context),
            const SizedBox(height: 8),
            if (!resources && d.featured != null) _featured(context, d.featured!),
            if (resources) ...[
              _head(context, 'Collections'),
              TileRow(tiles: _collectionTiles(context)),
              _head(context, 'Libraries', onSeeAll: links.allLibraries),
              RowStack(rows: _libraryRows(context)),
              _head(context, 'Maps', onSeeAll: links.allMaps),
              _mapsRow(context),
              _ownSource(context),
            ] else ...[
              _head(context, 'Activities'),
              TileRow(tiles: _activityTiles(context)),
              _head(context, 'Libraries', onSeeAll: links.allLibraries),
              TileRow(tiles: _libraryTiles(context)),
              _head(context, 'Maps', onSeeAll: links.allMaps),
              _mapsRow(context),
              _head(context, 'Collections'),
              TileRow(tiles: _collectionTiles(context)),
              const DHint('More ways to get things are coming.', top: 12),
            ],
          ],
        ],
      ),
    ),
  );

  Widget _mapsRow(BuildContext context) {
    final tiles = _mapTiles(context);
    if (tiles.isEmpty) return const DHint('Choose your place to see the maps for it.', top: 0);
    return TileRow(tiles: tiles);
  }

  // ---- a wide window

  Widget _wide(BuildContext context, double width) {
    final k = context.t;
    const pad = 40.0;
    final featured = resources ? null : d.featured;
    final searching = _query.text.trim().isNotEmpty;
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          key: const ValueKey('discover-list'),
          padding: const EdgeInsets.fromLTRB(pad, 30, pad, 32),
          children: [
            Row(
              children: [
                if (canPop) ...[BackButton(color: k.text), const SizedBox(width: 8)],
                Expanded(child: Text('Discover', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: k.text))),
                SizedBox(width: 480, child: DSearchBox(hint: resources ? 'Search resources' : 'Search Discover', controller: _query, onChanged: (_) => setState(() {}))),
              ],
            ),
            const SizedBox(height: 16),
            if (searching)
              Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _results(context))))
            else ...[
              if (resources && widget.yourOwn != null) Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: widget.yourOwn!)),
              if (!resources) ..._updates(context),
              if (featured != null) Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: _featured(context, featured))),
              if (!resources) ...[
                _head(context, 'Activities'),
                TileGrid(columns: 5, tiles: _activityTiles(context, grid: true)),
              ],
              _head(context, 'Libraries', onSeeAll: links.allLibraries),
              TileGrid(columns: 5, tiles: _libraryTiles(context, grid: true)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _head(context, 'Maps', onSeeAll: links.allMaps),
                      if (_mapTiles(context).isEmpty) const DHint('Choose your place to see the maps for it.', top: 0) else TileGrid(columns: 2, tiles: _mapTiles(context, grid: true)),
                    ]),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _head(context, 'Collections'),
                      TileGrid(columns: 2, tiles: _collectionTiles(context, grid: true)),
                    ]),
                  ),
                ],
              ),
              if (resources) Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: _ownSource(context))),
            ],
          ],
        ),
      ),
    );
  }

  // ---- pieces

  Widget _head(BuildContext context, String title, {void Function(BuildContext)? onSeeAll}) =>
      SectionHead(title: title, onSeeAll: onSeeAll == null ? null : () => onSeeAll(context));

  /// How many updates wait, with Update all, at the top.
  List<Widget> _updates(BuildContext context) {
    final n = d.updateCount;
    if (n == 0) return const [];
    final k = context.t;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(
              children: [
                Icon(Icons.system_update_alt, color: k.accent, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(n == 1 ? '1 update waiting' : '$n updates waiting', key: const ValueKey('discover-updates'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text))),
                TextButton(key: const ValueKey('discover-update-all'), onPressed: () => _updateAll(context), child: const Text('Update all')),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Future<void> _updateAll(BuildContext context) async {
    for (final a in d.catalogue.activities) {
      if (d.status(a) == ActivityStatus.update) await d.updateActivity(a);
    }
    for (final i in d.catalogue.libraries) {
      if (d.device.hasUpdate(i)) await d.device.update(i);
    }
  }

  Widget _featured(BuildContext context, Activity a) {
    final k = context.t;
    return Material(
      key: const ValueKey('discover-featured'),
      color: k.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: lineColor(k))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openActivity(context, a),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('FEATURED', style: TextStyle(fontSize: 12, letterSpacing: 0.72, fontWeight: FontWeight.w500, color: k.accent)),
              const SizedBox(height: 10),
              Row(
                children: [
                  DTile(discoverIcon(a.icon), size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        Text(a.tagline, style: TextStyle(fontSize: 13, color: k.secondary)),
                        Computed<int>(listenable: d, compute: () => d.sizeOf(a), builder: (context, b) => Text(formatBytes(b ?? d.totalBytes(a)), style: TextStyle(fontSize: 13, color: k.secondary))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  TileButton(key: const ValueKey('featured-get'), action: TileAction.get, onPressed: () => getActivity(context, d, a)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openActivity(BuildContext context, Activity a) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ActivityPage(discover: d, activity: a)));

  List<Widget> _activityTiles(BuildContext context, {bool grid = false}) => [
    for (final a in d.catalogue.activities)
      Computed<int>(
        key: ValueKey('tile-activity-${a.id}'),
        listenable: d,
        compute: () => d.sizeOf(a),
        builder: (context, bytes) {
          final s = d.status(a);
          return StoreTile(
            width: grid ? null : 158,
            icon: discoverIcon(a.icon),
            title: a.title,
            line: a.tagline,
            size: formatBytes(bytes ?? d.totalBytes(a)),
            action: switch (s) {
              ActivityStatus.notAdded => TileAction.get,
              ActivityStatus.update => TileAction.update,
              ActivityStatus.adding => TileAction.adding,
              ActivityStatus.added => TileAction.added,
            },
            onAction: s == ActivityStatus.update ? () => updateActivity(context, d, a) : () => getActivity(context, d, a),
            onTap: () => _openActivity(context, a),
          );
        },
      ),
  ];

  TileAction _libraryAction(RecipeItem i, bool present) {
    if (d.device.hasUpdate(i)) return TileAction.update;
    if (present) return d.device.progressOf(i).active ? TileAction.adding : TileAction.added;
    return TileAction.get;
  }

  Widget _libraryTile(BuildContext context, RecipeItem i, {bool grid = false}) => Computed<bool>(
    key: ValueKey('tile-${i.key}'),
    listenable: d,
    compute: () => d.device.isPresent(i),
    builder: (context, present) => StoreTile(
      width: grid ? null : 158,
      icon: discoverIcon('book'),
      title: d.titleOf(i),
      line: i.subtitle,
      size: formatBytes(d.bytesOf(i)),
      action: _libraryAction(i, present ?? false),
      onAction: d.device.hasUpdate(i) ? () => d.device.update(i) : () => getItems(context, d, title: d.titleOf(i), icon: 'book', items: [i]),
    ),
  );

  List<Widget> _libraryTiles(BuildContext context, {bool grid = false}) => [for (final i in d.catalogue.libraries) _libraryTile(context, i, grid: grid)];

  /// Resources lists the libraries as rows.
  List<Widget> _libraryRows(BuildContext context) => [
    for (final i in d.catalogue.libraries)
      Computed<bool>(
        key: ValueKey('row-${i.key}'),
        listenable: d,
        compute: () => d.device.isPresent(i),
        builder: (context, present) => DRow(
          leading: DTile(discoverIcon('book')),
          title: d.titleOf(i),
          subtitle: [if (i.subtitle.isNotEmpty) i.subtitle, formatBytes(d.bytesOf(i))].join(' · '),
          trailing: TileButton(
            action: _libraryAction(i, present ?? false),
            onPressed: d.device.hasUpdate(i) ? () => d.device.update(i) : () => getItems(context, d, title: d.titleOf(i), icon: 'book', items: [i]),
          ),
        ),
      ),
  ];

  List<Widget> _mapTiles(BuildContext context, {bool grid = false}) => [
    for (final m in d.device.maps)
      StoreTile(
        key: ValueKey('tile-map-${m.id}'),
        width: grid ? null : 158,
        icon: discoverIcon('map'),
        title: m.title,
        line: m.subtitle,
        size: m.bytes == null ? 'Size not known yet' : formatBytes(m.bytes!),
        action: m.onDevice ? TileAction.added : TileAction.get,
        onAction: () => getMap(context, d, m),
      ),
  ];

  List<Widget> _collectionTiles(BuildContext context, {bool grid = false}) => [
    for (final c in d.catalogue.collections)
      Computed<int>(
        key: ValueKey('tile-collection-${c.id}'),
        listenable: d,
        compute: () async => (await d.missing(c.items)).length,
        builder: (context, missing) => StoreTile(
          width: grid ? null : 158,
          icon: discoverIcon(c.icon),
          title: c.title,
          line: c.tagline.isNotEmpty ? c.tagline : (c.items.length == 1 ? '1 library' : '${c.items.length} libraries'),
          size: formatBytes(c.items.fold(0, (s, i) => s + d.bytesOf(i))),
          action: missing == 0 ? TileAction.added : TileAction.get,
          onAction: () => getItems(context, d, title: c.title, icon: c.icon, items: c.items),
        ),
      ),
  ];

  Widget _ownSource(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Material(
        key: const ValueKey('discover-own-source'),
        color: k.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: k.accent, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: links.ownSource == null ? null : () => links.ownSource!(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                SizedBox(width: 40, child: Icon(Icons.add, color: k.accent)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add your own source', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text('Any web service that gives data', style: TextStyle(fontSize: 13, color: k.secondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: k.secondary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What a search found: activities, collections and libraries, then the whole catalogue of libraries.
  List<Widget> _results(BuildContext context) {
    final q = _query.text.trim();
    final r = d.search(q);
    final rows = <Widget>[
      if (!resources)
        for (final a in r.activities)
          DRow(leading: DTile(discoverIcon(a.icon)), title: a.title, subtitle: a.tagline, onTap: () => _openActivity(context, a)),
      for (final c in r.collections)
        DRow(
          leading: DTile(discoverIcon(c.icon)),
          title: c.title,
          subtitle: '${c.items.length} libraries',
          trailing: TileButton(action: TileAction.get, onPressed: () => getItems(context, d, title: c.title, icon: c.icon, items: c.items)),
        ),
      for (final i in r.libraries)
        DRow(
          leading: DTile(discoverIcon('book')),
          title: d.titleOf(i),
          subtitle: [if (i.subtitle.isNotEmpty) i.subtitle, formatBytes(d.bytesOf(i))].join(' · '),
          trailing: TileButton(action: TileAction.get, onPressed: () => getItems(context, d, title: d.titleOf(i), icon: 'book', items: [i])),
        ),
      if (links.searchLibraries != null)
        DRow(
          key: const ValueKey('discover-search-all'),
          leading: DTile(Icons.search),
          title: 'Search all libraries for "$q"',
          subtitle: 'The full catalogue',
          onTap: () => links.searchLibraries!(context, q),
        ),
    ];
    return [
      const SizedBox(height: 12),
      if (rows.isEmpty) const DHint('Nothing found.') else RowStack(rows: rows),
    ];
  }
}
