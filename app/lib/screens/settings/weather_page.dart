import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/connector.dart';
import '../../weather/curated.dart';
import '../../weather/weather_state.dart';
import 'data_sources_page.dart';
import 'deps.dart';
import 'key_sheet.dart';
import 'places_page.dart';
import 'widgets.dart';

/// Opens the Add a key sheet for [c] and says so when the key was saved. [replace] is for a key that is already there.
Future<void> addKeyFor(BuildContext context, SettingsDeps d, Connector c, {bool replace = false, String? title}) async {
  final w = d.hub.weather;
  final provider = c.provider.isEmpty ? 'the provider' : c.provider;
  final saved = await showAddKeySheet(
    context,
    title: title ?? c.title,
    gives: '${c.description.isEmpty ? c.title : _sentence(c.description)} You need your own key from $provider.',
    getKeyLabel: 'Get a key from $provider',
    getKeyUrl: c.docs ?? w.catalogues.map((k) => k.catalogue.homepage).firstWhere((h) => h.startsWith('https://'), orElse: () => 'https://cache.echo6.co'),
    steps: const ['Follow their steps to get a key, then copy it'],
    onSave: (key) => w.saveKey(c, key, switchOn: !replace),
    openUrl: d.hub.openUrl,
    savedNote: replace
        ? "Saving checks the new key with one real download and replaces the old one. The key stays on this phone and isn't shown again."
        : "Saving checks the key with one real download and turns on ${title ?? c.title}. The key stays on this phone and isn't shown again.",
  );
  if (saved == true && context.mounted) say(context, replace ? 'Key replaced' : '${title ?? c.title} is on');
}

/// The first sentence of a description, capitalised, ending in a full stop.
String _sentence(String s) {
  var t = s.trim();
  final cut = t.indexOf('. ');
  if (cut > 0) t = t.substring(0, cut);
  t = t.replaceAll(RegExp(r'[.;]+$'), '');
  return '${t[0].toUpperCase()}${t.substring(1)}.';
}

/// Settings > Weather and alerts: how old the data is and why, the switches, the places to watch, and Advanced (all data sources).
class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  SettingsDeps get d => widget.deps;
  WeatherState get w => d.hub.weather;
  String _places = '';

  @override
  void initState() {
    super.initState();
    w.addListener(_reloadPlaces);
    d.hub.settings.addListener(_reloadPlaces);
    _reloadPlaces();
    // Nothing downloaded yet (a first start with no connection until now): try once on opening.
    if (w.started && w.catalogues.isEmpty && !w.refreshingCatalogues) w.refreshCatalogues();
  }

  @override
  void dispose() {
    w.removeListener(_reloadPlaces);
    d.hub.settings.removeListener(_reloadPlaces);
    super.dispose();
  }

  Future<void> _reloadPlaces() async {
    final s = await w.watchedSummary();
    if (mounted && s != _places) setState(() => _places = s);
  }

  Future<void> _update({bool anyway = false}) async {
    final r = await w.updateNow(anyway: anyway);
    if (!mounted) return;
    say(
      context,
      r.words,
      action: r.blocked != null ? SnackBarAction(label: 'Update anyway', onPressed: () => _update(anyway: true)) : null,
    );
  }

  List<Part> _status(CuratedRow r, List<Connector> list) {
    if (list.isEmpty) return const [Part('Not downloaded yet. Needs a connection once.', Tone.warn)];
    final provider = list.first.provider;
    return joinParts([
      [Part(r.detail)],
      if (provider.isNotEmpty) [Part(provider)],
    ]);
  }

  Widget _row(BuildContext context, CuratedRow r) {
    final list = w.rowSources(r);
    final status = _status(r, list);
    final keyed = list.isNotEmpty && list.any((c) => c.needsKey);
    final missing = [for (final c in list) if (!w.keyReady(c)) c];
    if (keyed && missing.isNotEmpty) {
      return SettingsRow(
        title: r.title,
        status: status,
        trailing: RowButton(label: 'Add key', onPressed: () => addKeyFor(context, d, missing.first, title: r.title)),
      );
    }
    return SwitchRow(title: r.title, status: status, value: w.rowIsOn(r), onChanged: list.isEmpty ? null : (v) => w.setRowOn(r, v));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings]),
      builder: (context, _) {
        bool isKeyed(CuratedRow r) {
          final list = w.rowSources(r);
          return list.isEmpty ? r.keyed : list.any((c) => c.needsKey);
        }

        final free = [for (final r in kCurated) if (!isKeyed(r)) r];
        final keyed = [for (final r in kCurated) if (isKeyed(r)) r];
        return SettingsPage(
          title: 'Weather and alerts',
          children: [
            StatusBox(status: w.status(), updating: w.updating, onUpdate: _update),
            if (free.isNotEmpty) SettingsGroup(label: 'Free', rows: [for (final r in free) _row(context, r)]),
            if (keyed.isNotEmpty) SettingsGroup(label: 'Needs your own key (free)', rows: [for (final r in keyed) _row(context, r)]),
            SettingsGroup(
              label: 'Watch these places',
              rows: [
                SettingsRow(
                  title: 'Places',
                  status: [Part(_places.isEmpty ? '…' : _places)],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlacesPage(deps: d))),
                ),
              ],
            ),
            AdvancedRow(
              status: 'All data sources, more',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DataSourcesPage(deps: d))),
            ),
          ],
        );
      },
    );
  }
}

/// The line at the top: how old the data is (and why when it is stale), with Update now.
class StatusBox extends StatelessWidget {
  const StatusBox({super.key, required this.status, required this.updating, required this.onUpdate});

  final WeatherStatus status;
  final bool updating;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final dot = switch (status.tone) {
      StatusTone.ok => k.ok,
      StatusTone.warn => k.warning,
      StatusTone.quiet => k.secondary,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(updating ? 'Updating…' : status.headline, key: const ValueKey('status-headline'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: k.text)),
                const SizedBox(height: 3),
                Text(status.detail, key: const ValueKey('status-detail'), style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (updating)
            const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)))
          else
            TextButton(
              key: const ValueKey('update-now'),
              onPressed: onUpdate,
              style: TextButton.styleFrom(foregroundColor: k.accent, minimumSize: const Size(48, 48)),
              child: const Text('Update now', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            ),
        ],
      ),
    );
  }
}
