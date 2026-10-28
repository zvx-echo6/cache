import 'package:flutter/material.dart';

import '../../maps/ui/format.dart';
import '../../settings/data_policy.dart';
import '../../theme.dart';
import '../region_catalogue.dart';
import '../regions_state.dart';

/// What downloading a region costs, part by part, shown before anything is downloaded. The parts are ticked by default; a part
/// already on the phone, or one that cannot be downloaded here, is not. Sizes count only what is not on the phone yet.
Future<void> showRegionSheet(BuildContext context, RegionsState regions, RegionRecord region) {
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
  bool _starting = false;
  bool _blockedByMobile = false;
  String? _error;

  RegionsState get r => widget.regions;

  @override
  void initState() {
    super.initState();
    r.plan(widget.region).then((p) {
      if (mounted) setState(() => _plan = p);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not work out the size');
    });
  }

  LocalRegion? get _here => r.regionOf(widget.region.id);
  bool get _routingHere => _here?.hasRouting ?? false;
  bool get _mapHere => _here?.hasMap ?? false;
  bool get _canRouting => !_routingHere && _plan?.routing != null;
  bool get _canMap => !_mapHere && (_plan?.mapAllowed.isNotEmpty ?? false);

  int get _total {
    final p = _plan;
    if (p == null) return 0;
    return (_routing && _canRouting ? p.routing!.downloadBytes : 0) + (_map && _canMap ? p.mapBytes : 0);
  }

  Future<void> _start({bool anyway = false}) async {
    setState(() {
      _starting = true;
      _blockedByMobile = false;
      _error = null;
    });
    try {
      await r.download(widget.region, routing: _routing && _canRouting, map: _map && _canMap, anyway: anyway);
      if (mounted) Navigator.pop(context);
    } on MobileDataBlocked catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _blockedByMobile = true;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  String _routingLine(RegionPlan p) {
    if (_routingHere) return 'On this phone';
    final rp = p.routing;
    if (rp == null) return p.routingProblem ?? 'Not available';
    final already = rp.bytes - rp.downloadBytes;
    return [
      'About ${formatBytes(rp.downloadBytes)}',
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
                  subtitle: Text(_routingLine(p)),
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
                const SizedBox(height: 8),
                if (_canRouting || _canMap)
                  Text('About ${formatBytes(_total)} to download', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: k.text))
                else if (_routingHere || _mapHere)
                  Text('${region.name} is on this phone.', style: TextStyle(fontSize: 16, color: k.secondary))
                else
                  Text('Nothing of ${region.name} can be downloaded here.', style: TextStyle(fontSize: 16, color: k.warning)),
                if (!r.maps.engine.online && (_canRouting || _canMap)) ...[
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
                    child: _blockedByMobile
                        ? FilledButton(
                            key: const ValueKey('download-anyway'),
                            onPressed: () => _start(anyway: true),
                            child: const Text('Download anyway'),
                          )
                        : FilledButton(
                            key: const ValueKey('region-download'),
                            onPressed: p != null && !_starting && ((_routing && _canRouting) || (_map && _canMap)) ? () => _start() : null,
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
