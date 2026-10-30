import 'package:flutter/material.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/ui/format.dart';
import '../../screens/settings/widgets.dart';
import '../../theme.dart';
import '../problem_words.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_actions.dart';

/// Opens the page of region [id] (each part with where it stands and its fix).
Future<void> openRegionPage(BuildContext context, RegionsState regions, String id) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RegionPage(regions: regions, id: id)));

/// The line under a region's name: "Ready · 1.8 GB" when all of it is here; otherwise only the parts that are not ready and where
/// each stands ("Places 40% · Off-road waiting"), in the warning colour when something stopped and the danger colour when it failed.
List<Part> regionStatusParts(RegionsState regions, LocalRegion l) => switch (l.phase) {
  RegionPhase.ready => [Part('${l.isArea ? 'Map ready' : 'Ready'} · ${formatBytes(l.bytes)}')],
  RegionPhase.downloading => [Part(l.partsLine)],
  RegionPhase.paused => [Part(regions.paused ?? 'Paused', Tone.warn), Part(' · ${l.partsLine}')],
  RegionPhase.stopped => [Part(l.partsLine, Tone.warn)],
  RegionPhase.failed => [Part(l.partsLine, Tone.danger)],
};

/// What the bar under a downloading region says: how far the whole region is and the part downloading now, "56% of 2.6 GB in all ·
/// now map" (the size in all when the catalogue knows it). The line above it says how far each part is.
String regionBarLabel(RegionsState regions, LocalRegion l) {
  final pct = '${(l.fraction * 100).clamp(0, 99).floor()}%';
  final total = regions.totalBytesOf(l);
  final part = l.downloadingPart;
  return [
    total == null ? '$pct in all' : '$pct of ${formatBytes(total)} in all',
    if (part != null) 'now ${part.name.toLowerCase()}' else if (l.phase == RegionPhase.paused) 'paused' else 'waiting to start',
  ].join(' · ');
}

/// A region on the phone as one row, the same wherever it is listed (Regions > Local, Settings > Maps): its name, the parts not ready
/// yet (on up to two lines), a labelled bar while it downloads, and, when it stopped or failed, its fix as a button on the row. Tap
/// opens its page; press and hold opens its menu.
class RegionRow extends StatelessWidget {
  const RegionRow({super.key, required this.regions, required this.region});

  final RegionsState regions;
  final LocalRegion region;

  @override
  Widget build(BuildContext context) {
    final l = region;
    final busy = l.phase == RegionPhase.downloading || l.phase == RegionPhase.paused;
    final fix = switch (l.phase) {
      RegionPhase.stopped => 'Carry on',
      RegionPhase.failed => 'Try again',
      _ => null,
    };
    return SettingsRow(
      key: ValueKey('local-${l.id}'),
      title: l.name,
      statusLines: 2,
      statusWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          statusText(context, regionStatusParts(regions, l), maxLines: 2),
          if (busy) ...[
            const SizedBox(height: 6),
            Semantics(
              label: regionBarLabel(regions, l),
              child: ExcludeSemantics(
                child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: l.fraction, minHeight: 5)),
              ),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(child: Text(regionBarLabel(regions, l), key: ValueKey('local-bar-${l.id}'), style: TextStyle(fontSize: 12, color: context.t.secondary))),
          ],
        ],
      ),
      trailing: fix == null
          ? null
          : RowButton(
              key: ValueKey('local-fix-${l.id}'),
              label: fix,
              onPressed: () => carryOnNow(ScaffoldMessenger.of(context), regions, l.id, name: l.name, again: l.phase == RegionPhase.failed),
            ),
      chevron: fix == null,
      onTap: () => openRegionPage(context, regions, l.id),
      onHold: () => showRegionActions(context, regions, l),
      holdLabel: 'Region options',
    );
  }
}

/// One region on the phone: each part (map, directions, places, off-road) with where it stands and its size, the fix next to anything
/// that stopped or failed, the map layers it holds, and Delete. Off-road can be added here when it has none.
class RegionPage extends StatelessWidget {
  const RegionPage({super.key, required this.regions, required this.id});

  final RegionsState regions;
  final String id;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: regions,
      builder: (context, _) {
        final l = regions.regionOf(id);
        if (l == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Region')),
            body: const Padding(padding: EdgeInsets.all(18), child: NoteText('This region is no longer on this phone.')),
          );
        }
        final k = context.t;
        final m = ScaffoldMessenger.of(context);
        void fix(bool again) => carryOnNow(m, regions, l.id, name: l.name, again: again);
        Widget? trailingFor(PartState s, double? fraction, String key) => switch (s) {
          PartState.ready => Icon(Icons.check_circle, color: k.ok, semanticLabel: 'Ready'),
          PartState.stopped => RowButton(key: ValueKey('fix-$key'), label: 'Carry on', onPressed: () => fix(false)),
          PartState.failed => RowButton(key: ValueKey('fix-$key'), label: 'Try again', onPressed: () => fix(true)),
          PartState.downloading => SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, value: fraction)),
          PartState.waiting || PartState.paused => null,
        };
        Tone toneOf(PartState s) => switch (s) {
          PartState.stopped || PartState.paused => Tone.warn,
          PartState.failed => Tone.danger,
          _ => Tone.normal,
        };
        String sizeOf(RegionPartStatus p) => switch (p.state) {
          PartState.ready => formatBytes(p.bytes),
          _ when p.totalBytes != null && p.totalBytes! > p.bytes => '${formatBytes(p.totalBytes! - p.bytes)} to go',
          _ when p.bytes > 0 => '${formatBytes(p.bytes)} so far',
          _ => '',
        };
        final layers = _layerGroups(l);
        final canAddOffroad = !l.hasOffroad && !l.isArea && regions.offroadCatalogue != null;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              Center(child: Padding(padding: const EdgeInsets.only(right: 4), child: Text(formatBytes(l.bytes), style: TextStyle(fontSize: 14, color: k.secondary)))),
              IconButton(
                key: const ValueKey('region-page-menu'),
                tooltip: 'Region options',
                icon: const Icon(Icons.more_vert),
                onPressed: () => showRegionActions(context, regions, l, open: false),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (l.phase == RegionPhase.paused && regions.paused != null) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: statusText(context, [Part(regions.paused!, Tone.warn)], maxLines: 3)),
                  const SizedBox(height: 10),
                ],
                SettingsGroup(
                  rows: [
                    for (final p in l.parts)
                      SettingsRow(
                        key: ValueKey('part-${p.kind.name}'),
                        title: p.name,
                        statusLines: 2,
                        status: joinParts([
                          [Part(partStateWords(p), toneOf(p.state))],
                          if (sizeOf(p).isNotEmpty) [Part(sizeOf(p))],
                        ]),
                        trailing: trailingFor(p.state, p.fraction, p.kind.name),
                      ),
                    if (canAddOffroad)
                      SettingsRow(
                        key: const ValueKey('part-offroad-add'),
                        title: 'Off-road',
                        status: const [Part('Not on this phone')],
                        trailing: RowButton(key: const ValueKey('add-offroad'), label: 'Add', onPressed: () => askAddOffroad(context, regions, l.id)),
                      ),
                  ],
                ),
                if (layers.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  SettingsGroup(
                    label: 'Map layers in this region',
                    rows: [
                      for (final g in layers)
                        SettingsRow(
                          key: ValueKey('layer-${g.key}'),
                          title: g.title,
                          statusLines: 2,
                          status: joinParts([
                            [Part(partStateWords(g.status), toneOf(g.status.state))],
                            if (g.status.bytes > 0) [Part(formatBytes(g.status.bytes))],
                          ]),
                          trailing: trailingFor(g.status.state, g.status.fraction, 'layer-${g.key}'),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const ValueKey('region-delete'),
                    style: OutlinedButton.styleFrom(foregroundColor: k.emergency, side: BorderSide(color: k.emergency)),
                    icon: const Icon(Icons.delete_outline),
                    label: Text('Delete ${l.name}'),
                    onPressed: () async {
                      if (await askDeleteRegion(context, regions, l) && context.mounted) Navigator.of(context).maybePop();
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The region's map areas by the layer their tiles are kept in, each with the names of the layers drawn from it ("Hillshade,
  /// contour lines" for the elevation layer) and where it stands.
  List<({String key, String title, RegionPartStatus status})> _layerGroups(LocalRegion l) {
    final engine = regions.maps.engine;
    final groups = <String, List<DownloadedArea>>{};
    for (final a in l.areas) {
      (groups[engine.downloadLayerOf(a.layerId)] ??= []).add(a);
    }
    final cards = regions.maps.catalogueLayers;
    return [
      for (final e in groups.entries)
        (
          key: e.key,
          title: _titles([
            for (final c in cards)
              if (engine.downloadLayerOf(regions.maps.downloadDefFor(c, e.value.first.bounds).id) == e.key) c.title,
          ], engine.layer(e.value.first.layerId)?.title ?? e.key),
          status: _status(e.value),
        ),
    ];
  }

  static String _titles(List<String> t, String fallback) {
    if (t.isEmpty) return fallback;
    return [t.first, for (final x in t.skip(1)) x.isEmpty ? x : x[0].toLowerCase() + x.substring(1)].join(', ');
  }

  static RegionPartStatus _status(List<DownloadedArea> l) {
    final done = l.fold(0, (s, a) => s + a.doneTiles), total = l.fold(0, (s, a) => s + a.totalTiles);
    final f = total == 0 ? null : (done / total).clamp(0.0, 1.0);
    final bytes = l.fold(0, (s, a) => s + a.bytes);
    final failed = l.where((a) => a.phase == AreaPhase.failed && !a.interrupted).firstOrNull;
    if (failed != null) return RegionPartStatus(RegionPartKind.map, PartState.failed, fraction: f, bytes: bytes, problem: areaProblemWords(failed.error));
    if (l.any((a) => a.phase == AreaPhase.failed)) return RegionPartStatus(RegionPartKind.map, PartState.stopped, fraction: f, bytes: bytes);
    if (l.any((a) => a.phase == AreaPhase.running)) return RegionPartStatus(RegionPartKind.map, PartState.downloading, fraction: f, bytes: bytes);
    return RegionPartStatus(RegionPartKind.map, PartState.ready, fraction: 1, bytes: bytes);
  }
}

/// A catalogue region's kind and its size or state for a list row: "County · 1.0 GB", "State · 0.4 GB to go", "State · On this
/// phone".
String offerLine(RegionRecord r, RegionOffer o, {List<String> offroadFrom = const []}) {
  final kind = regionKindLabel(r.kind, country: r.country);
  // The size counts off-road; when the state's off-road data comes with a region already on the phone, only this area's terrain is
  // counted, and the line says so.
  final shared = o.offroad && o.offroadShared ? (offroadFrom.isEmpty ? ' · off-road shared' : ' · off-road shared with ${offroadFrom.join(', ')}') : '';
  final what = switch (o.kind) {
    RegionOfferKind.download => '${sizeWords(o.bytes)}$shared',
    RegionOfferKind.carryOn => o.bytes == null ? 'Stopped' : '${formatBytes(o.bytes!)} to go',
    RegionOfferKind.tryAgain => "Couldn't finish",
    RegionOfferKind.addParts => 'On this phone · off-road not added',
    RegionOfferKind.busy => 'Downloading',
    RegionOfferKind.onPhone => 'On this phone · ${formatBytes(o.already)}',
  };
  return '$kind · $what';
}
