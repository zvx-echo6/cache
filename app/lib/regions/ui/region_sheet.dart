import 'package:flutter/material.dart';

import '../../maps/ui/format.dart';
import '../../screens/download_confirm.dart';
import '../../theme.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';

/// What downloading a region costs, part by part, shown before anything is downloaded. The parts are ticked by default; a part
/// already on the phone, or one that cannot be downloaded here, is not. A region downloaded before places were part of regions
/// shows places unticked, to add on their own. Sizes count only what is not on the phone yet; the size in all (what Local will
/// show for the region) is given beside it when some of it is already here.
Future<void> showRegionSheet(BuildContext context, RegionsState regions, RegionRecord region) {
  // The search field the sheet was opened from would get the focus back when the sheet closes, and the keyboard with it.
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => RegionSheet(regions: regions, region: region),
  );
}

class RegionSheet extends StatefulWidget {
  const RegionSheet({super.key, required this.regions, required this.region});

  final RegionsState regions;
  final RegionRecord region;

  @override
  State<RegionSheet> createState() => _RegionSheetState();
}

class _RegionSheetState extends State<RegionSheet> {
  RegionPlan? _plan;
  bool _routing = true;
  bool _map = true;
  bool _places = true;
  bool _starting = false;
  String? _error;

  RegionsState get r => widget.regions;

  @override
  void initState() {
    super.initState();
    _places = !(_routingHere || _mapHere);
    r.plan(widget.region).then((p) {
      if (mounted) setState(() => _plan = p);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not work out the size');
    });
  }

  LocalRegion? get _here => r.regionOf(widget.region.id);
  bool get _routingHere => _here?.hasRouting ?? false;
  bool get _mapHere => _here?.hasMap ?? false;
  bool get _placesHere => _here?.hasPlaces ?? false;
  bool get _canRouting => !_routingHere && _plan?.routing != null;
  bool get _canMap => !_mapHere && (_plan?.mapAllowed.isNotEmpty ?? false);
  bool get _canPlaces => !_placesHere && _plan?.places != null;
  bool get _canAny => _canRouting || _canMap || _canPlaces;
  bool get _picked => (_routing && _canRouting) || (_map && _canMap) || (_places && _canPlaces);

  int get _total {
    final p = _plan;
    if (p == null) return 0;
    return (_routing && _canRouting ? p.routing!.downloadBytes : 0) +
        (_map && _canMap ? p.mapBytes : 0) +
        (_places && _canPlaces ? p.places!.downloadBytes : 0);
  }

  /// What the picked parts already have on this phone (tiles shared with a region that is here). Local counts them in a
  /// region's size, so the sheet shows the same total beside what is new.
  int get _already {
    final p = _plan;
    if (p == null) return 0;
    int part(PartPlan pp) => pp.bytes > pp.downloadBytes ? pp.bytes - pp.downloadBytes : 0;
    return (_routing && _canRouting ? part(p.routing!) : 0) +
        (_map && _canMap ? p.mapBytesAlready : 0) +
        (_places && _canPlaces ? part(p.places!) : 0);
  }

  /// The download pop-up, then the parts picked start: now, or once on Wi-Fi.
  Future<void> _start() async {
    final dir = await r.supportDir();
    if (!mounted) return;
    final choice = await askToDownload(
      context,
      title: 'Download ${widget.region.name}?',
      lines: [DownloadLine(widget.region.name, _total)],
      dir: dir.path,
      policy: r.policy,
    );
    if (choice == DownloadChoice.cancel || !mounted) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final routing = _routing && _canRouting, map = _map && _canMap, places = _places && _canPlaces;
      if (choice == DownloadChoice.now) {
        await r.download(widget.region, routing: routing, map: map, places: places, anyway: true);
      } else {
        await r.downloadOnWifi(widget.region, routing: routing, map: map, places: places);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  String _partLine(bool here, PartPlan? pp, String? problem) {
    if (here) return 'On this phone';
    if (pp == null) return problem ?? 'Not available';
    final already = pp.bytes - pp.downloadBytes;
    return [
      'About ${formatBytes(pp.downloadBytes)}',
      if (already > 0) '${formatBytes(already)} already on this phone',
    ].join(' · ');
  }

  String _mapLine(RegionPlan p) {
    if (_mapHere) return 'On this phone';
    final ok = p.mapAllowed;
    if (ok.isEmpty) return p.mapProblem ?? 'Not available';
    final zoom = ok.map((m) => m.estimate.maxZoom).reduce((a, b) => a < b ? a : b);
    return [
      'About ${formatBytes(p.mapBytes)}',
      ok.map((m) => m.def.title).join(', '),
      'detail down to zoom $zoom',
      if (p.mapBytesAlready > 0) '${formatBytes(p.mapBytesAlready)} already on this phone',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final p = _plan;
    final region = widget.region;
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Download ${region.name}', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(regionKindLabel(region.kind, country: region.country), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              if (p == null && _error == null)
                const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
              else if (p != null) ...[
                CheckboxListTile(
                  key: const ValueKey('part-routing'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Road routing'),
                  subtitle: Text(_partLine(_routingHere, p.routing, p.routingProblem)),
                  value: _routingHere || (_routing && _canRouting),
                  onChanged: _canRouting && !_starting ? (v) => setState(() => _routing = v ?? false) : null,
                ),
                CheckboxListTile(
                  key: const ValueKey('part-map'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Map'),
                  subtitle: Text(_mapLine(p)),
                  value: _mapHere || (_map && _canMap),
                  onChanged: _canMap && !_starting ? (v) => setState(() => _map = v ?? false) : null,
                ),
                CheckboxListTile(
                  key: const ValueKey('part-places'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Places and addresses'),
                  subtitle: Text(_partLine(_placesHere, p.places, p.placesProblem)),
                  value: _placesHere || (_places && _canPlaces),
                  onChanged: _canPlaces && !_starting ? (v) => setState(() => _places = v ?? false) : null,
                ),
                const SizedBox(height: 8),
                if (_canAny) ...[
                  Text('About ${formatBytes(_total)} to download', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text)),
                  if (_picked && _already > 0)
                    Text(
                      'About ${formatBytes(_total + _already)} on this phone in all, ${formatBytes(_already)} of it already here',
                      key: const ValueKey('region-size-in-all'),
                      style: TextStyle(fontSize: 15, color: k.secondary),
                    ),
                ] else if (_routingHere || _mapHere || _placesHere)
                  Text('${region.name} is on this phone.', style: TextStyle(fontSize: 16, color: k.secondary))
                else
                  Text('Nothing of ${region.name} can be downloaded here.', style: TextStyle(fontSize: 16, color: k.warning)),
                if (!r.maps.engine.online && _canAny) ...[
                  const SizedBox(height: 8),
                  Text('Downloading needs a connection.', style: TextStyle(fontSize: 15, color: k.warning)),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(fontSize: 16, color: k.emergency)),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('region-download'),
                      onPressed: p != null && !_starting && _picked ? _start : null,
                      child: const Text('Download'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
