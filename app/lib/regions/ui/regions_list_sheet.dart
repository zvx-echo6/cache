import 'package:flutter/material.dart';

import '../../browse/browse_screen.dart' show LetterIcon;
import '../../maps/ui/format.dart';
import '../../screens/hold.dart';
import '../../screens/settings/widgets.dart' show RowButton;
import '../../theme.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_actions.dart';
import 'region_page.dart';

/// The Regions sheet: one list of the regions at a place on the map (smallest first), each with its kind and size at once (the sizes
/// come with the region catalogue; nothing is worked out on the phone), or how far it got when it is on the phone. Tapping a region
/// opens the one download pop-up for it (download, carry on, add off-road) or, when it is all here, its page. "Select" in the header
/// (press and hold a region is the shortcut) ticks several for one Download.
Future<void> showRegionsSheet(BuildContext context, RegionsState regions, {required double lat, required double lon}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => RegionsListSheet(regions: regions, lat: lat, lon: lon),
  );
}

class RegionsListSheet extends StatefulWidget {
  const RegionsListSheet({super.key, required this.regions, required this.lat, required this.lon});

  final RegionsState regions;
  final double lat;
  final double lon;

  @override
  State<RegionsListSheet> createState() => _RegionsListSheetState();
}

class _RegionsListSheetState extends State<RegionsListSheet> {
  List<RegionRecord>? _list;
  String? _error;
  bool _selecting = false;
  final Set<String> _picked = {};

  RegionsState get r => widget.regions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await r.catalogue.readShardAt(widget.lat, widget.lon);
      final list = r.catalogue.regionsAt(widget.lat, widget.lon);
      if (mounted) setState(() => _list = list);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't read the list of regions. It needs a connection the first time.");
    }
  }

  Future<void> _downloadPicked(List<RegionRecord> picked) async {
    await askDownloadRegions(context, r, picked);
    if (mounted) {
      setState(() {
        _selecting = false;
        _picked.clear();
      });
    }
  }

  void _toggleSelect([String? first]) => setState(() {
    _selecting = !_selecting || first != null;
    _picked.clear();
    if (first != null) _picked.add(first);
  });

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final list = _list;
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final picked = [for (final rec in list ?? const <RegionRecord>[]) if (_picked.contains(rec.id)) rec];
        final sizes = [for (final rec in picked) r.offer(rec).bytes];
        final total = sizes.every((b) => b != null) ? sizes.fold<int>(0, (s, b) => s + b!) : null;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selecting ? '${picked.length} selected' : 'Regions',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text),
                        ),
                      ),
                      if (list != null && list.isNotEmpty)
                        TextButton(
                          key: const ValueKey('regions-select'),
                          onPressed: () => setState(() {
                            _selecting = !_selecting;
                            _picked.clear();
                          }),
                          child: Text(_selecting ? 'Cancel' : 'Select'),
                        ),
                    ],
                  ),
                  Text('Each region has directions, map, places and off-road.', style: TextStyle(fontSize: 13, color: k.secondary)),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Text(_error!, style: TextStyle(fontSize: 14, color: k.warning))
                  else if (list == null)
                    const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                  else if (list.isEmpty)
                    Text('No region here in the catalogue. Search for one in Regions.', key: const ValueKey('regions-empty'), style: TextStyle(fontSize: 14, color: k.secondary))
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [for (final rec in list) _row(k, rec)],
                      ),
                    ),
                  if (!_selecting)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('regions-draw'),
                        // The map draws the rectangle, then the same download pop-up opens for it.
                        onPressed: () {
                          Navigator.pop(context);
                          r.maps.requestDraw();
                        },
                        child: const Text('Draw your own area instead'),
                      ),
                    ),
                  if (_selecting) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                        key: const ValueKey('regions-download-picked'),
                        onPressed: picked.isEmpty ? null : () => _downloadPicked(picked),
                        child: Text(picked.isEmpty ? 'Download' : 'Download ${picked.length} · ${sizeWords(total)}'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _row(CacheTokens k, RegionRecord rec) {
    final o = r.offer(rec);
    final l = r.regionOf(rec.id);
    final waiting = r.waitingIds.contains(rec.id);
    final pickable = o.kind == RegionOfferKind.download;
    final Widget trailing;
    if (_selecting) {
      trailing = Checkbox(
        value: _picked.contains(rec.id),
        onChanged: pickable ? (v) => setState(() => v == true ? _picked.add(rec.id) : _picked.remove(rec.id)) : null,
      );
    } else if (waiting) {
      trailing = RowBadge('Waiting for Wi-Fi', color: k.warning);
    } else {
      trailing = switch (o.kind) {
        RegionOfferKind.carryOn || RegionOfferKind.tryAgain => RowButton(
          key: ValueKey('region-fix-${rec.id}'),
          label: o.kind == RegionOfferKind.carryOn ? 'Carry on' : 'Try again',
          onPressed: () => openRegionOffer(context, r, rec),
        ),
        RegionOfferKind.busy => SizedBox(
          width: 44,
          height: 44,
          child: Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.5, value: l?.fraction)),
        ),
        RegionOfferKind.onPhone => Icon(Icons.check_circle, color: k.ok, semanticLabel: 'On this phone'),
        RegionOfferKind.download || RegionOfferKind.addParts => IconButton(
          key: ValueKey('region-download-${rec.id}'),
          tooltip: o.kind == RegionOfferKind.download ? 'Download ${rec.name}' : 'Add off-road to ${rec.name}',
          onPressed: () => openRegionOffer(context, r, rec),
          icon: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: k.accent, width: 1.5)),
            child: Icon(Icons.download, size: 18, color: k.accent),
          ),
        ),
      };
    }
    final line = l != null && (o.kind == RegionOfferKind.busy)
        ? '${regionKindLabel(rec.kind, country: rec.country)} · ${l.partsLine.isEmpty ? formatBytes(l.bytes) : l.partsLine}'
        : offerLine(rec, o, offroadFrom: r.offroadSharedWith(rec));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Holdable(
        key: ValueKey('region-${rec.id}'),
        holdLabel: l != null ? 'Region options' : 'Select',
        onTap: _selecting
            ? (pickable ? () => setState(() => _picked.contains(rec.id) ? _picked.remove(rec.id) : _picked.add(rec.id)) : null)
            : () => openRegionOffer(context, r, rec),
        onHold: _selecting
            ? null
            : l != null
            ? () => showRegionActions(context, r, l)
            : (pickable ? () => _toggleSelect(rec.id) : null),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                LetterIcon(title: rec.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rec.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: k.text)),
                      const SizedBox(height: 2),
                      Text(line, key: ValueKey('region-line-${rec.id}'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
