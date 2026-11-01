import 'package:flutter/material.dart';

import '../../layout/adaptive.dart';

import '../../maps/layers/layer_def.dart';
import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart' show openStorageForSpace;
import '../../screens/settings/widgets.dart';
import '../../theme.dart';
import '../problem_words.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_actions.dart';
import 'region_download.dart';
import '../../downloads/download_row.dart';

/// Opens the page of region [id] (each part with where it stands and its fix).
/// Beside the list on a tablet (Regions' two panes), else as a page of its own.
Future<void> openRegionPage(BuildContext context, RegionsState regions, String id) =>
    openDetail(context, key: 'region-$id', builder: (_) => RegionPage(regions: regions, id: id));

/// The line under a region's name: "Ready · 1.8 GB" when all of it is here; otherwise only the parts that are not ready and where
/// each stands ("Places 40% · Off-road waiting"), in the warning colour when something stopped and the danger colour when it failed.
List<Part> regionStatusParts(RegionsState regions, LocalRegion l) => switch (l.phase) {
  // Places not published for the area count as done; the row still says so, in the neutral colour with an info mark (a search that
  // finds no places is then understood). On a narrow row the size goes before the note does.
  RegionPhase.ready => [
    Part('${l.isArea ? 'Map ready' : 'Ready'} · ${formatBytes(l.bytes)}'),
    if (l.placesNotAvailable) ...[const Part(' · '), const Part(kPlacesNotAvailableShort, Tone.quiet, Icons.info_outline)],
  ],
  RegionPhase.downloading => [Part(l.partsLine)],
  RegionPhase.paused => [Part(regions.paused ?? 'Paused', Tone.warn), Part(' · ${l.partsLine}')],
  RegionPhase.stopped => [Part(l.partsLine, Tone.warn)],
  RegionPhase.failed => [Part(l.partsLine, Tone.danger)],
};

/// "Places not available yet": a region's places not published for its area, on its row.
const String kPlacesNotAvailableShort = 'Places not available yet';

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

/// A region on the phone as one row, the same wherever it is listed (Regions > Local, Settings > Maps), in the download pattern:
/// its name, one line (the whole region's progress, speed and time left while it downloads), one bar, and Pause, Resume or Free
/// space. Tap opens its page in every state; press and hold opens Pause, Resume and Remove while it downloads, else its menu.
class RegionRow extends StatelessWidget {
  const RegionRow({super.key, required this.regions, required this.region});

  final RegionsState regions;
  final LocalRegion region;

  @override
  Widget build(BuildContext context) {
    final l = region;
    final s = regionDl(regions, l);
    return DownloadRow(
      key: ValueKey('local-${l.id}'),
      keyBase: 'local-${l.id}',
      title: l.name,
      state: s,
      actions: regionDlActions(context, regions, l),
      selected: isPaneSelected(context, 'region-${l.id}'),
      doneLine: regionDoneLine(l, placesNote: kPlacesNotAvailableShort),
      doneAction: Icon(Icons.chevron_right, color: context.t.secondary),
      onOpen: () => openRegionPage(context, regions, l.id),
      onDoneHold: () => showRegionActions(context, regions, l),
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
            appBar: AppBar(leading: paneShowButton(context), title: const Text('Region')),
            body: const Padding(padding: EdgeInsets.all(18), child: NoteText('This region is no longer on this device.')),
          );
        }
        final k = context.t;
        final m = ScaffoldMessenger.of(context);
        void fix(bool again) => carryOnNow(m, regions, l.id, name: l.name, again: again);
        Widget? trailingFor(RegionPartStatus p, String key) => switch (p.state) {
          PartState.ready => Icon(Icons.check_circle, color: k.ok, semanticLabel: 'Ready'),
          PartState.stopped => RowButton(key: ValueKey('fix-$key'), label: 'Carry on', onPressed: () => fix(false)),
          // A full phone is fixed by freeing space, not by trying again.
          PartState.failed when p.noSpace && openStorageForSpace != null =>
            RowButton(key: ValueKey('fix-$key'), label: 'Free space', onPressed: () => openStorageForSpace!(context)),
          PartState.failed => RowButton(key: ValueKey('fix-$key'), label: 'Try again', onPressed: () => fix(true)),
          PartState.downloading => SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, value: p.fraction)),
          PartState.waiting || PartState.paused || PartState.notAvailable => null,
        };
        Tone toneOf(PartState s) => switch (s) {
          PartState.stopped || PartState.paused => Tone.warn,
          PartState.failed => Tone.danger,
          _ => Tone.normal,
        };
        final layers = _layerGroups(l);
        final canAddOffroad = !l.hasOffroad && !l.isArea && regions.offroadCatalogue != null;
        final canAddPlaces = regions.placesNowAvailable(l);
        return Scaffold(
          appBar: AppBar(leading: paneShowButton(context), 
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
                if (l.phase != RegionPhase.ready) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    child: Text(regionSummary(l), key: const ValueKey('region-summary'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: k.text)),
                  ),
                ],
                SettingsGroup(
                  rows: [
                    for (final p in l.parts)
                      if (p.state == PartState.notAvailable)
                        _NotAvailableRow(key: ValueKey('part-${p.kind.name}'), part: p.name, region: l.name)
                      else if (p.complete)
                        SettingsRow(
                          key: ValueKey('part-${p.kind.name}'),
                          title: p.name,
                          status: [Part('Ready · ${formatBytes(p.bytes)}')],
                          trailing: trailingFor(p, p.kind.name),
                        )
                      else
                        _PartRow(key: ValueKey('part-${p.kind.name}'), regions: regions, region: l, part: p),
                    // Published since this region was downloaded: offered here.
                    if (canAddPlaces)
                      SettingsRow(
                        key: const ValueKey('part-places-add'),
                        title: 'Places',
                        status: const [Part('Now available')],
                        trailing: RowButton(key: const ValueKey('add-places'), label: 'Add', onPressed: () => askAddPlaces(context, regions, l.id)),
                      ),
                    if (canAddOffroad)
                      SettingsRow(
                        key: const ValueKey('part-offroad-add'),
                        title: 'Off-road',
                        status: const [Part('Not on this device')],
                        trailing: RowButton(key: const ValueKey('add-offroad'), label: 'Add', onPressed: () => askAddOffroad(context, regions, l.id)),
                      ),
                  ],
                ),
                // Try again has not worked twice: the last fix, one pop-up.
                if (l.phase == RegionPhase.failed && regions.triesOf(l.id) >= 2) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('region-start-again'),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Delete and start again'),
                      onPressed: () => askStartAgain(context, regions, l),
                    ),
                  ),
                ],
                if (layers.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  SettingsGroup(
                    label: 'Map layers in this region',
                    rows: [
                      for (final g in layers)
                        if (!g.status.complete)
                          _PartRow(key: ValueKey('layer-${g.key}'), regions: regions, region: l, part: g.status, title: g.title, own: true)
                        else
                        SettingsRow(
                          key: ValueKey('layer-${g.key}'),
                          title: g.title,
                          statusLines: 2,
                          status: joinParts([
                            [Part(partStateWords(g.status), toneOf(g.status.state))],
                            if (g.status.bytes > 0) [Part(formatBytes(g.status.bytes))],
                          ]),
                          trailing: trailingFor(g.status, 'layer-${g.key}'),
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

/// A part not published for the region's area yet: "Not available yet for this area" with an info mark and no button (a tick would
/// claim it is there). A tap opens a short note under it saying why and when Cache checks again; the one place the reason is given.
class _NotAvailableRow extends StatefulWidget {
  const _NotAvailableRow({super.key, required this.part, required this.region});

  final String part;
  final String region;

  @override
  State<_NotAvailableRow> createState() => _NotAvailableRowState();
}

class _NotAvailableRowState extends State<_NotAvailableRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return SettingsRow(
      title: widget.part,
      statusWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          statusText(context, const [Part('Not available yet for this area')]),
          if (_open) ...[
            const SizedBox(height: 6),
            Text(
              '${widget.part} are not published for ${widget.region} yet. Cache will check again when you check for updates.',
              key: const ValueKey('part-note'),
              style: TextStyle(fontSize: 13, height: 1.4, color: k.text),
            ),
          ],
        ],
      ),
      trailing: Icon(_open ? Icons.info : Icons.info_outline, color: k.secondary, semanticLabel: _open ? 'Hide why' : 'Why'),
      chevron: false,
      onTap: () => setState(() => _open = !_open),
    );
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
    RegionOfferKind.addParts => 'On this device · off-road not added',
    RegionOfferKind.busy => 'Downloading',
    RegionOfferKind.onPhone => 'On this device · ${formatBytes(o.already)}',
  };
  return '$kind · $what';
}

/// A part of a region that is not complete, in the download pattern: the running part's line, bar and Pause; a waiting part
/// "Waiting for Map to finish"; a paused or failed part its Resume (or Free space) and Remove.
class _PartRow extends StatelessWidget {
  const _PartRow({super.key, required this.regions, required this.region, required this.part, this.title, this.own = false});

  final RegionsState regions;
  final LocalRegion region;
  final RegionPartStatus part;

  /// The row's title when it is not the part's name (a map layer: "Hillshade, Contours").
  final String? title;

  /// A map layer of the region: it pauses and resumes as itself, not in the parts' order.
  final bool own;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = partDl(regions, region, part, own: own);
    final a = regionDlActions(context, regions, region);
    final key = 'part-${part.kind.name}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title ?? part.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                DlStatus(state: s, actions: a, keyBase: key),
              ],
            ),
          ),
          // Only the running part pauses, and only the part that stopped resumes: the region is one download, not two ways.
          dlControl(context, s, s.phase == DlPhase.waiting ? const DlActions() : a, keyBase: key),
        ],
      ),
    );
  }
}
