import 'dart:async';

import 'package:flutter/material.dart';

import '../../layout/adaptive.dart' show ContentWidth;
import '../../regions/region_catalogue.dart';
import '../discover_state.dart';
import 'kit.dart';

/// "Choose a place" in the wizard: the region list searched by name (a town, a county, a state); the place is the middle of the
/// region chosen.
class PlacePage extends StatefulWidget {
  const PlacePage({super.key, required this.catalogue});

  final RegionCatalogue catalogue;

  @override
  State<PlacePage> createState() => _PlacePageState();
}

class _PlacePageState extends State<PlacePage> {
  final _query = TextEditingController();
  List<RegionHit> _all = const [];
  List<RegionHit> _found = const [];
  String? _error;
  bool _busy = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.catalogue.globalSearch().then(
      (l) {
        if (mounted) setState(() => _all = l);
      },
      onError: (Object _) {
        if (mounted) setState(() => _error = "Couldn't read the list of places. It needs a connection the first time.");
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _found = searchRegions(q, _all, limit: 30));
    });
  }

  Future<void> _pick(RegionHit h) async {
    setState(() => _busy = true);
    try {
      final r = await widget.catalogue.record(h.id, shardId: h.shardId);
      final b = r?.bbox;
      if (!mounted) return;
      if (b == null || b.length != 4) {
        setState(() => _error = "Couldn't read where ${h.name} is.");
        return;
      }
      Navigator.of(context).pop(DiscoverPlace(lat: (b[1] + b[3]) / 2, lon: (b[0] + b[2]) / 2, name: h.name));
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't read where ${h.name} is. It needs a connection the first time.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Choose a place')),
    body: LayoutBuilder(
      builder: (context, c) => ListView(
        padding: ContentWidth.padFor(c.maxWidth, min: 12, maxWidth: 560).copyWith(top: 4, bottom: 24),
        children: [
          DSearchBox(hint: 'A town, county or state', controller: _query, onChanged: _changed),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_error != null) DHint(_error!, top: 12),
          const SizedBox(height: 12),
          if (_found.isNotEmpty)
            RowStack(rows: [
              for (final h in _found)
                DRow(key: ValueKey('place-${h.id}'), leading: DTile(discoverIcon('pin')), title: h.name, subtitle: h.inside, onTap: _busy ? null : () => _pick(h)),
            ]),
        ],
      ),
    ),
  );
}
