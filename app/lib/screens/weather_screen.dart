import 'package:flutter/material.dart';

import '../theme.dart';
import '../weather/live_view.dart';
import '../weather/places.dart';
import '../weather/weather_state.dart';

/// The Weather module: for each watched place, the forecast day by day and everything that is happening near it (warnings,
/// fires, earthquakes, rivers, avalanches), each with its age. A thing that is happening opens with "Ask about this".
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key, required this.weather, this.onAsk, this.onOpenSettings});

  final WeatherState weather;

  /// Starts a new chat with this question (Ask about this).
  final void Function(String question)? onAsk;

  /// Opens Settings > Weather and alerts.
  final VoidCallback? onOpenSettings;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  List<WatchPlace>? _places;
  String? _placeId;
  Future<List<SourceView>>? _view;
  int _seenRevision = -1;

  WeatherState get w => widget.weather;

  @override
  void initState() {
    super.initState();
    w.addListener(_changed);
    w.focus.addListener(_onFocus);
    _load().then((_) => _onFocus());
  }

  @override
  void dispose() {
    w.removeListener(_changed);
    w.focus.removeListener(_onFocus);
    super.dispose();
  }

  /// A tapped pop-up: show its place, then open its item when the data is there.
  Future<void> _onFocus() async {
    final f = w.focus.value;
    if (f == null || !mounted) return;
    w.focus.value = null;
    setState(() => _placeId = f.placeId);
    await _load();
    final views = await _view;
    if (!mounted || views == null) return;
    for (final v in views) {
      for (final i in v.items) {
        if (i.address == f.address) {
          _openItem(context, v, i);
          return;
        }
      }
    }
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('That alert has ended or is no longer in the data.')));
  }

  int get _revision => Object.hash(w.lastOkAt, w.enabledSources.length, w.updating);

  void _changed() {
    if (_revision != _seenRevision && !w.updating) _load();
  }

  Future<void> _load() async {
    // (A focus from a pop-up may name a place first; keep it if it is watched.)
    _seenRevision = _revision;
    final places = await w.watchedPlaces();
    if (!mounted) return;
    setState(() {
      _places = places;
      if (_placeId == null || !places.any((p) => p.id == _placeId)) {
        _placeId = places.isEmpty ? null : places.firstWhere((p) => p.kind == PlaceKind.here, orElse: () => places.first).id;
      }
      final p = places.where((p) => p.id == _placeId).firstOrNull;
      _view = p == null ? null : w.viewFor(p);
    });
  }

  Future<void> _update() async {
    final r = await w.updateNow();
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    if (r.blocked != null) {
      m.showSnackBar(SnackBar(
        content: Text(r.blocked!.message),
        action: SnackBarAction(label: 'Update anyway', onPressed: () => w.updateNow(anyway: true)),
      ));
    } else {
      m.showSnackBar(SnackBar(content: Text(r.words)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final places = _places;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          if (widget.onOpenSettings != null)
            IconButton(tooltip: 'Weather and alerts settings', icon: const Icon(Icons.tune), onPressed: widget.onOpenSettings),
        ],
      ),
      body: ListenableBuilder(
        listenable: w,
        builder: (context, _) {
          final st = w.status();
          return RefreshIndicator(
            onRefresh: _update,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _statusBox(context, st),
                const SizedBox(height: 12),
                if (w.enabledSources.isEmpty)
                  _empty(context, 'Nothing is switched on yet.', 'Choose weather, alerts or fires in Settings > Weather and alerts.')
                else if (places == null)
                  const SizedBox.shrink()
                else if (places.isEmpty)
                  _empty(context, 'No place is being watched.', 'Choose places under Settings > Weather and alerts > Places.')
                else ...[
                  if (places.length > 1)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in places)
                          ChoiceChip(
                            label: Text(p.name),
                            selected: p.id == _placeId,
                            onSelected: (_) {
                              setState(() => _placeId = p.id);
                              _load();
                            },
                          ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  FutureBuilder<List<SourceView>>(
                    future: _view,
                    builder: (context, snap) {
                      if (!snap.hasData) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                      final views = snap.data!;
                      final forecast = [for (final v in views) if (v.group == LiveGroup.forecast) v];
                      final alerts = [for (final v in views) if (v.group == LiveGroup.alerts) v];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final v in forecast) _forecast(context, v),
                          if (alerts.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text('Happening nearby', style: TextStyle(fontSize: 13, letterSpacing: 0.6, color: k.secondary)),
                            const SizedBox(height: 6),
                            ..._alerts(context, alerts),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _statusBox(BuildContext context, WeatherStatus st) {
    final k = context.t;
    final colour = switch (st.tone) {
      StatusTone.ok => k.ok,
      StatusTone.warn => k.warning,
      StatusTone.quiet => k.secondary,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: colour),
          const SizedBox(width: 10),
          Expanded(child: Text(st.headline, style: TextStyle(fontSize: 15, color: k.text))),
          TextButton(
            key: const ValueKey('weather-update-now'),
            onPressed: w.updating || w.enabledSources.isEmpty ? null : _update,
            child: Text(w.updating ? 'Updating…' : 'Update now'),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, String a, String b) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: Column(
        children: [
          Text(a, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: k.text)),
          const SizedBox(height: 6),
          Text(b, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: k.secondary)),
          if (widget.onOpenSettings != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: widget.onOpenSettings, child: const Text('Open Weather and alerts settings')),
          ],
        ],
      ),
    );
  }

  String _ageLine(SourceView v) {
    if (v.missing) return v.error != null ? 'Not downloaded: ${v.error}' : 'Not downloaded yet. Update now to get it.';
    final a = v.age == null ? '' : v.age!;
    if (v.expired) return 'Expired${a.isEmpty ? '' : ' · $a'} · needs a connection for more';
    return a;
  }

  Widget _forecast(BuildContext context, SourceView v) {
    final k = context.t;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v.source.title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
          Text(_ageLine(v), style: TextStyle(fontSize: 13, color: v.expired ? k.warning : k.secondary)),
          const SizedBox(height: 8),
          if (v.items.isEmpty && !v.missing)
            Text(v.expired ? 'Every day of this forecast has passed.' : 'No forecast.', style: TextStyle(fontSize: 15, color: k.secondary)),
          for (final i in v.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 92, child: Text(i.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text))),
                  Expanded(child: _forecastText(k, i)),
                ],
              ),
            ),
          if (v.source.attribution.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(v.source.attribution, style: TextStyle(fontSize: 12, color: k.secondary)),
          ],
        ],
      ),
    );
  }

  /// A forecast row: the headline values (temperature, high and low, conditions) first, then the rest without the ones that are
  /// zero ("Snow 0.0 in" on a dry day says nothing).
  Widget _forecastText(CacheTokens k, LiveItem i) {
    const lead = ['Temperature', 'High', 'Low', 'Conditions'];
    final head = [
      for (final f in lead)
        if (i.fields[f] != null) (f == 'High' || f == 'Low') ? '$f ${i.fields[f]}' : i.fields[f]!,
    ];
    final rest = [
      for (final e in i.fields.entries)
        if (!lead.contains(e.key) && !_isZero(e.value)) '${e.key} ${e.value}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (head.isNotEmpty) Text(head.join(' · '), style: TextStyle(fontSize: 15, color: k.text)),
        if (rest.isNotEmpty) Text(rest.join(' · '), style: TextStyle(fontSize: 13, height: 1.35, color: k.secondary)),
      ],
    );
  }

  /// A value that starts with a number equal to zero, like "0.0 in over 0 h" or "0%".
  static bool _isZero(String v) {
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)').firstMatch(v);
    return m != null && double.parse(m.group(1)!) == 0;
  }

  List<Widget> _alerts(BuildContext context, List<SourceView> views) {
    final k = context.t;
    final out = <Widget>[];
    for (final v in views) {
      final active = v.active;
      out.add(Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.source.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                  Text(
                    v.missing || v.expired
                        ? _ageLine(v)
                        : active.isEmpty
                        ? 'None active${v.age == null ? '' : ' · checked ${v.age}'}'
                        : '${active.length} active${v.age == null ? '' : ' · ${v.age}'}',
                    style: TextStyle(fontSize: 13, color: v.expired ? k.warning : k.secondary),
                  ),
                ],
              ),
            ),
            for (final i in active)
              ListTile(
                minTileHeight: 56,
                title: Text(i.label, style: const TextStyle(fontSize: 16)),
                subtitle: Text([if (i.distance != null) i.distance!, if (i.summary.isNotEmpty) i.summary].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openItem(context, v, i),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ));
    }
    return out;
  }

  void _openItem(BuildContext context, SourceView v, LiveItem i) {
    final k = context.t;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(i.label, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('${v.source.title} · ${v.place.name}${v.age == null ? '' : ' · ${v.age}'}', style: TextStyle(fontSize: 14, color: k.secondary)),
              const SizedBox(height: 12),
              for (final e in i.fields.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 120, child: Text(e.key, style: TextStyle(fontSize: 15, color: k.secondary))),
                      Expanded(child: SelectableText(e.value, style: TextStyle(fontSize: 15, color: k.text))),
                    ],
                  ),
                ),
              if (widget.onAsk != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('ask-about-this'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    widget.onAsk!(
                      'Tell me about this ${v.source.title.toLowerCase()} item near ${v.place.name}: ${i.label}. What does it mean for me, and what should I do?',
                    );
                  },
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Ask about this'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
