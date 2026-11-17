import 'package:flutter/material.dart';

import '../../location/location_service.dart';
import '../../location/position_source.dart' show LocationPermissionState;
import '../../theme.dart';
import '../../weather/connector.dart';
import '../../weather/places.dart';
import '../../weather/source_icon.dart';
import '../../weather/weather_state.dart';
import '../../weather/words.dart';
import 'assistant_page.dart' show AssistantPage, setUpWebSearch;
import 'own_source_pages.dart';
import 'deps.dart';
import 'key_sheet.dart';
import 'source_page.dart';
import 'widgets.dart';
import '../../guide/place_link.dart' show LinkText;
import '../../platform/app_log.dart';
import '../../update/update_ui.dart' show updateCacheAction;
import '../../weather/catalogue.dart' show kNewerCatalogueFormat;

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

/// Settings > Weather and alerts: how many sources work and when Cache last checked (with a small refresh button), what weather
/// watches (your location, the downloaded regions and the saved places, each with its switch), and the sources from the catalogue:
/// those that need attention, the working ones, the ones that are off, then More sources.
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
    logInfo('Weather: Settings page opened; ${w.sourcesLine()}, ${w.catalogues.length} catalogues');
    if (w.started && w.catalogues.isEmpty && !w.refreshingCatalogues) w.refreshCatalogues();
  }

  /// The refresh button: the source list first (the connector catalogues, as "Check for updates" does, so a newly published
  /// source shows here), then the data.
  Future<void> _refresh() async {
    logInfo('Weather: Update now tapped (Settings); ${w.sourcesLine()}');
    await w.refreshCatalogues();
    logInfo('Weather: catalogues refreshed; ${w.sourcesLine()}');
    final r = await w.updateNow(force: true);
    // A source that failed says so on its own row (in words, never an HTTP status); the message only speaks when nothing failed.
    if (mounted && r.failures.isEmpty) say(context, r.words);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings, d.hub.webSearch]),
      builder: (context, _) {
        final all = w.sources;
        // The featured sources, then any other source that is on (it needs watching like the rest); off and not featured: More sources.
        final listed = [
          for (final c in all) if (c.featured) c,
          for (final c in all) if (!c.featured && w.isOn(c.id)) c,
        ];
        final more = [for (final c in all) if (!listed.contains(c)) c];
        // Every row with its state: the sources, then web search.
        final entries = <(SourceRowState, Widget)>[
          for (final c in listed) (w.rowStateOf(c), SourceRow(deps: d, source: c)),
          (d.hub.webSearch.rowState, WebSearchRow(deps: d)),
        ];
        final attention = [for (final e in entries) if (WeatherState.needsAttention(e.$1)) e.$2];
        final off = [for (final e in entries) if (e.$1 == SourceRowState.off) e.$2];
        final rest = [for (final e in entries) if (!WeatherState.needsAttention(e.$1) && e.$1 != SourceRowState.off) e.$2];
        SettingsGroup group(List<Widget> l, [String? label]) => SettingsGroup(label: label, rows: l);
        return SettingsPage(
          title: 'Weather and alerts',
          children: [
            listed.isEmpty
                ? StatusLine(status: w.status(), updating: w.updating, onRefresh: _refresh)
                : SourcesStatusLine(weather: w, counts: sourceCountsOf(d), onRefresh: _refresh),
            WatchGroups(deps: d),
            if (all.isEmpty)
              w.refreshingCatalogues
                  ? const NoteText('Loading sources…')
                  : CatalogueErrorNote(w.catalogueErrors.values.firstOrNull ?? 'No sources downloaded yet. Connect to the internet and they load by themselves.')
            else ...[
              const NoteText('What Cache watches for your places. All free; some need a free key you get from the provider.'),
              if (attention.isNotEmpty) group(attention, 'Needs attention'),
              if (rest.isNotEmpty) group(rest, attention.isNotEmpty || off.isNotEmpty ? 'Working' : null),
              if (off.isNotEmpty) group(off, 'Off'),
              SettingsGroup(
                rows: [
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

/// How long ago, for "updated 12 min ago" and "saved 3 hours ago".
String _ago(WeatherState w, DateTime? at) => at == null ? '' : agoWords(w.clockNow.difference(at));

/// The state in a word, as the row's second line names it.
String stateWord(SourceRowState s) => switch (s) {
  SourceRowState.working => 'Working',
  SourceRowState.updating => 'Updating',
  SourceRowState.off => 'Off',
  SourceRowState.needsKey => 'Needs a key',
  SourceRowState.keyRejected => 'Key not accepted',
  SourceRowState.notAnswering => 'Not answering',
  SourceRowState.limitReached => 'Limit reached',
  SourceRowState.nothingHere => 'Nothing for this place',
};

/// The one sentence a problem state gets (null for a state with none), in the owner's approved words.
String? stateSentence(WeatherState w, Connector c, SourceRowState s) {
  final who = c.provider.isEmpty ? c.title : c.provider;
  switch (s) {
    case SourceRowState.needsKey:
      return '$who needs a free key.';
    case SourceRowState.keyRejected:
      return '$who no longer accepts the saved key.';
    case SourceRowState.notAnswering:
      final ago = _ago(w, w.healthOf(c)?.lastOkAt);
      return ago.isEmpty ? "$who didn't answer." : "$who didn't answer. Showing what Cache saved $ago.";
    case SourceRowState.limitReached:
      return '$who says it has reached its limit. Cache tries again later.';
    case SourceRowState.nothingHere:
      return c.coverage.isEmpty ? 'Your place is outside what this covers.' : 'Covers ${c.coverage}. Your place is outside it.';
    case SourceRowState.working || SourceRowState.updating || SourceRowState.off:
      return null;
  }
}

/// One source: its name, its state (and how old its data is), and its switch, or the one button its problem needs. A problem adds a
/// sentence. Tapping it opens the source's details (its key can be replaced or removed there).
class SourceRow extends StatelessWidget {
  const SourceRow({super.key, required this.deps, required this.source});

  final SettingsDeps deps;
  final Connector source;

  @override
  Widget build(BuildContext context) {
    final w = deps.hub.weather;
    final c = source;
    void open() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourcePage(deps: deps, sourceId: c.id)));
    final s = w.rowStateOf(c);
    final gives = c.description.isEmpty ? '' : '${c.description[0].toUpperCase()}${c.description.substring(1)}';
    return StateRow(
      id: c.id,
      icon: sourceIcon(c),
      title: c.title,
      gives: gives,
      state: s,
      ago: _ago(w, w.healthOf(c)?.lastOkAt),
      sentence: stateSentence(w, c, s),
      onSwitch: (v) => w.keyReady(c) ? w.setSourceOn(c, v) : addKeyFor(context, deps, c),
      onAddKey: () => addKeyFor(context, deps, c),
      onReplaceKey: () => addKeyFor(context, deps, c, replace: true),
      // just this source
      onTryAgain: () => w.updateSource(c),
      onTap: open,
    );
  }
}

/// How many sources (and web search) work, need attention and are off.
({int working, int attention, int off}) sourceCountsOf(SettingsDeps d) {
  final n = d.hub.weather.sourceCounts;
  return switch (d.hub.webSearch.rowState) {
    SourceRowState.off => (working: n.working, attention: n.attention, off: n.off + 1),
    final s when WeatherState.needsAttention(s) => (working: n.working, attention: n.attention + 1, off: n.off),
    _ => (working: n.working + 1, attention: n.attention, off: n.off),
  };
}

/// Web search (Kagi) in the same list: its state comes from its key, its switch and how the assistant's last search went. Tapping
/// the row opens the web search settings.
class WebSearchRow extends StatelessWidget {
  const WebSearchRow({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final web = deps.hub.webSearch;
    final s = web.rowState;
    return StateRow(
      id: 'web-search',
      icon: Icons.travel_explore,
      title: 'Web search',
      gives: 'Kagi searches the web for the assistant',
      state: s,
      sentence: switch (s) {
        SourceRowState.needsKey => 'Kagi needs a key.',
        SourceRowState.keyRejected => 'Kagi no longer accepts the saved key.',
        SourceRowState.limitReached => 'Kagi says it has reached its limit. Cache tries again later.',
        _ => null,
      },
      onSwitch: (v) => v && !web.hasKey ? setUpWebSearch(context, deps) : web.setEnabled(v),
      onAddKey: () => setUpWebSearch(context, deps),
      onReplaceKey: () => setUpWebSearch(context, deps),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AssistantPage(deps: deps))),
    );
  }
}

/// One row of the sources list for a state: the icon and name; line 2 the state (and "updated 12 min ago" while it works, or what an off
/// source gives); a problem adds its sentence; the switch, or the one button the problem needs, at the end.
class StateRow extends StatelessWidget {
  const StateRow({
    required this.id,
    required this.icon,
    required this.title,
    required this.state,
    this.gives = '',
    this.ago = '',
    this.sentence,
    this.onSwitch,
    this.onAddKey,
    this.onReplaceKey,
    this.onTryAgain,
    this.onTap,
  });

  /// The source's id (web search: web-search): the keys of the row and of its button are made from it.
  final String id;
  final IconData icon;
  final String title;
  final SourceRowState state;
  final String gives;
  final String ago;
  final String? sentence;
  final void Function(bool on)? onSwitch;
  final VoidCallback? onAddKey;
  final VoidCallback? onReplaceKey;
  final VoidCallback? onTryAgain;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = state;
    final problem = WeatherState.needsAttention(s) || s == SourceRowState.limitReached;
    // A problem row names its state only: its sentence says how old the saved data is, and the age does not fit beside the button.
    final line2 = switch (s) {
      SourceRowState.off => [Part(gives.isEmpty ? 'Off' : gives)],
      SourceRowState.working || SourceRowState.updating => [Part(stateWord(s)), if (ago.isNotEmpty) Part(' · updated $ago')],
      _ => [Part(stateWord(s), problem ? Tone.warn : Tone.quiet)],
    };
    final Widget? trailing = switch (s) {
      SourceRowState.working => Switch(value: true, onChanged: onSwitch),
      SourceRowState.off => Switch(value: false, onChanged: onSwitch),
      SourceRowState.updating => const SizedBox(width: 48, height: 48, child: Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2.5))),
      SourceRowState.needsKey => RowButton(key: ValueKey('add-key-$id'), label: 'Add key', onPressed: onAddKey),
      SourceRowState.keyRejected => RowButton(key: ValueKey('replace-key-$id'), label: 'Replace key', onPressed: onReplaceKey),
      SourceRowState.notAnswering => RowButton(key: ValueKey('try-again-$id'), label: 'Try again', onPressed: onTryAgain),
      SourceRowState.limitReached || SourceRowState.nothingHere => null,
    };
    return SettingsRow(
      key: ValueKey('source-$id'),
      leading: Icon(icon, size: 22, color: k.secondary),
      title: title,
      // A source's name takes two lines, so a phone shows it whole beside the switch.
      titleLines: 2,
      statusWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          statusText(context, line2, maxLines: s == SourceRowState.off ? 2 : 1),
          if (sentence != null) ...[
            const SizedBox(height: 2),
            statusText(context, [Part(sentence!, problem ? Tone.warn : Tone.quiet)], maxLines: 2),
          ],
        ],
      ),
      trailing: trailing,
      onTap: onTap,
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
            if (errors.isNotEmpty) CatalogueErrorNote(errors.first),
            if (own.isNotEmpty) SettingsGroup(label: 'Your own', rows: [for (final c in own) SourceRow(deps: d, source: c)]),
            AddOwnSourceRow(deps: d),
          ],
        );
      },
    );
  }
}

/// The one line at the top: how old the data is, turning into a warning when it is old (older than a reading stands, see
/// [WeatherState.status]), there is no connection or the last update failed, with a small round refresh button.
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

/// The top of the page: line 1 says how many sources need attention (a warning) or that all work, with how many are off; line 2 says
/// when Cache last checked; the refresh button. With no connection line 1 is the one notice for the whole list.
class SourcesStatusLine extends StatelessWidget {
  const SourcesStatusLine({super.key, required this.weather, required this.counts, required this.onRefresh});

  final WeatherState weather;
  final ({int working, int attention, int off}) counts;
  final VoidCallback onRefresh;

  /// "2 need attention · 1 off", "All 6 sources working", "1 off" with the ones that are on none of them.
  static String summary(({int working, int attention, int off}) n) {
    final head = n.attention > 0
        ? '${n.attention} need${n.attention == 1 ? 's' : ''} attention'
        : n.working == 0
        ? 'Nothing is on'
        : 'All ${n.working} ${n.working == 1 ? 'source' : 'sources'} working';
    return n.off > 0 && n.working + n.attention > 0 ? '$head · ${n.off} off' : head;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final w = weather;
    final n = counts;
    final offline = w.noNetwork;
    final warn = offline || n.attention > 0;
    final line1 = offline ? 'No connection. Showing what was saved.' : summary(n);
    final at = w.lastCheckedAt;
    final line2 = at == null ? 'Not checked yet' : 'Last checked ${agoWords(w.clockNow.difference(at))}';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (warn) ...[Icon(Icons.warning_amber_rounded, size: 18, color: k.warning), const SizedBox(width: 6)],
                  Expanded(
                    child: Text(
                      line1,
                      key: const ValueKey('status-headline'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: warn ? FontWeight.w500 : FontWeight.w400, color: warn ? k.warning : k.secondary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(line2, key: const ValueKey('status-checked'), style: TextStyle(fontSize: 13, color: k.secondary)),
            ],
          ),
        ),
        SizedBox(
          width: 48,
          height: 48,
          child: w.updating
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

/// A note about the list of sources. "Update Cache to use it" (a list in a newer format) goes to the update: the words point
/// there and link to it, when this build knows where its update is.
class CatalogueErrorNote extends StatelessWidget {
  const CatalogueErrorNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final go = text == kNewerCatalogueFormat ? updateCacheAction(context) : null;
    if (go == null) return NoteText(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NoteText(text),
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: LinkText('Update Cache', key: const ValueKey('update-cache-link'), onTap: go)),
      ],
    );
  }
}
