import 'package:flutter/material.dart';

import '../../net/fetch.dart' show fetchBytes;
import '../../roads/road_registry.dart';
import '../../roads/road_sources.dart';
import '../../roads/road_state.dart';
import '../../theme.dart';
import '../../weather/weather_state.dart';
import 'deps.dart';
import 'api_keys_page.dart';
import 'widgets.dart';

/// Settings > Maps > Road events: the road sources the person has (one row per 511 site or WZDx feed, each with its switch), the two ways
/// to add one, and a key row for each source that takes a key (the existing key sheet, with the steps from the data file). Adding a
/// source or saving its key turns nothing on: the switch does.

/// The "Road events" group, its note and the key rows, for the Maps page. Empty when the app has no road sources.
List<Widget> roadEventsSection(BuildContext context, SettingsDeps d) {
  final w = d.hub.weather;
  final roads = w.roads;
  if (roads == null) return const [];
  final sources = roads.sources;
  final file = roads.file;
  final feedCount = file.feeds.where((f) => f.usable).length;
  return [
    SettingsGroup(
      label: 'Road events',
      rows: [
        for (final s in sources) _SourceRow(deps: d, source: s),
        SettingsRow(
          key: const ValueKey('add-511-site'),
          icon: Icons.add,
          title: 'Add a 511 site',
          status: [Part('${file.sites.length} state and provincial sites')],
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Road511PickerPage(deps: d))),
        ),
        SettingsRow(
          key: const ValueKey('add-road-work-feed'),
          icon: Icons.add,
          title: 'Add a road work feed',
          status: [Part('$feedCount feeds, or paste a feed address')],
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RoadWorkPickerPage(deps: d))),
        ),
      ],
    ),
    if (sources.isNotEmpty) const NoteText('Closures, crashes and road work are drawn on the map from what Cache has already downloaded for the places it watches. Press and hold a source to remove it.'),
  ];
}

/// Whether any connector of [s] is switched on.
bool _on(WeatherState w, RoadSource s) => s.connectors.any((c) => w.isOn(c.id));

/// The row's second line: "Idaho · 511.idaho.gov", "Ohio DOT · version 4.2".
List<Part> _subtitle(RoadSource s) {
  if (s.site != null) return [Part(s.site!.name == s.site!.host ? s.site!.host : '${s.site!.name} · ${s.site!.host}')];
  final f = s.feed;
  if (f == null) return [Part(s.title.replaceFirst('WZDx road work: ', ''))];
  return [Part('${f.publisher} · version ${f.version}')];
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.deps, required this.source});

  final SettingsDeps deps;
  final RoadSource source;

  @override
  Widget build(BuildContext context) {
    final w = deps.hub.weather;
    final isSite = source.record.isSite;
    return SettingsRow(
      key: ValueKey('road-source-${source.record.kind}-${source.record.id}'),
      title: isSite ? '511 road events' : 'Road work (WZDx)',
      status: _subtitle(source),
      trailing: Switch(value: _on(w, source), onChanged: (v) => w.setSourcesOn(source.connectors, v)),
      onTap: () => w.setSourcesOn(source.connectors, !_on(w, source)),
      holdLabel: 'Remove',
      onHold: () => _remove(context),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final w = deps.hub.weather;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${source.title}?'),
        content: const Text('It stops drawing on the map. Your key stays saved on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('remove-road-source'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await w.setSourcesOn(source.connectors, false);
    w.roads?.remove(source.record);
    if (context.mounted) say(context, 'Removed ${source.title}');
  }
}

/// Plain key rows for Map settings: NASA FIRMS and TomTom, Google (not available yet), and one key row for each road source that takes a
/// key. Each opens the master list at that provider.
List<Widget> mapKeyRows(BuildContext context, SettingsDeps d) {
  final roads = d.hub.weather.roads;
  return [
    SettingsGroup(
      label: 'Online map data',
      rows: [
        ApiKeyShortcutRow(deps: d, providerId: 'firms'),
        ApiKeyShortcutRow(deps: d, providerId: 'tomtom'),
        if (roads != null) for (final s in roads.sources) if (s.keyAlias != null) ApiKeyShortcutRow(deps: d, providerId: s.keyAlias!),
        ApiKeyShortcutRow(deps: d, providerId: 'google'),
      ],
    ),
    const NoteText('Keys are added in Settings > API keys. Without one, the map shows what is in your downloaded regions.'),
  ];
}

// ------------------------------------------------------------------------------------------------ the pickers

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.hint, required this.onChanged});

  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return TextField(
      key: const ValueKey('road-search'),
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(Icons.search, color: k.secondary),
        filled: true,
        fillColor: k.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
      ),
    );
  }
}

bool _matches(String query, Iterable<String> fields) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return fields.any((f) => f.toLowerCase().contains(q));
}

/// Adding a 511 site: search, "Enter another site", the sites by country. A tap adds the site (turning nothing on) and opens its key sheet.
class Road511PickerPage extends StatefulWidget {
  const Road511PickerPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<Road511PickerPage> createState() => _Road511PickerPageState();
}

class _Road511PickerPageState extends State<Road511PickerPage> {
  String _query = '';

  RoadSources get _roads => widget.deps.hub.weather.roads!;

  Future<void> _pick(RoadSite site) async {
    _roads.addSite(site);
    await _keyFor('${'k511'}:${site.host}');
  }

  Future<void> _keyFor(String id) async {
    final s = _roads.sourceOf(id);
    if (s?.keyAlias != null && context.mounted) {
      final nav = Navigator.of(context);
      nav.pop();
      await openApiKeys(nav.context, widget.deps, providerId: s!.keyAlias);
    }
  }

  Future<void> _enterOther() async {
    final c = TextEditingController();
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter another site'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The web address of a 511 site that is not listed, for example 511.example.gov. It must offer a developer key.'),
            const SizedBox(height: 12),
            TextField(key: const ValueKey('other-site-field'), controller: c, autofocus: true, autocorrect: false, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: '511.example.gov')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('other-site-add'), onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
        ],
      ),
    );
    if (host == null) return;
    final added = _roads.addUnlistedSite(host);
    if (added == null) {
      if (mounted) say(context, "That isn't a web address.");
      return;
    }
    await _keyFor('k511:$added');
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.deps.hub.weather;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final file = _roads.file;
        final have = {for (final r in _roads.records) if (r.isSite) r.id};
        List<Widget> rowsFor(String country) => [
          for (final s in file.sitesIn(country))
            if (_matches(_query, [s.name, s.host]))
              SettingsRow(
                key: ValueKey('site-${s.host}'),
                title: s.name,
                status: [Part(s.host)],
                trailing: have.contains(s.host) ? Text('Added', style: TextStyle(fontSize: 14, color: context.t.secondary)) : null,
                chevron: !have.contains(s.host),
                onTap: have.contains(s.host) ? null : () => _pick(s),
              ),
        ];
        final us = rowsFor('US'), ca = rowsFor('CA');
        return SettingsPage(
          title: '511 road events',
          children: [
            const NoteText('Closures, crashes and road work from your state or province 511 site. Every site needs its own key, which you add right after.'),
            _SearchBox(hint: 'Search ${file.sites.length} sites', onChanged: (v) => setState(() => _query = v)),
            SettingsGroup(
              rows: [
                SettingsRow(key: const ValueKey('enter-another-site'), icon: Icons.add, title: 'Enter another site', status: const [Part('A 511 site that is not listed')], onTap: _enterOther),
              ],
            ),
            if (us.isNotEmpty) SettingsGroup(label: 'United States', rows: us),
            if (ca.isNotEmpty) SettingsGroup(label: 'Canada', rows: ca),
            if (us.isEmpty && ca.isEmpty) NoteText('No site matches "$_query".'),
          ],
        );
      },
    );
  }
}

/// Adding road work: search, "Paste a feed URL", then the registry's feeds: those Cache can use, then those listed but not usable (by
/// request, or not supported yet) with the reason.
class RoadWorkPickerPage extends StatefulWidget {
  const RoadWorkPickerPage({super.key, required this.deps, this.fetch});

  final SettingsDeps deps;

  /// Reads the registry (a test hands its own); null: the app's own fetch.
  final Future<List<int>> Function(Uri url)? fetch;

  @override
  State<RoadWorkPickerPage> createState() => _RoadWorkPickerPageState();
}

class _RoadWorkPickerPageState extends State<RoadWorkPickerPage> {
  String _query = '';
  bool _loading = true;
  String? _problem;

  RoadSources get _roads => widget.deps.hub.weather.roads!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      await _roads.loadRegistry(widget.fetch ?? (u) => fetchBytes(u));
    } catch (_) {
      _problem = "Couldn't load the list of feeds. Check your connection.";
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(RoadFeed f) async {
    final r = _roads.addRegistryFeed(f, _roads.registry);
    if (!mounted) return;
    switch (r) {
      case AddFeedResult.added:
      case AddFeedResult.already:
        final s = _roads.sourceOf('wzdx:${f.id}');
        if (s != null && s.keyAlias != null) {
          final nav = Navigator.of(context);
          nav.pop();
          await openApiKeys(nav.context, widget.deps, providerId: s.keyAlias);
        } else {
          Navigator.of(context).pop();
          say(context, '${f.publisher} added. Switch it on under Road events.');
        }
      case AddFeedResult.notUsable:
        say(context, f.byRequest ? 'Access is by request from the publisher.' : (f.unsupportedReason ?? "Cache can't use this feed yet."));
      case AddFeedResult.noAddress:
        say(context, "The list of feeds has no address for ${f.publisher}.");
    }
  }

  Future<void> _paste() async {
    final c = TextEditingController();
    String? note;
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Paste a feed URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The web address of a WZDx work zone feed (version 4.0, 4.1 or 4.2). Cache removes any key or token from it.'),
              const SizedBox(height: 12),
              TextField(key: const ValueKey('paste-feed-field'), controller: c, autofocus: true, autocorrect: false, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://')),
              if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note!, key: const ValueKey('paste-feed-note'), style: TextStyle(color: ctx.t.emergency))),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('paste-feed-add'),
              onPressed: () {
                final p = readPastedFeed(c.text);
                if (!p.ok) {
                  setD(() => note = p.problem);
                  return;
                }
                _roads.addPastedFeed(c.text, name: Uri.parse(p.url!).host);
                Navigator.pop(ctx, true);
                if (p.note != null && mounted) say(context, p.note!);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (added == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  String _line(RoadFeed f) => [
    f.area,
    'version ${f.version}',
    if (f.update.isNotEmpty && f.update != '-') 'every ${f.update}',
    if (f.access == 'key') 'key needed',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final w = widget.deps.hub.weather;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final file = _roads.file;
        final have = {for (final r in _roads.records) if (!r.isSite) r.id};
        bool shown(RoadFeed f) => _matches(_query, [f.publisher, f.area, f.id]);
        final usable = [for (final f in file.feeds) if (f.usable && shown(f)) f];
        final request = [for (final f in file.feeds) if (!f.usable && f.byRequest && shown(f)) f];
        final other = [for (final f in file.feeds) if (!f.usable && !f.byRequest && shown(f)) f];
        Widget row(RoadFeed f) {
          final added = have.contains(f.id);
          final grey = !f.usable;
          return SettingsRow(
            key: ValueKey('feed-${f.id}'),
            title: f.publisher,
            status: joinParts([
              [Part(_line(f))],
              if (f.byRequest) const [Part('Access by request from the publisher', Tone.warn)] else if (grey) [Part(f.unsupportedReason ?? 'Not supported yet', Tone.warn)],
            ]),
            statusLines: 3,
            dim: grey,
            trailing: added ? Text('Added', style: TextStyle(fontSize: 14, color: context.t.secondary)) : null,
            chevron: !added && !grey,
            onTap: added ? null : () => _add(f),
          );
        }

        return SettingsPage(
          title: 'Road work (WZDx)',
          children: [
            const NoteText("Planned work zones and lane closures from the US Department of Transportation's work zone feeds."),
            _SearchBox(hint: 'Search ${file.feeds.length} feeds', onChanged: (v) => setState(() => _query = v)),
            SettingsGroup(
              rows: [
                SettingsRow(key: const ValueKey('paste-feed-url'), icon: Icons.add, title: 'Paste a feed URL', status: const [Part('A WZDx feed that is not listed')], onTap: _paste),
              ],
            ),
            if (_loading) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
            else if (_problem != null) ...[
              NoteText(_problem!),
              SettingsGroup(rows: [SettingsRow(key: const ValueKey('registry-retry'), icon: Icons.refresh, title: 'Try again', onTap: _load)]),
            ],
            if (usable.isNotEmpty) SettingsGroup(label: 'Feeds', rows: [for (final f in usable) row(f)]),
            if (request.isNotEmpty) SettingsGroup(label: 'By request', rows: [for (final f in request) row(f)]),
            if (other.isNotEmpty) SettingsGroup(label: 'Not supported yet', rows: [for (final f in other) row(f)]),
            if (usable.isEmpty && request.isEmpty && other.isEmpty) NoteText('No feed matches "$_query".'),
          ],
        );
      },
    );
  }
}
