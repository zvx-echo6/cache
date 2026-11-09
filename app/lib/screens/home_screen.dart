import 'dart:async';

import 'package:flutter/material.dart';

import '../brand.dart';
import '../discover/discover_state.dart';
import '../discover/ui/home_card.dart';
import '../layout/edit_home_screen.dart';
import '../layout/layout_state.dart';
import '../layout/modules.dart' show ModuleId;
import '../search/app_search.dart';
import 'hold.dart';
import 'settings/widgets.dart' show GroupLabel;
import '../theme.dart';
import '../update/update_ui.dart';
import '../weather/weather_state.dart';
import '../weather/words.dart' show lineStart;
import 'setup_card.dart';
import 'weather_turn_on.dart';
import '../layout/adaptive.dart' show showFittedSheet, ContentWidth, isShort, kRegularWidth;

/// Home: the blocks the person chose, in the order they chose (Set up Cache while it is not done, the search box, Weather and alerts,
/// Shortcuts by default), a gear for Settings at the top right, and "Edit Home" at the bottom. The search box searches all of Cache;
/// its first row always asks Cache exactly what was typed. With no model on this device ([askOn] false) the box is search only:
/// "Search Cache", results as you type, no Ask row, and a shortcut to the Ask module is not drawn.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.layout,
    required this.onAsk,
    required this.onOpenSettings,
    required this.onOpenShortcut,
    this.search,
    this.searchFootnote,
    this.weather,
    this.onOpenWeather,
    this.turnOn,
    this.setup,
    this.updates,
    this.onOpenWeatherSettings,
    this.askOn = true,
    this.onChooseModel,
    this.discover,
    this.onOpenDiscover,
  });

  /// Discover: once its first run is done, its card takes the Set up card's place (the same Home block); null keeps Set up Cache.
  final DiscoverState? discover;

  /// Opens Discover from its card.
  final VoidCallback? onOpenDiscover;

  /// Ask is available (a chat model is on this device). False: search only.
  final bool askOn;

  /// "Choose a model" under a search that found nothing, with no model on this device; null leaves it out.
  final VoidCallback? onChooseModel;

  /// "Turn on" on the Weather card when every source is off: Settings > Weather and alerts.
  final VoidCallback? onOpenWeatherSettings;

  /// The iPhone's "New version available" banner at the top; null leaves it out.
  final AppUpdates? updates;

  /// The "Set up Cache" block; null leaves it out.
  final SetupCache? setup;

  /// "Turn on weather" on the Weather and alerts card while weather is not set up (and Set up Cache is not showing it).
  final WeatherTurnOn? turnOn;

  /// Feeds the Weather and alerts card; without it the card says "Not set up yet".
  final WeatherState? weather;
  final VoidCallback? onOpenWeather;

  /// Searches every module as the person types; null searches nothing (the Ask row stays).
  final AppSearch? search;

  /// One quiet line at the very bottom of the results, under the list, never above it (libraries whose PDFs are not searchable
  /// yet); null shows none.
  final Widget? searchFootnote;

  final LayoutState layout;

  /// Starts a new chat with exactly what was typed.
  final void Function(String text) onAsk;
  final VoidCallback onOpenSettings;
  final void Function(Shortcut) onOpenShortcut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<AppSearchResult>? _results;
  int _generation = 0;

  LayoutState get layout => widget.layout;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _editHome(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditHomeScreen(layout: layout)));
  }

  void _changed(String text) {
    _debounce?.cancel();
    final gen = ++_generation;
    setState(() => _results = null);
    if (text.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final found = await widget.search?.search(text) ?? const <AppSearchResult>[];
      if (mounted && gen == _generation) setState(() => _results = found);
    });
  }

  void _clear() {
    _query.clear();
    _focus.unfocus();
    _changed('');
  }

  void _ask() {
    final text = _query.text.trim();
    if (text.isEmpty || !widget.askOn) return;
    _clear();
    widget.onAsk(text);
  }

  void _open(AppSearchResult r) {
    _clear();
    r.open();
  }

  /// Discover's card is in the Set up card's place.
  final _askKey = GlobalKey(debugLabel: 'home-ask');

  bool get _discoverCard => widget.discover?.firstRunDone ?? false;

  /// "Hide" on Set up Cache (or Discover, in its place): the block is switched off (Edit Home switches it on again), with Undo.
  void _hideSetup() {
    widget.layout.setBlockOn(HomeBlock.setup, false);
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      key: const ValueKey('setup-hidden'),
      content: Text('${_discoverCard ? 'Discover' : 'Set up Cache'} hidden. Bring it back in Edit Home.'),
      action: SnackBarAction(label: 'Undo', onPressed: () => widget.layout.setBlockOn(HomeBlock.setup, true)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final typing = _query.text.trim().isNotEmpty;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const BrandWordmark(height: 30),
        actions: [
          IconButton(
            key: const ValueKey('home-settings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: layout,
        builder: (context, _) {
          final blocks = layout.visibleBlocks;
          final setupShown = widget.setup != null && blocks.contains(HomeBlock.setup) && !_discoverCard;
          Widget block(HomeBlock b) => switch (b) {
            HomeBlock.setup => widget.discover == null
                ? (widget.setup == null ? const SizedBox.shrink() : SetupCard(setup: widget.setup!, onHide: _hideSetup))
                : ListenableBuilder(
                    listenable: widget.discover!,
                    builder: (context, _) => _discoverCard
                        ? DiscoverCard(discover: widget.discover!, onOpen: widget.onOpenDiscover ?? () {}, onHide: _hideSetup)
                        : widget.setup == null
                        ? const SizedBox.shrink()
                        : SetupCard(setup: widget.setup!, onHide: _hideSetup),
                  ),
            // The search box keeps its state (focus, keyboard) when the page goes from two columns to one as typing starts.
            HomeBlock.ask => KeyedSubtree(
              key: _askKey,
              child: Padding(key: const ValueKey('home-ask-block'), padding: const EdgeInsets.only(bottom: 12), child: _searchBox(k)),
            ),
            HomeBlock.weather => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _WeatherCard(weather: widget.weather, onTap: widget.onOpenWeather, turnOn: setupShown ? null : widget.turnOn, onOpenSettings: widget.onOpenWeatherSettings),
            ),
            HomeBlock.shortcuts => Padding(padding: const EdgeInsets.only(bottom: 12), child: _shortcuts(context, k)),
          };
          final editHome = Align(
            alignment: Alignment.center,
            child: TextButton(
              key: const ValueKey('edit-home'),
              onPressed: () => _editHome(context),
              child: const Text('Edit Home', style: TextStyle(fontSize: 15)),
            ),
          );
          return LayoutBuilder(builder: (context, cts) {
            final padding = ContentWidth.padFor(cts.maxWidth, min: 16).copyWith(top: 8, bottom: 24);
            // A short, wide window (a phone held sideways): two columns, so the first screen shows the search box and the weather
            // on the left and the Set up card and the shortcuts on the right, instead of one column a few rows of which show.
            if (!typing && isShort(context) && cts.maxWidth - padding.horizontal >= kHomeTwoColumnMinWidth) {
              const right = {HomeBlock.setup, HomeBlock.shortcuts};
              return ListView(
                key: const ValueKey('home-two-columns'),
                padding: padding,
                children: [
                  if (widget.updates != null) UpdateBanner(updates: widget.updates!),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final b in blocks) if (!right.contains(b)) block(b)])),
                      const SizedBox(width: 16),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final b in blocks) if (right.contains(b)) block(b)])),
                    ],
                  ),
                  editHome,
                ],
              );
            }
            return ListView(
              padding: padding,
              children: [
                // The banner's slot stays while typing (empty), so the children below keep their places: dropping it shifted the
                // search box one place up, which made a new text field and closed the keyboard at the first letter typed.
                if (widget.updates != null) typing ? const SizedBox.shrink() : UpdateBanner(updates: widget.updates!),
                for (final b in blocks)
                  if (typing && b != HomeBlock.ask) const SizedBox.shrink() else block(b),
                if (typing) _resultList(k),
                if (!typing) editHome,
              ],
            );
          });
        },
      ),
    );
  }

  Widget _searchBox(CacheTokens k) => TextField(
    key: const ValueKey('home-search'),
    controller: _query,
    focusNode: _focus,
    onChanged: _changed,
    // Enter asks Cache: the keyboard's action key is the send key. Search only (no model): the results show as you type, and
    // the key is the keyboard's search key.
    onSubmitted: widget.askOn ? (_) => _ask() : null,
    textInputAction: widget.askOn ? TextInputAction.send : TextInputAction.search,
    style: TextStyle(fontSize: 15, color: k.text),
    decoration: InputDecoration(
      hintText: widget.askOn ? 'Search Cache or ask anything' : 'Search Cache',
      hintStyle: TextStyle(color: k.secondary),
      prefixIcon: Icon(Icons.search, color: k.secondary),
      suffixIcon: _query.text.isEmpty ? null : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _clear),
      filled: true,
      fillColor: k.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: k.accent, width: 1.5)),
    ),
  );

  /// The results: "Ask Cache: " and exactly what was typed first, then what every module found, best first, or "Nothing found".
  Widget _resultList(CacheTokens k) {
    final text = _query.text.trim();
    final results = _results;
    Widget row({Key? key, required IconData icon, required Widget title, String? second, Widget? trailing, required VoidCallback onTap}) => Material(
      key: key,
      color: k.surface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 20, color: k.secondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      if (second != null && second.isNotEmpty)
                        Text(second, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
    final list = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.askOn)
          row(
            key: const ValueKey('search-ask'),
            icon: Icons.subdirectory_arrow_left,
            title: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Ask Cache:', style: TextStyle(color: k.accent)),
                TextSpan(text: ' $text', style: TextStyle(color: k.accent, fontStyle: FontStyle.italic)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            trailing: Text('Enter', style: TextStyle(fontSize: 12, color: k.secondary)),
            onTap: _ask,
          ),
          if (results != null && results.isEmpty && !widget.askOn)
            _nothingOnDevice(k)
          else if (results != null && results.isEmpty)
            row(
              key: const ValueKey('search-nothing'),
              icon: Icons.search_off,
              title: Text('Nothing found', style: TextStyle(fontSize: 14, color: k.secondary)),
              onTap: _ask,
            ),
          for (final r in results ?? const <AppSearchResult>[]) ...[
            const SizedBox(height: 1),
            row(
              icon: r.icon,
              title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.text)),
              second: [r.module, if (r.detail.isNotEmpty) r.detail].join(' · '),
              onTap: () => _open(r),
            ),
          ],
        ],
      ),
    );
    final note = widget.searchFootnote;
    if (note == null || results == null) return list;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [list, note]);
  }

  /// Search only, and nothing found: says so, and under it, small, the way to answers in words.
  Widget _nothingOnDevice(CacheTokens k) => Material(
    key: const ValueKey('search-nothing'),
    color: k.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.search_off, size: 20, color: k.secondary),
              const SizedBox(width: 12),
              Expanded(child: Text('Nothing found on this device.', style: TextStyle(fontSize: 14, color: k.secondary))),
            ],
          ),
          if (widget.onChooseModel != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: Text('For an answer in words, choose a model.', style: TextStyle(fontSize: 12, color: k.secondary)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: TextButton(
                key: const ValueKey('search-choose-model'),
                onPressed: () {
                  _clear();
                  widget.onChooseModel!();
                },
                child: const Text('Choose a model'),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _shortcuts(BuildContext context, CacheTokens k) {
    // A shortcut to the Ask module is not drawn while there is no model (a chat's shortcut stays: it opens read-only).
    final items = [for (final s in layout.shortcuts) if (widget.askOn || s.module != ModuleId.ask) s];
    final size = MediaQuery.sizeOf(context);
    final tall = size.width >= kRegularWidth && size.height >= kHomeTallHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Shortcuts'),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'Nothing here yet. Use "Add to Home" on a module, a place on the map, a Library page, a chat or a notebook.',
              style: TextStyle(fontSize: 13, color: k.secondary),
            ),
          )
        else
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // Two across on a phone, three on a wider page (the page keeps to the content width); a tall window (a tablet held
            // upright) has larger cards, with larger tiles, so Home is not a strip at the top of the screen.
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: tall ? 14 : 10,
              crossAxisSpacing: tall ? 14 : 10,
              mainAxisExtent: tall ? 150 : 96,
            ),
            children: [
              for (final s in items)
                ShortcutCard(
                  key: ValueKey('shortcut-${s.key}'),
                  shortcut: s,
                  large: tall,
                  onTap: () => widget.onOpenShortcut(s),
                  onLongPress: () => _manage(context, s),
                ),
            ],
          ),
      ],
    );
  }

  /// Long press on a card: remove it, or move it earlier or later.
  Future<void> _manage(BuildContext context, Shortcut s) async {
    final i = layout.shortcuts.indexWhere((x) => x.key == s.key);
    final last = layout.shortcuts.length - 1;
    final choice = await showFittedSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: ctx.t.text)),
              ),
            ),
            if (i > 0)
              ListTile(minTileHeight: 56, leading: Icon(Icons.arrow_back, color: ctx.t.text), title: const Text('Move earlier', style: TextStyle(fontSize: 18)), onTap: () => Navigator.pop(ctx, 'earlier')),
            if (i >= 0 && i < last)
              ListTile(minTileHeight: 56, leading: Icon(Icons.arrow_forward, color: ctx.t.text), title: const Text('Move later', style: TextStyle(fontSize: 18)), onTap: () => Navigator.pop(ctx, 'later')),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.delete_outline, color: ctx.t.emergency),
              title: Text('Remove from Home', style: TextStyle(fontSize: 18, color: ctx.t.emergency)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'earlier':
        layout.nudgeShortcut(s, -1);
      case 'later':
        layout.nudgeShortcut(s, 1);
      case 'remove':
        layout.removeShortcut(s);
    }
  }
}

/// The narrowest content that Home splits into two columns on a short window (two of about 300).
const double kHomeTwoColumnMinWidth = 600;

/// From this window height (a tablet held upright, 1180 or 1366 high) Home's shortcut cards are larger.
const double kHomeTallHeight = 1000;

/// A shortcut card: the module's painted tile (or an icon for the rest), the name and what it is.
class ShortcutCard extends StatelessWidget {
  const ShortcutCard({super.key, required this.shortcut, required this.onTap, required this.onLongPress, this.large = false});

  final Shortcut shortcut;

  /// The larger card of a tall window: a 56 tile and the name in larger type.
  final bool large;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = shortcut;
    final double a = large ? 56 : 32;
    final Widget art = switch (s.kind) {
      ShortcutKind.module => BrandTileImage(s.module!.tile, size: a),
      ShortcutKind.chat => BrandTileImage(BrandTile.chat, size: a),
      ShortcutKind.page => BrandTileImage(BrandTile.library, size: a),
      ShortcutKind.place => SizedBox(height: a, width: a, child: Icon(Icons.place_outlined, size: a * 0.8, color: k.accent)),
      ShortcutKind.notebook => BrandTileImage(BrandTile.journal, size: a),
    };
    return Holdable(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onHold: onLongPress,
        holdLabel: 'Move or remove',
        child: Padding(
          padding: EdgeInsets.all(large ? 16 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              art,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: large ? 18 : 15, fontWeight: FontWeight.w600, color: k.text)),
                  if (s.subtitle.isNotEmpty)
                    Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: large ? 14 : 12, color: k.secondary)),
                ],
              ),
            ],
          ),
        ),
    );
  }
}

/// The conditions and the day's high and low as the Weather card's line starts: "Rain · High 61 °F, low 42 °F" (the source
/// writes "rain"; the line starts with a capital).
String homeConditionsLine(HomeWeather h) => lineStart([
  if (h.conditions != null) h.conditions!,
  if (h.high != null && h.low != null) 'High ${h.high}, low ${h.low}',
].join(' · '));

/// The one Weather and alerts card: a weather icon and the temperature in large type, the conditions and the day's high and low, and
/// below them each warning (a red triangle) and fire (a flame) near the place, with one line of detail. With nothing active it
/// says so beside a tick, never in words alone.
class _WeatherCard extends StatelessWidget {
  const _WeatherCard({required this.weather, this.onTap, this.turnOn, this.onOpenSettings});

  /// "Turn on" when every source is off.
  final VoidCallback? onOpenSettings;

  final WeatherState? weather;
  final VoidCallback? onTap;

  /// Shown as "Turn on weather" while weather is not set up.
  final WeatherTurnOn? turnOn;

  Future<(HomeWeather, bool)> _read(WeatherState w) async => (await w.homeCard(), turnOn != null && await w.needsTurnOn());

  @override
  Widget build(BuildContext context) {
    final w = weather;
    if (w == null) return _frame(context, const HomeWeather(message: 'Not set up yet'), null);
    final t = turnOn;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) => FutureBuilder<(HomeWeather, bool)>(
        future: _read(w),
        builder: (context, snap) {
          // Until the core answers: what was last shown for the place, at once (build 46: 13-20 s of "…" at start).
          final h = snap.data?.$1 ?? w.homeCardNow() ?? const HomeWeather(message: '…');
          final Widget? action;
          if (h.off && onOpenSettings != null) {
            action = Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(key: const ValueKey('weather-off-turn-on'), onPressed: onOpenSettings, child: const Text('Turn on')),
            );
          } else {
            action = t != null && snap.data?.$2 == true ? WeatherTurnOnButtons(turnOn: t, secondary: false) : null;
          }
          return _frame(context, h, action);
        },
      ),
    );
  }

  Widget _frame(BuildContext context, HomeWeather h, Widget? action) {
    final k = context.t;
    final small = TextStyle(fontSize: 12, color: k.secondary);
    final Widget top;
    if (h.message != null) {
      top = Row(
        children: [
          Icon(Icons.wb_cloudy_outlined, size: 30, color: k.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Weather and alerts', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                Text(h.message!, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              ],
            ),
          ),
        ],
      );
    } else {
      final cond = homeConditionsLine(h);
      final where = [
        h.place,
        if (h.expired) 'forecast expired, needs a connection' else if (h.forecastMissing) 'no forecast yet' else ?h.age,
      ].join(' · ');
      top = Row(
        children: [
          Icon(weatherIcon(h.conditions), size: 34, color: k.text),
          const SizedBox(width: 10),
          if (h.temperature != null) ...[
            Text(h.temperature!, key: const ValueKey('home-temperature'), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300, color: k.text, height: 1.1)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cond.isNotEmpty) Text(cond, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.text)),
                Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              ],
            ),
          ),
        ],
      );
    }
    return InkWell(
      key: const ValueKey('home-weather'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            top,
            if (h.message == null && h.alerts.isNotEmpty)
              for (final a in h.alerts.take(4))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(a.fire ? Icons.local_fire_department : Icons.warning_rounded, size: 22, color: a.fire ? k.warning : k.emergency),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: a.fire ? k.text : k.emergency)),
                            if (a.detail.isNotEmpty) Text(a.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
            else if (h.message == null && h.alertsKnown)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: k.ok),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [h.alertsExpired ? 'No alerts known, data expired' : 'No alerts nearby', ?(h.alertsExpired ? null : h.checked)].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                    ),
                  ],
                ),
              ),
            if (h.alerts.length > 4) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${h.alerts.length - 4} more in Weather', style: small)),
            if (action != null) ...[const SizedBox(height: 10), action],
          ],
        ),
      ),
    );
  }
}

/// The weather icon for a forecast's conditions as the source words them ("Partly cloudy", "Light rain").
IconData weatherIcon(String? conditions) {
  final c = (conditions ?? '').toLowerCase();
  if (c.contains('thunder')) return Icons.thunderstorm_outlined;
  if (c.contains('snow') || c.contains('sleet') || c.contains('ice')) return Icons.ac_unit;
  if (c.contains('rain') || c.contains('drizzle') || c.contains('shower')) return Icons.umbrella_outlined;
  if (c.contains('fog') || c.contains('mist') || c.contains('haze') || c.contains('smoke')) return Icons.foggy;
  if (c.contains('partly') || c.contains('mostly')) return Icons.wb_cloudy_outlined;
  if (c.contains('cloud') || c.contains('overcast')) return Icons.cloud_outlined;
  if (c.contains('clear') || c.contains('sun') || c.contains('fair')) return Icons.wb_sunny_outlined;
  return Icons.wb_cloudy_outlined;
}
