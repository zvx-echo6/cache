import 'dart:async';

import 'package:flutter/material.dart';

import '../brand.dart';
import '../layout/edit_home_screen.dart';
import '../layout/layout_state.dart';
import '../search/app_search.dart';
import 'hold.dart';
import 'settings/widgets.dart' show GroupLabel;
import '../theme.dart';
import '../weather/weather_state.dart';
import '../weather/words.dart' show lineStart;
import 'setup_card.dart';
import 'weather_turn_on.dart';

/// Home: the blocks the person chose, in the order they chose (Set up Cache while it is not done, the search box, Weather and alerts,
/// Shortcuts by default), a gear for Settings at the top right, and "Edit Home" at the bottom. The search box searches all of Cache;
/// its first row always asks Cache exactly what was typed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.layout,
    required this.onAsk,
    required this.onOpenSettings,
    required this.onOpenShortcut,
    this.search,
    this.weather,
    this.onOpenWeather,
    this.turnOn,
    this.setup,
  });

  /// The "Set up Cache" block; null leaves it out.
  final SetupCache? setup;

  /// "Turn on weather" on the Weather and alerts card while weather is not set up (and Set up Cache is not showing it).
  final WeatherTurnOn? turnOn;

  /// Feeds the Weather and alerts card; without it the card says "Not set up yet".
  final WeatherState? weather;
  final VoidCallback? onOpenWeather;

  /// Searches every module as the person types; null searches nothing (the Ask row stays).
  final AppSearch? search;

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
    if (text.isEmpty) return;
    _clear();
    widget.onAsk(text);
  }

  void _open(AppSearchResult r) {
    _clear();
    r.open();
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
          final setupShown = widget.setup != null && blocks.contains(HomeBlock.setup);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              for (final b in blocks)
                if (typing && b != HomeBlock.ask)
                  const SizedBox.shrink()
                else
                  switch (b) {
                    HomeBlock.setup => widget.setup == null ? const SizedBox.shrink() : SetupCard(setup: widget.setup!),
                    HomeBlock.ask => Padding(padding: const EdgeInsets.only(bottom: 12), child: _searchBox(k)),
                    HomeBlock.weather => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _WeatherCard(weather: widget.weather, onTap: widget.onOpenWeather, turnOn: setupShown ? null : widget.turnOn),
                    ),
                    HomeBlock.shortcuts => Padding(padding: const EdgeInsets.only(bottom: 12), child: _shortcuts(context, k)),
                  },
              if (typing) _resultList(k),
              if (!typing)
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    key: const ValueKey('edit-home'),
                    onPressed: () => _editHome(context),
                    child: const Text('Edit Home', style: TextStyle(fontSize: 15)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _searchBox(CacheTokens k) => TextField(
    key: const ValueKey('home-search'),
    controller: _query,
    focusNode: _focus,
    onChanged: _changed,
    onSubmitted: (_) => _ask(),
    // Enter asks Cache: the keyboard's action key is the send key.
    textInputAction: TextInputAction.send,
    style: TextStyle(fontSize: 15, color: k.text),
    decoration: InputDecoration(
      hintText: 'Search Cache or ask anything',
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          if (results != null && results.isEmpty)
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
  }

  Widget _shortcuts(BuildContext context, CacheTokens k) {
    final items = layout.shortcuts;
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
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              mainAxisExtent: 96,
            ),
            children: [
              for (final s in items)
                ShortcutCard(
                  key: ValueKey('shortcut-${s.key}'),
                  shortcut: s,
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
    final choice = await showModalBottomSheet<String>(
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

/// A shortcut card: the module's painted tile (or an icon for the rest), the name and what it is.
class ShortcutCard extends StatelessWidget {
  const ShortcutCard({super.key, required this.shortcut, required this.onTap, required this.onLongPress});

  final Shortcut shortcut;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = shortcut;
    final Widget art = switch (s.kind) {
      ShortcutKind.module => BrandTileImage(s.module!.tile, size: 32),
      ShortcutKind.chat => const BrandTileImage(BrandTile.chat, size: 32),
      ShortcutKind.page => const BrandTileImage(BrandTile.library, size: 32),
      ShortcutKind.place => SizedBox(height: 32, width: 32, child: Icon(Icons.place_outlined, size: 26, color: k.accent)),
      ShortcutKind.notebook => const BrandTileImage(BrandTile.journal, size: 32),
    };
    return Holdable(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onHold: onLongPress,
        holdLabel: 'Move or remove',
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              art,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text)),
                  if (s.subtitle.isNotEmpty)
                    Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.secondary)),
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
  const _WeatherCard({required this.weather, this.onTap, this.turnOn});

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
        builder: (context, snap) => _frame(
          context,
          snap.data?.$1 ?? const HomeWeather(message: '…'),
          t != null && snap.data?.$2 == true ? WeatherTurnOnButtons(turnOn: t, secondary: false) : null,
        ),
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
