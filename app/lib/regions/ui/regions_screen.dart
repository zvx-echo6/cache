import 'package:flutter/material.dart';

import '../../maps/ui/format.dart';
import '../../screens/settings/widgets.dart';
import '../../settings/data_policy.dart';
import '../../theme.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_sheet.dart';

/// Regions and downloads, like OsmAnd's Maps & Resources: Downloads (the catalogue as a tree, with search), Local (what is on
/// this phone, largest first, with update and delete) and Updates (by part, with Update all).
class RegionsScreen extends StatefulWidget {
  const RegionsScreen({super.key, required this.regions, this.initialTab = 0});

  final RegionsState regions;
  final int initialTab;

  @override
  State<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends State<RegionsScreen> {
  @override
  void initState() {
    super.initState();
    widget.regions.init();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Regions'),
          bottom: const TabBar(tabs: [Tab(text: 'Downloads'), Tab(text: 'Local'), Tab(text: 'Updates')]),
        ),
        body: SafeArea(
          top: false,
          child: TabBarView(
            children: [
              DownloadsTab(regions: widget.regions),
              LocalTab(regions: widget.regions),
              UpdatesTab(regions: widget.regions),
            ],
          ),
        ),
      ),
    );
  }
}

/// The padding and spacing of a Settings page, for a tab's list.
Widget _list(List<Widget> children) => ListView(
  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
  children: [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(height: 14),
      children[i],
    ],
  ],
);

/// The small line under a region's name: what of it is on the phone, or nothing.
List<Part> localParts(RegionsState regions, LocalRegion? l) {
  if (l == null) return const [];
  return switch (l.phase) {
    RegionPhase.downloading => [Part('Downloading ${(l.fraction * 100).toStringAsFixed(0)}%')],
    RegionPhase.paused => [Part(regions.paused ?? 'Paused', Tone.warn)],
    RegionPhase.failed => [Part(l.error ?? 'Could not be downloaded', Tone.danger)],
    RegionPhase.ready => [const Part('On this phone', Tone.ok), Part(' · ${formatBytes(l.bytes)}')],
  };
}

/// The parts a region has on the phone, in order: "Road routing, map and places".
String partsWords(LocalRegion l) {
  final parts = [if (l.hasRouting) 'road routing', if (l.hasMap) 'map', if (l.hasPlaces) 'places', if (l.hasOffroad) 'off-road'];
  if (parts.isEmpty) return '';
  final words = parts.length == 1 ? parts.single : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  return words[0].toUpperCase() + words.substring(1);
}

// ---- Downloads -------------------------------------------------------------------------------------------

class DownloadsTab extends StatefulWidget {
  const DownloadsTab({super.key, required this.regions});

  final RegionsState regions;

  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> with AutomaticKeepAliveClientMixin {
  RegionsState get r => widget.regions;
  final _text = TextEditingController();
  late Future<RegionIndex> _index = r.catalogue.index();
  String _query = '';
  List<RegionHit>? _hits;
  String? _searchError;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() {
      _query = q.trim();
      _searchError = null;
      if (_query.isEmpty) _hits = null;
    });
    if (_query.isEmpty) return;
    final asked = _query;
    try {
      final rows = <RegionHit>[...await r.catalogue.globalSearch()];
      for (final s in r.catalogue.loadedShards.toList()) {
        rows.addAll(await r.catalogue.shardSearch(s.id));
      }
      if (!mounted || asked != _query) return;
      setState(() => _hits = searchRegions(asked, rows));
    } catch (_) {
      if (mounted && asked == _query) setState(() => _searchError = 'Search needs a connection the first time.');
    }
  }

  Future<void> _openHit(RegionHit h) async {
    try {
      final rec = await r.catalogue.record(h.id, shardId: h.shardId);
      if (rec == null) throw StateError('missing');
      if (mounted) await showRegionSheet(context, r, rec);
    } catch (_) {
      if (mounted) say(context, 'This region could not be read. Connect and try again.');
    }
  }

  Future<void> _openCountry(RegionCountry c) async {
    // Coming back here must not give the search field the focus (and the keyboard) again.
    FocusManager.instance.primaryFocus?.unfocus();
    if (c.count <= 1) {
      await showRegionSheet(context, r, c.record);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionNodePage(regions: r, shardId: c.shard, nodeId: c.record.id, title: c.record.name)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final k = context.t;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: TextField(
            key: const ValueKey('region-search'),
            controller: _text,
            onChanged: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search regions',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _text.clear();
                        _search('');
                      },
                    ),
              filled: true,
              fillColor: k.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(child: _query.isEmpty ? _countries() : _results()),
      ],
    );
  }

  Widget _results() {
    if (_searchError != null) return _list([NoteText(_searchError!)]);
    final hits = _hits;
    if (hits == null) return const Center(child: CircularProgressIndicator());
    if (hits.isEmpty) return _list([NoteText('No region called "$_query".')]);
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) => _list([
        SettingsGroup(
          rows: [
            for (final h in hits)
              SettingsRow(
                key: ValueKey('hit-${h.id}'),
                title: h.name,
                status: joinParts([
                  [Part(regionKindLabel(h.kind, country: h.shardId.toUpperCase()))],
                  if (h.inside.isNotEmpty) [Part(h.inside)],
                  localParts(r, r.regionOf(h.id)),
                ]),
                onTap: () => _openHit(h),
              ),
          ],
        ),
      ]),
    );
  }

  Widget _countries() {
    return FutureBuilder<RegionIndex>(
      future: _index,
      builder: (context, snap) {
        if (snap.hasError) {
          return _list([
            const NoteText('The list of regions needs a connection the first time. After that it works offline.'),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: () => setState(() => _index = r.catalogue.index()), child: const Text('Try again')),
            ),
          ]);
        }
        final ix = snap.data;
        if (ix == null) return const Center(child: CircularProgressIndicator());
        return ListenableBuilder(
          listenable: r,
          builder: (context, _) => _list([
            SettingsGroup(
              label: 'Countries',
              rows: [
                for (final c in ix.countries)
                  SettingsRow(
                    key: ValueKey('country-${c.record.id}'),
                    title: c.record.name,
                    status: localParts(r, r.regionOf(c.record.id)),
                    onTap: () => _openCountry(c),
                  ),
              ],
            ),
          ]),
        );
      },
    );
  }
}

/// One place in the tree: the region itself (to download it) and what is inside it, grouped by kind. A region inside several
/// others (Idaho is in the Pacific Northwest and in the Intermountain West) is under each of them.
class RegionNodePage extends StatefulWidget {
  const RegionNodePage({super.key, required this.regions, required this.shardId, required this.nodeId, required this.title, this.node});

  final RegionsState regions;
  final String shardId;
  final String nodeId;
  final String title;

  /// The node when the parent page already has it.
  final RegionNode? node;

  @override
  State<RegionNodePage> createState() => _RegionNodePageState();
}

RegionNode? _find(List<RegionNode> nodes, String id) {
  for (final n in nodes) {
    if (n.id == id) return n;
    final f = _find(n.children, id);
    if (f != null) return f;
  }
  return null;
}

class _RegionNodePageState extends State<RegionNodePage> {
  late Future<RegionShard> _shard = widget.regions.catalogue.shard(widget.shardId);

  RegionsState get r => widget.regions;

  Future<void> _open(RegionShard s, RegionNode n) async {
    if (n.children.isNotEmpty) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RegionNodePage(regions: r, shardId: widget.shardId, nodeId: n.id, title: n.name, node: n),
      ));
      return;
    }
    final rec = s[n.id];
    if (rec != null) await showRegionSheet(context, r, rec);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        top: false,
        child: FutureBuilder<RegionShard>(
          future: _shard,
          builder: (context, snap) {
            if (snap.hasError) {
              return _list([
                const NoteText('This country\'s regions need a connection the first time.'),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: () => setState(() => _shard = r.catalogue.shard(widget.shardId)),
                    child: const Text('Try again'),
                  ),
                ),
              ]);
            }
            final s = snap.data;
            if (s == null) return const Center(child: CircularProgressIndicator());
            final node = widget.node ?? _find(s.tree, widget.nodeId);
            final self = s[widget.nodeId];
            final groups = <String, List<RegionNode>>{};
            for (final c in node?.children ?? const <RegionNode>[]) {
              (groups[c.kind] ??= []).add(c);
            }
            return ListenableBuilder(
              listenable: r,
              builder: (context, _) => _list([
                if (self != null)
                  SettingsGroup(
                    rows: [
                      SettingsRow(
                        key: ValueKey('self-${self.id}'),
                        icon: Icons.download_outlined,
                        title: 'Download ${self.name}',
                        status: joinParts([
                          [Part(regionKindLabel(self.kind, country: self.country))],
                          localParts(r, r.regionOf(self.id)),
                        ]),
                        onTap: () => showRegionSheet(context, r, self),
                      ),
                    ],
                  ),
                for (final g in groups.entries)
                  SettingsGroup(
                    label: regionKindHeading(g.key, country: self?.country ?? s.id.toUpperCase()),
                    rows: [
                      for (final n in g.value)
                        SettingsRow(
                          key: ValueKey('node-${n.id}'),
                          title: n.name,
                          status: localParts(r, r.regionOf(n.id)),
                          chevron: true,
                          onTap: () => _open(s, n),
                        ),
                    ],
                  ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// ---- Local -----------------------------------------------------------------------------------------------

class LocalTab extends StatelessWidget {
  const LocalTab({super.key, required this.regions});

  final RegionsState regions;

  Future<void> _delete(BuildContext context, LocalRegion l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${l.name}?'),
        content: const Text('Its road routing, map, places and off-road data are removed from this phone. Parts another region uses stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await regions.remove(l.id);
    } catch (e) {
      if (context.mounted) say(context, '$e');
    }
  }

  Future<void> _update(BuildContext context, LocalRegion l, {bool anyway = false}) async {
    try {
      await regions.updateRegion(l.id, anyway: anyway);
    } on MobileDataBlocked catch (e) {
      if (context.mounted) {
        say(context, e.message, action: SnackBarAction(label: 'Download anyway', onPressed: () => _update(context, l, anyway: true)));
      }
    } catch (e) {
      if (context.mounted) say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: regions,
      builder: (context, _) {
        final k = context.t;
        final local = regions.local;
        return _list([
          if (regions.paused != null && local.any((l) => l.phase != RegionPhase.ready))
            Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: statusText(context, [Part(regions.paused!, Tone.warn)])),
          SettingsGroup(
            rows: [
              if (local.isEmpty) const SettingsRow(title: 'Nothing downloaded yet', status: [Part('Pick a region under Downloads')]),
              for (final l in local)
                SettingsRow(
                  key: ValueKey('local-${l.id}'),
                  title: l.name,
                  statusWidget: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      statusText(context, switch (l.phase) {
                        RegionPhase.ready => [
                          Part('${formatBytes(l.bytes)} · ${partsWords(l)}'),
                          if (regions.missesPlaces(l)) ...const [Part(' · '), Part('Places not downloaded', Tone.warn)],
                        ],
                        _ => localParts(regions, l),
                      }),
                      if (l.phase == RegionPhase.downloading || l.phase == RegionPhase.paused) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: l.fraction),
                      ],
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Update ${l.name}',
                        icon: Icon(Icons.refresh, color: k.secondary),
                        onPressed: l.phase == RegionPhase.ready ? () => _update(context, l) : null,
                      ),
                      IconButton(
                        tooltip: 'Delete ${l.name}',
                        icon: Icon(Icons.delete_outline, color: k.secondary),
                        onPressed: () => _delete(context, l),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (local.length > 1) const NoteText('Largest first. A part two regions share is kept once.'),
        ]);
      },
    );
  }
}

// ---- Updates ---------------------------------------------------------------------------------------------

class UpdatesTab extends StatefulWidget {
  const UpdatesTab({super.key, required this.regions});

  final RegionsState regions;

  @override
  State<UpdatesTab> createState() => _UpdatesTabState();
}

class _UpdatesTabState extends State<UpdatesTab> {
  RegionsState get r => widget.regions;
  bool _busy = false;

  Future<void> _run(Future<void> Function() f, {Future<void> Function()? anyway}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } on MobileDataBlocked catch (e) {
      if (mounted) {
        say(context, e.message, action: anyway == null ? null : SnackBarAction(label: 'Download anyway', onPressed: () => _run(anyway)));
      }
    } catch (e) {
      if (mounted) say(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final k = context.t;
        final up = r.routingUpdate;
        final placesUp = r.placesUpdate;
        final maps = r.withMap;
        final any = up != null || (placesUp != null && placesUp['downloading'] != true) || maps.isNotEmpty;
        return _list([
          SettingsGroup(
            label: 'Road routing',
            rows: [
              if (r.routingUnavailable != null)
                SettingsRow(title: 'Road routing', status: [Part(r.routingUnavailable!, Tone.warn)])
              else if (up != null)
                SettingsRow(
                  key: const ValueKey('routing-update'),
                  title: 'New road routing',
                  status: [Part('${up['build']} · About ${formatBytes((up['download_bytes'] as num?)?.toInt() ?? 0)} to download')],
                )
              else
                const SettingsRow(title: 'Road routing', status: [Part('Up to date', Tone.ok)]),
            ],
          ),
          if (r.placesAvailable)
            SettingsGroup(
              label: 'Places',
              rows: [
                if (placesUp == null)
                  const SettingsRow(title: 'Places', status: [Part('Up to date', Tone.ok)])
                else
                  SettingsRow(
                    key: const ValueKey('places-update'),
                    title: 'New places',
                    status: [
                      Part(placesUp['downloading'] == true
                          ? 'Downloading ${placesUp['build']}'
                          : '${placesUp['build']} · About ${formatBytes((placesUp['download_bytes'] as num?)?.toInt() ?? 0)} to download'),
                    ],
                  ),
              ],
            ),
          SettingsGroup(
            label: 'Map',
            rows: [
              if (maps.isEmpty) const SettingsRow(title: 'No region maps downloaded'),
              for (final l in maps)
                SettingsRow(
                  key: ValueKey('map-${l.id}'),
                  title: l.name,
                  status: [
                    Part(l.fetchedAt == null ? 'Downloading' : 'Downloaded ${formatDate(l.fetchedAt!)} · ${formatBytes(l.mapBytes)}'),
                  ],
                  trailing: IconButton(
                    tooltip: 'Update ${l.name}',
                    icon: Icon(Icons.refresh, color: k.secondary),
                    onPressed: _busy || l.phase != RegionPhase.ready
                        ? null
                        : () => _run(() => r.updateRegion(l.id), anyway: () => r.updateRegion(l.id, anyway: true)),
                  ),
                ),
            ],
          ),
          // Stacked: side by side they do not fit a phone's width.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const ValueKey('update-all'),
                onPressed: _busy || !any ? null : () => _run(r.updateAll, anyway: () => r.updateAll(anyway: true)),
                child: const Text('Update all'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('Check for updates'),
                onPressed: _busy || !r.routingAvailable ? null : () => _run(r.checkUpdates),
              ),
            ],
          ),
        ]);
      },
    );
  }
}
