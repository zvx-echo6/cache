import 'package:flutter/material.dart';

import '../../location/location_service.dart';
import '../../location/position_source.dart' show LocationPermissionState;
import '../../theme.dart';
import '../../weather/connector.dart';
import '../../weather/places.dart';
import '../../weather/source_icon.dart';
import '../../weather/weather_state.dart';
import '../../weather/words.dart';
import 'own_source_pages.dart';
import 'deps.dart';
import 'key_sheet.dart';
import 'source_page.dart';
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
    getKeyUrl: c.docs ?? w.catalogues.map((k) => k.catalogue.homepage).firstWhere((h) => h.startsWith('https://'), orElse: () => 'https://cached.info'),
    steps: const ['Follow their steps to get a key, then copy it'],
    onSave: (key) => w.saveKey(c, key, switchOn: !replace),
    openUrl: d.hub.openUrl,
    savedNote: replace
        ? "Saving checks the new key with one real download and replaces the old one. The key stays on this device and isn't shown again."
        : "Saving checks the key with one real download and turns on ${title ?? c.title}. The key stays on this device and isn't shown again.",
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

/// Settings > Weather and alerts: one line saying how old the data is (with a small refresh button), what weather watches (your
/// location, the downloaded regions and the saved places, each with its switch), and the sources from the catalogue (featured ones
/// first, the rest under More sources).
class WeatherPage extends StatefulWidget {
  const WeatherPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  SettingsDeps get d => widget.deps;
  WeatherState get w => d.hub.weather;
  @override
  void initState() {
    super.initState();
    // Nothing downloaded yet (a first start with no connection until now): try once on opening.
    if (w.started && w.catalogues.isEmpty && !w.refreshingCatalogues) w.refreshCatalogues();
  }

  /// The refresh button: the source list first (the connector catalogues, as "Check for updates" does, so a newly published
  /// source shows here), then the data.
  Future<void> _refresh() async {
    await w.refreshCatalogues();
    final r = await w.updateNow(force: true);
    if (mounted) say(context, r.words);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings]),
      builder: (context, _) {
        final all = w.sources;
        final featured = [for (final c in all) if (c.featured) c];
        final more = [for (final c in all) if (!c.featured) c];
        return SettingsPage(
          title: 'Weather and alerts',
          children: [
            StatusLine(status: w.status(), updating: w.updating, onRefresh: _refresh),
            WatchGroups(deps: d),
            if (all.isEmpty)
              NoteText(w.refreshingCatalogues
                  ? 'Loading sources…'
                  : (w.catalogueErrors.values.firstOrNull ?? 'No sources downloaded yet. Connect to the internet and they load by themselves.'))
            else ...[
              const NoteText('What Cache watches for your places. All free; some need a free key you get from the provider.'),
              SettingsGroup(
                rows: [
                  for (final c in featured) SourceRow(deps: d, source: c),
                  SettingsRow(
                      key: const ValueKey('more-sources'),
                      icon: Icons.add,
                      title: 'More sources',
                      status: [Part(more.isEmpty ? 'Add your own source' : more.map((c) => c.title).join(', '))],
                      trailing: more.isEmpty ? null : Text('${more.length} more', style: TextStyle(fontSize: 13, color: context.t.secondary)),
                      chevron: true,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MoreSourcesPage(deps: d))),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// "What weather watches": your location, the downloaded regions and the saved places, each with its switch. A saved place's switch
/// is the same one as on its edit page (one value, two views). Switches move at once; turning on your location asks the phone for
/// it, and when the phone will not give it the switch goes back with why and "Open settings".
class WatchGroups extends StatefulWidget {
  const WatchGroups({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<WatchGroups> createState() => _WatchGroupsState();
}

class _WatchGroupsState extends State<WatchGroups> {
  WeatherState get w => widget.deps.hub.weather;
  late Future<List<WatchPlace>> _choices = w.placeChoices();
  final _query = TextEditingController();
  String _q = '';

  /// More saved places than this and the group gets a search box.
  static const int searchFrom = 8;

  @override
  void initState() {
    super.initState();
    w.addListener(_reread);
  }

  @override
  void dispose() {
    w.removeListener(_reread);
    _query.dispose();
    super.dispose();
  }

  // The saved places and regions change with the weather part (a place saved or deleted, a region downloaded).
  void _reread() {
    if (mounted) {
      setState(() {
        _choices = w.placeChoices();
      });
    }
  }

  Future<void> _setHere(bool on) async {
    final settings = w.settings;
    final loc = widget.deps.location;
    final m = ScaffoldMessenger.of(context);
    settings.setWatchHere(on);
    if (!on || loc.fix != null) return;
    if (!loc.enabled) await loc.setEnabled(true);
    final ok = await loc.request(explain: () async => true);
    if (ok) return;
    settings.setWatchHere(false);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: const Text('Could not turn on. Location is blocked.'),
      action: SnackBarAction(label: 'Open settings', onPressed: loc.openAppSettings),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final settings = w.settings;
    final loc = widget.deps.location;
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, loc]),
      builder: (context, _) => FutureBuilder<List<WatchPlace>>(
        future: _choices,
        builder: (context, snap) {
          final all = snap.data ?? const <WatchPlace>[];
          final regions = [for (final p in all) if (p.kind == PlaceKind.region) p];
          final saved = [for (final p in all) if (p.kind == PlaceKind.saved) p];
          final words = _q.toLowerCase().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
          final shown = [for (final p in saved) if (words.every('${p.name} ${p.subtitle}'.toLowerCase().contains)) p];
          final blocked = loc.permission == LocationPermissionState.deniedForever || loc.problem == LocationProblem.permissionBlocked;
          Widget place(WatchPlace p) => SwitchRow(
            key: ValueKey('watch-${p.id}'),
            title: p.name,
            value: settings.watchedPlaces.contains(p.id),
            onChanged: (on) => settings.setWatched(p.id, on),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsGroup(
                label: 'What weather watches',
                rows: [
                  if (blocked)
                    SettingsRow(
                      key: const ValueKey('watch-here'),
                      title: 'Your location',
                      status: const [Part('Location is blocked', Tone.danger)],
                      trailing: RowButton(key: const ValueKey('watch-here-settings'), label: 'Open settings', onPressed: loc.openAppSettings),
                    )
                  else
                    SwitchRow(
                      key: const ValueKey('watch-here'),
                      title: 'Your location',
                      status: const [Part('Updates while you move. Needs location.')],
                      value: settings.watchHere,
                      onChanged: _setHere,
                    ),
                ],
              ),
              if (regions.isNotEmpty) ...[
                const SizedBox(height: 10),
                SettingsGroup(label: 'Regions', rows: [for (final p in regions) place(p)]),
              ],
              const SizedBox(height: 10),
              SettingsGroup(
                label: 'Saved places',
                rows: [
                  if (saved.length > searchFrom)
                    Material(
                      color: k.surface,
                      child: TextField(
                        key: const ValueKey('watch-search'),
                        controller: _query,
                        onChanged: (v) => setState(() => _q = v.trim()),
                        textInputAction: TextInputAction.search,
                        style: TextStyle(fontSize: 15, color: k.text),
                        decoration: InputDecoration(
                          hintText: 'Search places',
                          hintStyle: TextStyle(color: k.secondary),
                          prefixIcon: Icon(Icons.search, color: k.secondary),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        ),
                      ),
                    ),
                  if (saved.isEmpty) const SettingsRow(key: ValueKey('watch-no-places'), title: 'None yet'),
                  for (final p in shown) place(p),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One source: what it gives and who provides it, and its switch, or "Get key" on the row while it needs a key. Tapping it opens the
/// source's details (its key can be replaced or removed there).
class SourceRow extends StatelessWidget {
  const SourceRow({super.key, required this.deps, required this.source});

  final SettingsDeps deps;
  final Connector source;

  @override
  Widget build(BuildContext context) {
    final w = deps.hub.weather;
    final c = source;
    final k = context.t;
    final gives = c.description.isEmpty ? '' : '${c.description[0].toUpperCase()}${c.description.substring(1)}';
    final status = w.isOwn(c)
        ? joinParts([
            [const Part('Your source')],
            [Part('checked ${everyWords(c.refreshMinutes)}')],
          ])
        : joinParts([
            if (gives.isNotEmpty) [Part(gives)],
            if (c.provider.isNotEmpty) [Part(c.provider)],
          ]);
    return SettingsRow(
      key: ValueKey('source-${c.id}'),
      leading: Icon(sourceIcon(c), size: 22, color: k.secondary),
      title: c.title,
      status: status,
      trailing: w.keyReady(c)
          ? Switch(value: w.isOn(c.id), onChanged: (v) => w.setSourceOn(c, v))
          : RowButton(key: ValueKey('get-key-${c.id}'), label: 'Get key', onPressed: () => addKeyFor(context, deps, c)),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourcePage(deps: deps, sourceId: c.id))),
    );
  }
}

/// Weather and alerts > More sources: the sources that are not featured, searchable; then "Your own" (the sources the person
/// added, each with its switch) and Add your own source.
class MoreSourcesPage extends StatefulWidget {
  const MoreSourcesPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<MoreSourcesPage> createState() => _MoreSourcesPageState();
}

class _MoreSourcesPageState extends State<MoreSourcesPage> {
  final _query = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(Connector c) {
    if (_q.isEmpty) return true;
    final hay = '${c.title} ${c.provider} ${c.description} ${c.category} ${c.coverage}'.toLowerCase();
    return _q.toLowerCase().split(RegExp(r'\s+')).every(hay.contains);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    final w = d.hub.weather;
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings]),
      builder: (context, _) {
        final more = [for (final c in w.sources) if (!c.featured && !w.isOwn(c)) c];
        final shown = [for (final c in more) if (_matches(c)) c];
        final own = [for (final c in w.ownSources) if (_matches(c)) c];
        final errors = w.catalogueErrors.values.toList();
        return SettingsPage(
          title: 'More sources',
          children: [
            TextField(
              key: const ValueKey('search-sources'),
              controller: _query,
              onChanged: (v) => setState(() => _q = v.trim()),
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 15, color: k.text),
              decoration: InputDecoration(
                hintText: 'Search ${more.length} ${more.length == 1 ? 'source' : 'sources'}',
                hintStyle: TextStyle(color: k.secondary),
                prefixIcon: Icon(Icons.search, color: k.secondary),
                filled: true,
                fillColor: k.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
            if (more.isNotEmpty && shown.isEmpty) const NoteText('No source matches your search.'),
            if (shown.isNotEmpty) SettingsGroup(rows: [for (final c in shown) SourceRow(deps: d, source: c)]),
            if (errors.isNotEmpty) NoteText(errors.first),
            if (own.isNotEmpty) SettingsGroup(label: 'Your own', rows: [for (final c in own) SourceRow(deps: d, source: c)]),
            AddOwnSourceRow(deps: d),
          ],
        );
      },
    );
  }
}

/// The one line at the top: how old the data is, turning into a warning when it is old, with a small round refresh button.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.status, required this.updating, required this.onRefresh});

  final WeatherStatus status;
  final bool updating;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final warn = status.tone == StatusTone.warn;
    return Row(
      children: [
        if (warn) ...[Icon(Icons.warning_amber_rounded, size: 18, color: k.warning), const SizedBox(width: 6)],
        Expanded(
          child: Text(
            updating ? 'Updating…' : status.headline,
            key: const ValueKey('status-headline'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: warn ? k.warning : k.secondary),
          ),
        ),
        SizedBox(
          width: 48,
          height: 48,
          child: updating
              ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.5))
              : IconButton(
                  key: const ValueKey('weather-refresh'),
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                  icon: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: k.surface),
                    child: Icon(Icons.refresh, size: 18, color: k.text),
                  ),
                ),
        ),
      ],
    );
  }
}
