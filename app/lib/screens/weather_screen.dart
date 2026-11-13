import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/ask_about.dart';
import '../desktop/desktop.dart';
import '../desktop/weather_layout.dart';
import '../layout/adaptive.dart' show ContentWidth;
import '../maps/maps_state.dart' show shortAttribution;
import '../settings/app_settings.dart' show formatMinutes;
import '../settings/data_policy.dart' show ConnectionKind;
import '../theme.dart';
import '../weather/alert_watch.dart' show sameAlert;
import '../weather/connector.dart';
import '../weather/live_view.dart';
import '../weather/place_alerts.dart' show PlaceAlertRule;
import '../weather/place_summary.dart';
import '../weather/places.dart';
import '../weather/source_icon.dart';
import '../weather/weather_state.dart';
import '../weather/words.dart';
import 'home_screen.dart' show weatherIcon;
import 'settings/notifications_page.dart' show AlertGlyph;
import 'weather_turn_on.dart';

/// The Weather module, as a weather app shows a place, for every kind of event: the weather now and today at one watched place
/// (its name opens the list of all of them), what is happening near it with the most serious first, and the forecast day by
/// day. Everything shows at once from what is stored; nothing here is a setting. A thing that is happening opens with "Ask
/// about this".
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key, required this.weather, this.onAsk, this.onOpenSettings, this.turnOn});

  final WeatherState weather;

  /// "Turn on weather" and "Choose a place instead" in the empty states, and "Add a place" in Places; without it they only
  /// point to Settings.
  final WeatherTurnOn? turnOn;

  /// Starts a new chat about this item (Ask about this).
  final void Function(AskAbout about)? onAsk;

  /// Opens Settings > Weather and alerts.
  final VoidCallback? onOpenSettings;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

/// How many days the forecast lists before "All N days".
const int _daysListed = 7;

class _WeatherScreenState extends State<WeatherScreen> {
  List<WatchPlace>? _places;
  String? _placeId;

  /// What the core last answered for each place this screen asked about, by place id. Until it answers for a place, what the
  /// app kept of its last answer shows.
  final Map<String, List<SourceView>> _answers = {};

  /// Counts the core's answers, so Places (a sheet over this screen) redraws when one comes.
  final ValueNotifier<int> _answered = ValueNotifier<int>(0);
  int _seenRevision = -1;
  int _loads = 0;

  /// "All 16 days" was tapped: every day is listed.
  bool _allDays = false;

  WeatherState get w => widget.weather;

  @override
  void initState() {
    super.initState();
    w.addListener(_changed);
    w.focus.addListener(_onFocus);
    unawaited(_loadRules());
    _load().then((_) => _onFocus());
  }

  @override
  void dispose() {
    w.removeListener(_changed);
    w.focus.removeListener(_onFocus);
    _answered.dispose();
    super.dispose();
  }

  /// The places' own alert rules say how far out a fire is serious; they are in a small file, read once.
  Future<void> _loadRules() async {
    await w.placeAlerts?.load();
    if (mounted) setState(() {});
  }

  /// A tapped pop-up: show its place, then open its item when the data is there.
  Future<void> _onFocus() async {
    final f = w.focus.value;
    if (f == null || !mounted) return;
    w.focus.value = null;
    setState(() => _placeId = f.placeId);
    await _load();
    if (!mounted) return;
    // (a place that is no longer watched has nothing to open: it says the same)
    for (final v in _answers[f.placeId] ?? const <SourceView>[]) {
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

  /// What the page was last read for: an update, a source switched, and the fetch made for "Where I am" alone after it moved
  /// (that one changes no update time; without it the page kept saying nothing was downloaded for the new position).
  int get _revision => Object.hash(w.lastOkAt, w.enabledSources.length, w.updating, w.hereFetchedAt);

  void _changed() {
    if (_revision != _seenRevision && !w.updating) _load();
  }

  /// Reads the places and what is stored for the one on screen. Nothing is downloaded: the places and what was last shown for
  /// them show at once from what the app keeps (build 46: the page stayed empty for 9 s at start while the core was busy), and
  /// the core's answers replace them when they come.
  Future<void> _load() async {
    _seenRevision = _revision;
    final load = ++_loads;
    if (_places == null) {
      final now = w.watchedPlacesNow();
      if (now.isNotEmpty) {
        setState(() {
          _places = now;
          _pick(now);
        });
      }
    }
    final places = await w.watchedPlaces();
    if (!mounted) return;
    setState(() {
      _places = places;
      _pick(places);
    });
    final p = places.where((p) => p.id == _placeId).firstOrNull;
    if (p == null) return;
    final views = await w.viewFor(p);
    if (!mounted) return;
    setState(() => _answers[p.id] = views);
    _answered.value++;
    if (load == _loads) unawaited(_loadOthers(load, places, p.id));
  }

  /// The other watched places, after the one on screen: Places lists each one's temperature and worst event, and the top card
  /// says when something serious is at another place. One place at a time, from what the core has stored.
  Future<void> _loadOthers(int load, List<WatchPlace> places, String shown) async {
    for (final q in places) {
      if (q.id == shown) continue;
      final views = await w.viewFor(q);
      if (!mounted || load != _loads) return;
      setState(() => _answers[q.id] = views);
      _answered.value++;
    }
  }

  void _pick(List<WatchPlace> places) {
    if (_placeId == null || !places.any((p) => p.id == _placeId)) {
      _placeId = places.isEmpty ? null : places.firstWhere((p) => p.kind == PlaceKind.here, orElse: () => places.first).id;
    }
  }

  /// Shows another watched place.
  void _show(String placeId) {
    setState(() {
      _placeId = placeId;
      _allDays = false;
    });
    _load();
  }

  Future<void> _update() async {
    final r = await w.updateNow(force: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(r.words)));
    _load();
  }

  /// What the screen says about [p]: from the core's answer when it has come, else from what the app kept.
  PlaceSummary _summary(WatchPlace p) {
    final answered = _answers[p.id];
    return PlaceSummary.of(
      place: p,
      // a source switched off since the answer is not shown
      views: answered == null ? (w.keptViewFor(p) ?? const []) : [for (final v in answered) if (w.isOn(v.source.id)) v],
      enabled: w.enabledSources,
      clock: w.clockNow,
      rule: w.placeAlerts?.ruleFor(p.id) ?? PlaceAlertRule.same,
      pending: answered == null,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          final nothingOn = w.enabledSources.isEmpty;
          // On the Linux desktop an empty page is one centred card, which holds the status line too.
          final card = isLinuxDesktop(context) && (nothingOn || (places != null && places.isEmpty));
          // The whole-page states keep the status line above their words.
          List<Widget> whole(Widget words) => [
            if (!card) ...[
              _statusBox(context, w.status()),
              const SizedBox(height: 12),
            ],
            words,
          ];
          return RefreshIndicator(
            onRefresh: _update,
            child: LayoutBuilder(
              builder: (context, cts) => ListView(
                padding: weatherPadding(context, cts.maxWidth, centered: card),
                children: [
                  if (nothingOn)
                    ...whole(
                      widget.turnOn == null
                          ? _empty(context, 'Nothing is switched on yet.', 'Choose weather, alerts or fires in Settings > Weather and alerts.')
                          : _empty(context, 'Weather is off.', 'Get the forecast, weather alerts and wildfires for where you are.'),
                    )
                  else if (places == null)
                    ...whole(const SizedBox.shrink())
                  else if (places.isEmpty && w.waitingForPosition)
                    // "Where I am" is watched and the phone does not know where it is yet: weather is on, so this is not the
                    // "Turn on weather" page (which read as the settings), it is what Home's card says.
                    ...whole(_empty(context, 'Waiting for your position.', 'The forecast and alerts for where you are show here once the device knows where it is.', offerTurnOn: false))
                  else if (places.isEmpty)
                    ...whole(
                      widget.turnOn == null
                          ? _empty(context, 'No place is being watched.', 'Choose places under Settings > Weather and alerts > Places.')
                          : _empty(context, 'No place is being watched.', 'Use where you are, or choose a place.'),
                    )
                  else
                    _page(context, places),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- the page for one place

  Widget _page(BuildContext context, List<WatchPlace> places) {
    final p = places.where((p) => p.id == _placeId).firstOrNull ?? places.first;
    final s = _summary(p);
    final plain = _plainLine(s);
    final nearby = _nearby(context, s);
    final forecast = _forecast(context, s);
    final credits = _credits(context, s);
    return WeatherColumns(
      top: [
        _topCard(context, s, places),
        if (plain != null) _plain(context, plain),
      ],
      nearby: [?nearby],
      below: [
        ?forecast,
        if (s.otherWeather.isNotEmpty) Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _tiles([for (final v in s.otherWeather) _sourceRow(context, v)])),
        ?credits,
      ],
    );
  }

  TextStyle _heading(CacheTokens k) => TextStyle(fontSize: 13, letterSpacing: 0.6, color: k.secondary);

  /// A heading over its rows, 6 apart.
  Widget _section(BuildContext context, String heading, List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(padding: const EdgeInsets.only(left: 2, top: 2), child: Text(heading, style: _heading(context.t))),
      const SizedBox(height: 6),
      ...rows,
    ],
  );

  /// Rows stacked tight, as a Settings group is: round on the outer corners, 2 apart.
  List<Widget> _tiles(List<_Entry> rows) => [
    for (var n = 0; n < rows.length; n++) _Tile(key: rows[n].key, first: n == 0, last: n == rows.length - 1, onTap: rows[n].onTap, child: rows[n].child),
  ];

  // ---------------------------------------------------------------- the top card

  Widget _topCard(BuildContext context, PlaceSummary s, List<WatchPlace> places) {
    final k = context.t;
    final fresh = w.freshness();
    final warn = fresh.tone == StatusTone.warn;
    final elsewhere = _seriousElsewhere(s, places);
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The place's name opens Places.
            InkWell(
              key: const ValueKey('weather-place'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openPlaces(context),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(s.place.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text))),
                    const SizedBox(width: 2),
                    Icon(Icons.keyboard_arrow_down, size: 22, color: k.secondary),
                  ],
                ),
              ),
            ),
            if (elsewhere != null)
              InkWell(
                key: const ValueKey('weather-serious-elsewhere'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _show(elsewhere.$1.id),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6, right: 8),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: k.emergency),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Serious at ${elsewhere.$1.name}: ${elsewhere.$2.item.label}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, height: 1.3, fontWeight: FontWeight.w600, color: k.emergency),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ..._now(context, s),
            // How fresh it all is, and Update now. A warning only for a reason that can be named, with its mark as well as its colour.
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  if (warn) ...[Icon(Icons.warning_amber_rounded, size: 18, color: k.warning), const SizedBox(width: 6)],
                  Expanded(
                    child: Text(fresh.headline, key: const ValueKey('weather-freshness'), style: TextStyle(fontSize: 13, height: 1.35, color: warn ? k.warning : k.secondary)),
                  ),
                  TextButton(
                    key: const ValueKey('weather-update-now'),
                    onPressed: w.updating ? null : _update,
                    child: Text(w.updating ? 'Updating…' : 'Update now'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The weather now and today, or what is not known of it.
  List<Widget> _now(BuildContext context, PlaceSummary s) {
    final k = context.t;
    Widget words(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 6),
      child: Text(text, key: const ValueKey('weather-no-forecast'), style: TextStyle(fontSize: 15, color: k.secondary)),
    );
    final open = widget.onOpenSettings;
    if (!s.forecastOn) {
      return [
        InkWell(
          key: const ValueKey('weather-forecast-off'),
          borderRadius: BorderRadius.circular(8),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
            child: Row(
              children: [
                Expanded(child: Text('No forecast is switched on', style: TextStyle(fontSize: 15, color: k.secondary))),
                if (open != null) Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ];
    }
    final main = s.forecast;
    final reading = s.reading;
    final period = s.now ?? s.days.firstOrNull;
    if (main != null && reading != null) return _reading(context, s, main, reading);
    if (main != null && period != null) return _period(context, s, main, period);
    if (s.forecastExpired) return [words('Forecast expired, needs a connection')];
    // The core has not said yet what it holds, and nothing is kept: not known, which is not "none".
    if (main == null && s.pending) {
      return const [
        Padding(padding: EdgeInsets.fromLTRB(0, 8, 8, 8), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
      ];
    }
    return [words(main == null ? 'No forecast yet' : 'No forecast.')];
  }

  /// A reading: the temperature at size, the conditions, and four facts of now and today.
  List<Widget> _reading(BuildContext context, PlaceSummary s, SourceView main, LiveItem reading) {
    final k = context.t;
    final conditions = conditionsOf(reading);
    final temperature = reading.fields['Temperature'];
    final feels = reading.fields['Feels like'];
    final taken = placeClock(reading.time) ?? placeClock(main.fetchedAt);
    final day = s.now;
    final facts = <(String, String)>[];
    void add(String? name, String? value) {
      if (name != null && value != null && !facts.any((f) => f.$1 == name)) facts.add((name, value));
    }

    // today's high and low, the wind now, the chance of rain: under the source's own names
    if (day != null) {
      add(highNameOf(day), highOf(day));
      add(lowNameOf(day), lowOf(day));
    }
    add('Wind', reading.fields['Wind']);
    if (day != null) add(rainNameOf(day), rainOf(day));
    // a source with other names fills the places that are left, in its own order
    for (final e in [...reading.fields.entries, ...?day?.fields.entries]) {
      if (facts.length >= 4) break;
      if (_shownAbove.contains(e.key) || LiveItem.isDistance(e.key) || _isZero(e.value) || e.value.length > _factChars) continue;
      add(e.key, e.value);
    }
    return [
      if (s.readingIsOld(w.clockNow) && taken != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text('As of ${clockWords(taken, s.today)}', key: const ValueKey('weather-as-of'), style: TextStyle(fontSize: 13, color: k.secondary)),
        ),
      InkWell(
        key: const ValueKey('weather-now'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openItem(context, main, reading),
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
          child: Row(
            children: [
              if (conditions != null) ...[Icon(weatherIcon(conditions), size: 46, color: k.text), const SizedBox(width: 10)],
              if (temperature != null) ...[
                // at its size while it fits half of the row; a long reading (or large type) is drawn smaller, never cut
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(temperature, key: const ValueKey('weather-temperature'), style: TextStyle(fontSize: 52, fontWeight: FontWeight.w300, height: 1.05, color: k.text)),
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (conditions != null)
                      Text(lineStart(conditions), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, height: 1.25, color: k.text)),
                    if (feels != null) Text('Feels like $feels', style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      if (facts.isNotEmpty) _facts(context, facts.take(4).toList()),
    ];
  }

  /// No reading: the forecast for the period that covers now, with no temperature for now, because none is known.
  List<Widget> _period(BuildContext context, PlaceSummary s, SourceView main, LiveItem period) {
    final k = context.t;
    final conditions = conditionsOf(period);
    final big = <(String, String)>[];
    final rest = <(String, String)>[];
    final highName = highNameOf(period), lowName = lowNameOf(period), rainName = rainNameOf(period);
    if (highName != null) big.add((highName, highOf(period)!));
    if (lowName != null) big.add((lowName, lowOf(period)!));
    // the period's other values, in the source's order; the ones that are zero say nothing ("Snow 0.0 in" on a dry day)
    for (final e in period.fields.entries) {
      if (e.key == highName || e.key == lowName || _shownAbove.contains(e.key) || LiveItem.isDistance(e.key) || e.value.length > _factChars) continue;
      if (e.key != rainName && _isZero(e.value)) continue;
      rest.add((e.key, e.value));
    }
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          s.isToday(period) ? 'Forecast for today, ${period.label}' : 'Forecast for ${period.label}',
          key: const ValueKey('weather-forecast-for'),
          style: TextStyle(fontSize: 13, color: k.secondary),
        ),
      ),
      if (conditions != null)
        InkWell(
          key: const ValueKey('weather-now'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openItem(context, main, period),
          child: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
            child: Row(
              children: [
                Icon(weatherIcon(conditions), size: 38, color: k.text),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(lineStart(conditions), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.2, color: k.text)),
                ),
              ],
            ),
          ),
        ),
      if (big.isNotEmpty) _facts(context, big, big: true),
      if (rest.isNotEmpty) _facts(context, rest.take(big.isEmpty ? 6 : 4).toList()),
    ];
  }

  /// What the top card already says in words of its own, so it is not repeated among the facts.
  static const Set<String> _shownAbove = {'Temperature', 'Feels like', 'Conditions', 'Sky', 'Summary'};

  /// The longest value a fact may have: a sentence (a period's written forecast) belongs in the detail, not in a column.
  static const int _factChars = 40;

  /// Facts in two columns, a small name over each value ([big]: the value at the size of a temperature).
  Widget _facts(BuildContext context, List<(String, String)> facts, {bool big = false}) {
    final k = context.t;
    Widget fact((String, String) f) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(f.$1, style: TextStyle(fontSize: 12, color: k.secondary)),
        const SizedBox(height: 1),
        Text(
          f.$2,
          style: big ? TextStyle(fontSize: 30, fontWeight: FontWeight.w300, height: 1.1, color: k.text) : TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 8),
      child: Column(
        children: [
          for (var n = 0; n < facts.length; n += 2)
            Padding(
              padding: EdgeInsets.only(top: n == 0 ? 0 : 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: fact(facts[n])),
                  const SizedBox(width: 16),
                  Expanded(child: n + 1 < facts.length ? fact(facts[n + 1]) : const SizedBox.shrink()),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A value that starts with a number equal to zero, like "0.0 in over 0 h" or "0%".
  static bool _isZero(String v) {
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)').firstMatch(v);
    return m != null && double.parse(m.group(1)!) == 0;
  }

  /// Something serious at another watched place that the place on screen does not list: that place and the event; else null.
  (WatchPlace, NearbyEvent)? _seriousElsewhere(PlaceSummary here, List<WatchPlace> places) {
    final listed = here.nearby.ranked;
    for (final q in places) {
      if (q.id == here.place.id) continue;
      for (final e in _summary(q).nearby.serious) {
        final warning = e.kind == NearbyKind.warning;
        final same = listed.any((x) => sameAlert(x.item, here.place, x.kind == NearbyKind.warning, e.item, q, warning, sourceA: x.view.source.id, sourceB: e.view.source.id));
        if (!same) return (q, e);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- the one plain line

  /// The one line under the top card, only while something a person relies on is not updating, has no key, or no alert source
  /// is on. It names the source, because that is what the person has to act on; why, and the key, are in Settings.
  String? _plainLine(PlaceSummary s) {
    // Without a connection nothing updates, and the top card's own line says so.
    if (w.connection != ConnectionKind.none && !s.pending) {
      final failed = [
        for (final v in s.views)
          if (w.keyReady(v.source) && (v.error != null || w.sourceErrors.containsKey(v.source.id))) v,
      ];
      if (failed.length == 1) {
        final v = failed.single;
        final at = v.missing ? null : DateTime.tryParse(v.fetchedAt?.trim() ?? '');
        return at == null ? '${v.source.title} has not updated' : '${v.source.title} has not updated since ${_since(at.toLocal(), w.clockNow)}';
      }
      if (failed.length > 1) return '${failed.length} sources have not updated: ${failed.map((v) => v.source.title).join(', ')}';
    }
    final keyless = [for (final c in w.enabledSources) if (!w.keyReady(c)) c];
    if (keyless.length == 1) return '${keyless.single.title} needs a key';
    if (keyless.length > 1) return '${keyless.length} sources need a key: ${keyless.map((c) => c.title).join(', ')}';
    if (!s.alertsOn) return 'Alerts and fires are not switched on';
    return null;
  }

  /// "2:14 PM" for earlier today, else "yesterday", "Friday", "Oct 12".
  static String _since(DateTime then, DateTime now) =>
      then.year == now.year && then.month == now.month && then.day == now.day ? formatMinutes(then.hour * 60 + then.minute) : dayWords(then, now);

  Widget _plain(BuildContext context, String text) {
    final k = context.t;
    final open = widget.onOpenSettings;
    return InkWell(
      key: const ValueKey('weather-plain-line'),
      borderRadius: BorderRadius.circular(8),
      onTap: open,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: k.warning),
            const SizedBox(width: 6),
            Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.35, color: k.warning))),
            if (open != null) Icon(Icons.chevron_right, color: k.warning),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- Happening nearby

  /// "No alerts or fires nearby", naming only the kinds that were checked.
  String _calmWords(PlaceSummary s) => s.warningsChecked && s.firesChecked ? 'No alerts or fires nearby' : (s.warningsChecked ? 'No alerts nearby' : 'No fires nearby');

  /// What the list says when the last check of alerts and fires is too old to speak for now.
  String _tooOldWords(PlaceSummary s) {
    final at = s.checkedAt;
    if (at == null) return 'Needs a connection for anything newer.';
    final last = 'Last checked ${agoWords(w.clockNow.difference(at))}.';
    return w.connection == ConnectionKind.none ? '$last Needs a connection for anything newer.' : last;
  }

  /// "Happening nearby": one list, the most serious first; null when there is nothing to say (no source of events is on).
  Widget? _nearby(BuildContext context, PlaceSummary s) {
    final k = context.t;
    final n = s.nearby;
    final rows = <_Entry>[];
    if (s.calm) {
      final at = s.checkedAt;
      rows.add(_Entry(
        key: const ValueKey('weather-calm'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, size: 22, color: k.ok),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_calmWords(s), style: TextStyle(fontSize: 15, color: k.text)),
                    if (at != null) Text('Checked ${agoWords(w.clockNow.difference(at))}', style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
    } else if (s.notChecked && !s.pending) {
      rows.add(_Entry(
        key: const ValueKey('weather-not-checked'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text('Not checked yet', style: TextStyle(fontSize: 15, color: k.secondary)),
        ),
      ));
    }
    for (final e in [...n.serious, ...n.warnings, ...n.fires.take(kFiresListed)]) {
      rows.add(_eventRow(context, s, e));
    }
    final more = n.moreFires;
    if (more.isNotEmpty) {
      final title = more.length == 1 ? '1 more fire' : '${more.length} more fires';
      rows.add(_Entry(
        key: const ValueKey('weather-more-fires'),
        onTap: () => _openList(context, title: title, entries: [for (final e in more) for (final i in e.same.isEmpty ? [e.item] : e.same) (i, e.view)]),
        child: _rowBody(context, glyph: AlertGlyph(sourceIcon(more.first.view.source), color: k.warning, size: 36), title: title, tappable: true),
      ));
    }
    for (final e in n.ruled) {
      rows.add(_eventRow(context, s, e));
    }
    for (final v in n.sources) {
      rows.add(_sourceRow(context, v));
    }
    if (rows.isEmpty && !s.tooOld) return null;
    return _section(context, 'Happening nearby', [
      if (s.tooOld)
        Padding(
          key: const ValueKey('weather-too-old'),
          padding: EdgeInsets.fromLTRB(2, 0, 2, rows.isEmpty ? 0 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.warning_amber_rounded, size: 18, color: k.warning)),
              const SizedBox(width: 6),
              Expanded(child: Text(_tooOldWords(s), style: TextStyle(fontSize: 14, height: 1.35, color: k.warning))),
            ],
          ),
        ),
      ..._tiles(rows),
    ]);
  }

  /// "until 11 PM", "until Thu 9 PM": when an alert ends, from its "Expires" on the place's own clock; null when it gives none.
  static String? _until(LiveItem i, DateTime today) {
    final at = placeClock(i.fields['Expires']);
    return at == null ? null : 'until ${clockWords(at, today)}';
  }

  /// A row's glyph, name and lines, with a chevron when it opens something.
  Widget _rowBody(BuildContext context, {required Widget glyph, required String title, Color? titleColor, List<Widget> lines = const [], required bool tappable}) {
    final k = context.t;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            glyph,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // an emergency alert's name is its headline, up to 120 characters: four lines hold it whole on a phone
                  Text(title, maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.25, color: titleColor ?? k.text)),
                  for (final l in lines) Padding(padding: const EdgeInsets.only(top: 2), child: l),
                ],
              ),
            ),
            if (tappable) ...[const SizedBox(width: 6), Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8))],
          ],
        ),
      ),
    );
  }

  /// One ranked event: what it is, how serious, until when and where. Colour is never the only sign of how serious it is: the
  /// service's own word or the distance is written too, and serious events are listed first.
  _Entry _eventRow(BuildContext context, PlaceSummary s, NearbyEvent e) {
    final k = context.t;
    final i = e.item;
    final small = TextStyle(fontSize: 13, height: 1.35, color: k.secondary);
    // how serious, in the emergency colour and a heavier weight: a sign that does not rest on the colour alone
    final strong = e.serious ? TextStyle(color: k.emergency, fontWeight: FontWeight.w600) : null;
    final lines = <Widget>[];
    final rest = [?i.distance, if (i.summary.isNotEmpty) i.summary].join(' · ');
    switch (e.kind) {
      case NearbyKind.warning:
        final severity = e.severity;
        final until = _until(i, s.today);
        final by = i.fields['Issued by'];
        final where = by != null ? 'Issued by $by' : i.fields['Area'];
        if (severity != null || until != null) {
          lines.add(Text.rich(
            TextSpan(
              children: [
                if (severity != null) TextSpan(text: lineStart(severity), style: strong),
                if (severity != null && until != null) const TextSpan(text: ' · '),
                if (until != null) TextSpan(text: until),
              ],
            ),
            style: small,
          ));
        }
        if (where != null) lines.add(Text(where, maxLines: 2, overflow: TextOverflow.ellipsis, style: small));
        if (lines.isEmpty && rest.isNotEmpty) lines.add(Text(rest, maxLines: 2, overflow: TextOverflow.ellipsis, style: small));
      case NearbyKind.fire:
        final distance = i.distance;
        final summary = i.summary;
        final parts = e.same.length > 1
            ? [
                TextSpan(text: '${e.same.length} listed'),
                if (distance != null) TextSpan(text: 'nearest $distance', style: strong),
              ]
            : [
                if (distance != null) TextSpan(text: distance, style: strong),
                if (summary.isNotEmpty) TextSpan(text: summary),
              ];
        if (parts.isNotEmpty) {
          lines.add(Text.rich(
            TextSpan(
              children: [
                for (var n = 0; n < parts.length; n++) ...[
                  if (n > 0) const TextSpan(text: ' · '),
                  parts[n],
                ],
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: small,
          ));
        }
      case NearbyKind.other:
        if (rest.isNotEmpty) lines.add(Text(rest, maxLines: 2, overflow: TextOverflow.ellipsis, style: small));
    }
    // A check too old to speak for now: what was known is listed with when it was known.
    final asOf = e.view.expired ? placeClock(e.view.fetchedAt) : null;
    if (asOf != null) lines.add(Text('As of ${clockWords(asOf, s.today)}', style: small));
    final fill = e.serious ? k.emergency : (e.kind == NearbyKind.other ? null : k.warning);
    return _Entry(
      key: ValueKey('weather-event-${i.address}'),
      onTap: e.same.length > 1 ? () => _openList(context, title: i.label, entries: [for (final x in e.same) (x, e.view)]) : () => _openItem(context, e.view, i),
      child: _rowBody(
        context,
        glyph: AlertGlyph(sourceIcon(e.view.source), color: fill, size: 36),
        title: i.label,
        titleColor: e.serious ? k.emergency : null,
        lines: lines,
        tappable: true,
      ),
    );
  }

  String _ageLine(SourceView v) {
    if (v.missing) return v.error != null ? 'Not downloaded: ${v.error}' : 'Not downloaded yet. Update now to get it.';
    final a = v.age == null ? '' : v.age!;
    if (v.expired) return 'Expired${a.isEmpty ? '' : ' · $a'} · needs a connection for more';
    return a;
  }

  /// One row for a whole source: a kind the app has no way to rank, or a weather source other than the one in the top card. Its
  /// name, how many items it lists and its first one; it opens its items.
  _Entry _sourceRow(BuildContext context, SourceView v) {
    final k = context.t;
    final active = v.active;
    final first = active.firstOrNull;
    final String line;
    if (v.missing || v.expired) {
      line = _ageLine(v);
    } else if (first == null) {
      line = 'None active';
    } else if (active.length == 1) {
      line = [if (first.label != v.source.title) first.label, ?first.distance, if (first.summary.isNotEmpty) first.summary].join(' · ');
    } else {
      line = '${active.length} listed · ${first.label}';
    }
    final VoidCallback? onTap;
    if (v.missing) {
      onTap = null;
    } else if (first != null && active.length == 1) {
      onTap = () => _openItem(context, v, first);
    } else {
      onTap = () => _openList(context, title: v.source.title, note: [v.place.name, ?v.age].join(' · '), entries: [for (final i in active) (i, v)]);
    }
    return _Entry(
      key: ValueKey('weather-source-${v.source.id}'),
      onTap: onTap,
      child: _rowBody(
        context,
        glyph: AlertGlyph(sourceIcon(v.source), size: 36),
        title: v.source.title,
        lines: [
          if (line.isNotEmpty) Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.35, color: v.missing || v.expired ? k.warning : k.secondary)),
        ],
        tappable: onTap != null,
      ),
    );
  }

  // ---------------------------------------------------------------- the forecast

  /// The days, one line each: the first [_daysListed], then all of them. Null when no forecast is stored (the top card says so).
  Widget? _forecast(BuildContext context, PlaceSummary s) {
    final k = context.t;
    final main = s.forecast;
    if (main == null) return null;
    final days = s.days;
    if (days.isEmpty) {
      if (!s.forecastExpired) return null;
      return _section(context, 'Forecast', [
        Material(
          color: k.surface,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text('Every day of this forecast has passed.', style: TextStyle(fontSize: 15, color: k.secondary)),
          ),
        ),
      ]);
    }
    // a column only for a value some day has; a day without it shows a dash, never an empty place
    final rain = days.any((i) => rainOf(i) != null), high = days.any((i) => highOf(i) != null), low = days.any((i) => lowOf(i) != null);
    final shown = _allDays ? days : days.take(_daysListed).toList();
    final more = !_allDays && days.length > _daysListed;
    final offline = w.connection == ConnectionKind.none;
    final cap = TextStyle(fontSize: 12, color: k.secondary);
    // a narrow phone keeps every column and gives the conditions' words what is left
    final narrow = MediaQuery.sizeOf(context).width < 380;
    const rainWidth = 40.0;
    final nameWidth = narrow ? 84.0 : 94.0, tempWidth = narrow ? 50.0 : 54.0;
    Widget cell(String? value, double width, TextStyle style) => SizedBox(width: width, child: Text(value ?? '–', textAlign: TextAlign.right, maxLines: 1, style: style));
    return _section(context, 'Forecast', [
      Material(
        color: k.surface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rain || high || low)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (rain) cell('Rain', rainWidth, cap),
                    if (high) cell('High', tempWidth, cap),
                    if (low) cell('Low', tempWidth, cap),
                  ],
                ),
              )
            else
              const SizedBox(height: 6),
            for (final i in shown)
              InkWell(
                key: ValueKey('weather-day-${i.address}'),
                onTap: () => _openItem(context, main, i),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: nameWidth,
                          child: Text(s.isToday(i) ? 'Today' : i.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                        ),
                        if (conditionsOf(i) case final c?) ...[
                          Icon(weatherIcon(c), size: 22, color: k.text),
                          const SizedBox(width: 8),
                          // "Thunderstorm with heavy hail" takes two lines; one line would cut it
                          Expanded(child: Text(lineStart(c), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.25, color: k.secondary))),
                        ] else
                          const Spacer(),
                        if (rain) cell(rainOf(i), rainWidth, TextStyle(fontSize: 13, color: k.secondary)),
                        if (high) cell(highOf(i), tempWidth, TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                        if (low) cell(lowOf(i), tempWidth, TextStyle(fontSize: 15, color: k.secondary)),
                      ],
                    ),
                  ),
                ),
              ),
            if (more || offline)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 2, 0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      // How far the stored forecast runs matters only while it cannot be renewed.
                      Expanded(
                        child: offline
                            ? Text('Stored through ${days.last.label}', key: const ValueKey('weather-stored-through'), style: TextStyle(fontSize: 13, color: k.secondary))
                            : const SizedBox.shrink(),
                      ),
                      if (more)
                        TextButton(
                          key: const ValueKey('weather-all-days'),
                          onPressed: () => setState(() => _allDays = true),
                          child: Text('All ${days.length} days'),
                        ),
                    ],
                  ),
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- credits

  /// One small line crediting every source whose data is shown, as the map credits its own; it opens the credits in full.
  Widget? _credits(BuildContext context, PlaceSummary s) {
    final k = context.t;
    final shown = [for (final v in s.views) if (!v.missing && v.source.attribution.isNotEmpty) v.source];
    if (shown.isEmpty) return null;
    // the forecast of the top card first: its data leads the page, and its license asks for the credit
    final main = s.forecast?.source;
    final sources = [
      for (final c in shown) if (identical(c, main)) c,
      for (final c in shown) if (!identical(c, main)) c,
    ];
    final lines = <String>[];
    for (final c in sources) {
      final line = _shortCredit(c.attribution);
      if (!lines.contains(line)) lines.add(line);
    }
    return Semantics(
      button: true,
      label: 'Weather credits',
      child: InkWell(
        key: const ValueKey('weather-credits'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openCredits(context, sources),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(lines.join(' · '), style: TextStyle(fontSize: 10.5, height: 1.3, color: k.secondary))),
              const SizedBox(width: 6),
              Icon(Icons.info_outline, size: 15, color: k.secondary),
            ],
          ),
        ),
      ),
    );
  }

  /// A credit in the map's short form ([shortAttribution]: its first sentence, at most 80 characters). Where that cut a long
  /// sentence inside a word, the cut moves back to the end of the word before.
  static String _shortCredit(String credit) {
    final short = shortAttribution(credit);
    if (!short.endsWith('…')) return short;
    final space = short.lastIndexOf(' ');
    return space < 40 ? short : '${short.substring(0, space)}…';
  }

  void _openCredits(BuildContext context, List<Connector> sources) {
    final k = context.t;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (ctx) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shrinkWrap: true,
          children: [
            Text('Weather credits', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final c in sources) ...[
              Text(c.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
              Text(c.attribution, style: TextStyle(fontSize: 15, color: k.text)),
              if (c.license.isNotEmpty) Text(c.license, style: TextStyle(fontSize: 14, color: k.secondary)),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- Places

  /// Places: every watched place with its temperature and the worst thing happening there. Tapping one shows it.
  void _openPlaces(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(listenable: Listenable.merge([w, _answered]), builder: (ctx, _) => _placesList(ctx)),
      ),
    );
  }

  Widget _placesList(BuildContext ctx) {
    final k = ctx.t;
    final t = widget.turnOn;
    return ListView(
      key: const ValueKey('weather-places'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text('Places', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
        ),
        for (final p in _places ?? const <WatchPlace>[]) _placeRow(ctx, p),
        if (t != null)
          InkWell(
            key: const ValueKey('weather-add-place'),
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Navigator.pop(ctx);
              _addPlace(t);
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 26, color: k.accent),
                    const SizedBox(width: 14),
                    Flexible(child: Text('Add a place', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.accent))),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// "Add a place": the Choose a place sheet. The place is watched; the sources stay as the person has them.
  Future<void> _addPlace(WeatherTurnOn t) async {
    await chooseWeatherPlace(context, t, switchOn: false);
    if (mounted) _load();
  }

  /// The worst thing happening at a place, in one line: its name, how many more are ranked after it (" · +4 more", or null),
  /// and whether it is serious. When nothing is listed, what is known instead.
  (String, String?, bool) _worst(PlaceSummary s) {
    final ranked = s.nearby.ranked;
    final first = ranked.firstOrNull;
    if (first != null) return (first.item.label, ranked.length == 1 ? null : ' · +${ranked.length - 1} more', first.serious);
    // nothing kept and no answer yet is not known, which is not "nothing downloaded"
    if (!s.anyStored) return (s.pending ? kWeatherStarting : 'Nothing downloaded yet', null, false);
    if (s.tooOld) return (_tooOldWords(s), null, false);
    if (s.calm) return (_calmWords(s), null, false);
    if (!s.alertsOn) return ('Alerts and fires are not switched on', null, false);
    return (s.pending ? kWeatherStarting : 'Not checked yet', null, false);
  }

  Widget _placeRow(BuildContext ctx, WatchPlace p) {
    final k = ctx.t;
    final s = _summary(p);
    final conditions = conditionsOf(s.reading) ?? conditionsOf(s.now);
    final temperature = s.reading?.fields['Temperature'];
    final (line, more, serious) = _worst(s);
    final worst = TextStyle(fontSize: 13, height: 1.35, color: serious ? k.emergency : k.secondary);
    return InkWell(
      key: ValueKey('weather-place-${p.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.pop(ctx);
        _show(p.id);
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // the conditions there; a place whose conditions are not known gets the place mark, not a made-up sky
              Icon(conditions == null ? Icons.place_outlined : weatherIcon(conditions), size: 26, color: k.secondary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: k.text))),
                        if (p.id == _placeId) ...[const SizedBox(width: 6), Icon(Icons.check, size: 18, color: k.accent)],
                      ],
                    ),
                    const SizedBox(height: 2),
                    // a long name gives way; how many more there are stays in sight
                    Row(
                      children: [
                        Flexible(child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: worst)),
                        if (more != null) Text(more, maxLines: 1, style: worst),
                      ],
                    ),
                  ],
                ),
              ),
              if (temperature != null) ...[
                const SizedBox(width: 10),
                Text(temperature, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300, color: k.text)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- the whole-page states

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

  Widget _empty(BuildContext context, String a, String b, {bool offerTurnOn = true}) {
    final k = context.t;
    // The words and the buttons keep to a narrow column, centred, on a wide window.
    // (On the Linux desktop the heading and the words are left-aligned and the buttons sit in a row.)
    final desk = isLinuxDesktop(context);
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: ContentWidth(
        maxWidth: 440,
        child: Column(
        crossAxisAlignment: desk ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(a, textAlign: desk ? TextAlign.start : TextAlign.center, style: TextStyle(fontSize: 18, color: k.text)),
          const SizedBox(height: 6),
          Text(b, textAlign: desk ? TextAlign.start : TextAlign.center, style: TextStyle(fontSize: 15, color: k.secondary)),
          if (widget.turnOn case final t? when offerTurnOn) ...[
            const SizedBox(height: 16),
            WeatherTurnOnButtons(turnOn: t, inline: desk),
          ],
          if (widget.onOpenSettings != null) ...[
            const SizedBox(height: 12),
            widget.turnOn == null
                ? OutlinedButton(onPressed: widget.onOpenSettings, child: const Text('Open Weather and alerts settings'))
                : TextButton(
                    // On the desktop the button's text starts at the buttons' left edge.
                    style: desk ? TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0)) : null,
                    onPressed: widget.onOpenSettings,
                    child: const Text('Open Weather and alerts settings')),
          ],
        ],
        ),
      ),
    );
    return isLinuxDesktop(context) ? WeatherEmptyCard(status: _statusBox(context, w.status()), child: body) : body;
  }

  // ---------------------------------------------------------------- the sheets an item opens

  /// The items behind one row (a source's, the fires after the nearest few, the items that share a name); each opens as any
  /// other item does.
  void _openList(BuildContext context, {required String title, String? note, required List<(LiveItem, SourceView)> entries}) {
    final k = context.t;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleLarge),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(note, style: TextStyle(fontSize: 14, color: k.secondary)),
            ],
            const SizedBox(height: 8),
            if (entries.isEmpty) Text('None active', style: TextStyle(fontSize: 15, color: k.secondary)),
            for (final (i, v) in entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: 56,
                title: Text(i.label, style: const TextStyle(fontSize: 16)),
                subtitle: Text([?i.distance, if (i.summary.isNotEmpty) i.summary].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openItem(context, v, i),
              ),
          ],
        ),
      ),
    );
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
                    widget.onAsk!(AskAbout(sourceTitle: v.source.title, sourceId: v.source.id, place: v.place.name, label: i.label));
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

/// One row of a group of the Weather screen: what it shows, and what a tap does.
class _Entry {
  const _Entry({required this.child, this.key, this.onTap});

  final Key? key;
  final VoidCallback? onTap;
  final Widget child;
}

/// A row of a group, drawn as a Settings row is: the card's colour, round on the group's outer corners, 2 under the row before.
class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.first, required this.last, required this.child, this.onTap});

  final bool first;
  final bool last;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 2),
      child: Material(
        color: context.t.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(first ? 16 : 4), bottom: Radius.circular(last ? 16 : 4)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: child),
      ),
    );
  }
}
