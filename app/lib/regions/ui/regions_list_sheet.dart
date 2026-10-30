import 'package:flutter/material.dart';

import '../../browse/browse_screen.dart' show LetterIcon;
import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart';
import '../../screens/hold.dart';
import '../../theme.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';
import 'region_sheet.dart';

/// The Regions sheet: one list of the regions at a place on the map (smallest first), each with its size and a download button, or
/// "On this phone". "Select" in the header (press and hold a region is the shortcut) shows tick boxes and one "Download N" button.
/// Every download goes through the download pop-up. Tapping a region opens its own sheet with its parts.
Future<void> showRegionsSheet(BuildContext context, RegionsState regions, {required double lat, required double lon}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => RegionsListSheet(regions: regions, lat: lat, lon: lon),
  );
}

/// What downloading a region adds: the parts not on the phone yet that can be downloaded here, and their size.
typedef RegionParts = ({int bytes, bool routing, bool map, bool places, bool offroad});

/// The parts of [r] still to download, from its [plan].
RegionParts regionParts(RegionsState regions, RegionRecord r, RegionPlan plan) {
  final here = regions.regionOf(r.id);
  final routing = !(here?.hasRouting ?? false) && plan.routing != null;
  final map = !(here?.hasMap ?? false) && plan.mapAllowed.isNotEmpty;
  final places = !(here?.hasPlaces ?? false) && plan.places != null;
  final offroad = !(here?.hasOffroad ?? false) && plan.offroadAllowed;
  return (
    bytes: (routing ? plan.routing!.downloadBytes : 0) +
        (map ? plan.mapBytes : 0) +
        (places ? plan.places!.downloadBytes : 0) +
        (offroad ? plan.offroad!.downloadBytes : 0),
    routing: routing,
    map: map,
    places: places,
    offroad: offroad,
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
  final Map<String, RegionPlan?> _plans = {};
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
      if (!mounted) return;
      setState(() => _list = list);
      for (final rec in list) {
        r.plan(rec).then((p) {
          if (mounted) setState(() => _plans[rec.id] = p);
        }).catchError((Object _) {
          if (mounted) setState(() => _plans[rec.id] = null);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't read the list of regions. It needs a connection the first time.");
    }
  }

  RegionParts? _parts(RegionRecord rec) {
    final p = _plans[rec.id];
    return p == null ? null : regionParts(r, rec, p);
  }

  bool _onPhone(RegionRecord rec) {
    final l = r.regionOf(rec.id);
    final parts = _parts(rec);
    return l != null && l.phase == RegionPhase.ready && (parts == null || parts.bytes == 0);
  }

  /// The download pop-up for [list], then each region's parts start (now, or once on Wi-Fi).
  Future<void> _download(List<RegionRecord> list) async {
    final todo = [
      for (final rec in list)
        if (_parts(rec) case final p? when p.bytes > 0) (rec, p),
    ];
    if (todo.isEmpty) return;
    final dir = await r.supportDir();
    if (!mounted) return;
    final choice = await askToDownload(
      context,
      title: todo.length == 1 ? 'Download ${todo.single.$1.name}?' : 'Download ${todo.length} regions?',
      lines: [for (final t in todo) DownloadLine(t.$1.name, t.$2.bytes)],
      dir: dir.path,
      policy: r.policy,
    );
    if (choice == DownloadChoice.cancel) return;
    for (final (rec, p) in todo) {
      if (choice == DownloadChoice.now) {
        await r.download(rec, routing: p.routing, map: p.map, places: p.places, offroad: p.offroad, anyway: true);
      } else {
        await r.downloadOnWifi(rec, routing: p.routing, map: p.map, places: p.places, offroad: p.offroad);
      }
    }
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
        final total = picked.fold<int>(0, (s, rec) => s + (_parts(rec)?.bytes ?? 0));
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
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
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text),
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
                  Text('Each region has routing, map, places and off-road.', style: TextStyle(fontSize: 12, color: k.secondary)),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Text(_error!, style: TextStyle(fontSize: 13, color: k.warning))
                  else if (list == null)
                    const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                  else if (list.isEmpty)
                    Text('No region here in the catalogue. Search for one in Regions.', key: const ValueKey('regions-empty'), style: TextStyle(fontSize: 13, color: k.secondary))
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
                        // The map draws the rectangle, then the same region sheet and download pop-up open for it.
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
                        onPressed: picked.isEmpty ? null : () => _download(picked),
                        child: Text(picked.isEmpty ? 'Download' : 'Download ${picked.length} · ${formatBytes(total)}'),
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
    final parts = _parts(rec);
    final planned = _plans.containsKey(rec.id);
    final l = r.regionOf(rec.id);
    final onPhone = _onPhone(rec);
    final waiting = r.waitingIds.contains(rec.id);
    final downloading = l != null && (l.phase == RegionPhase.downloading || l.phase == RegionPhase.paused);
    final available = parts != null && parts.bytes > 0;
    final detail = !planned
        ? 'Working out the size…'
        : onPhone
        ? formatBytes(l!.bytes)
        : parts == null || !available
        ? "Can't be downloaded here"
        : formatBytes(parts.bytes);
    final Widget trailing;
    if (_selecting) {
      trailing = Checkbox(
        value: _picked.contains(rec.id),
        onChanged: available && !onPhone ? (v) => setState(() => v == true ? _picked.add(rec.id) : _picked.remove(rec.id)) : null,
      );
    } else if (onPhone) {
      trailing = RowBadge('On this phone', color: k.ok);
    } else if (downloading) {
      trailing = SizedBox(width: 44, height: 44, child: Padding(padding: const EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2.5, value: l.fraction)));
    } else if (waiting) {
      trailing = RowBadge('Waiting for Wi-Fi', color: k.warning);
    } else {
      trailing = IconButton(
        key: ValueKey('region-download-${rec.id}'),
        tooltip: 'Download ${rec.name}',
        onPressed: available ? () => _download([rec]) : null,
        icon: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: available ? k.accent : k.secondary, width: 1.5)),
          child: Icon(Icons.download, size: 17, color: available ? k.accent : k.secondary),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Holdable(
        key: ValueKey('region-${rec.id}'),
        holdLabel: 'Select',
        onTap: _selecting
            ? (available && !onPhone ? () => setState(() => _picked.contains(rec.id) ? _picked.remove(rec.id) : _picked.add(rec.id)) : null)
            : () => showRegionSheet(context, r, rec),
        onHold: _selecting || !available || onPhone ? null : () => _toggleSelect(rec.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                LetterIcon(title: rec.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rec.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                      Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
