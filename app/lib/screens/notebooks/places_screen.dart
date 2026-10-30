import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../chat/answer_markdown.dart' show answerStyle;
import '../../layout/layout_state.dart';
import '../../notebook/markdown_text.dart';
import '../../notebook/media.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/place_style.dart';
import '../../notebook/places.dart';
import '../../theme.dart';
import '../../weather/place_alerts.dart';
import 'field_inputs.dart';
import 'notebook_editor.dart';
import 'notebook_screen.dart' show NotebookDeps;
import 'place_alert_sheet.dart';

/// A map that shows [pin] and, when [onPick] is given, moves it to where it is tapped (the place screen's map).
typedef PlaceMapBuilder = Widget Function(BuildContext context, NbPlace? pin, ValueChanged<NbPlace>? onPick);

/// What the Places notebooks need besides the store: the weather and alert switches of the saved places, the place map and
/// directions. Weather and alerts are kept for saved places only (the saved-places notebook): a watched place's id is
/// `place:<key>`, and "Where I am" is `here`.
class PlaceNotebookDeps {
  const PlaceNotebookDeps({
    required this.watched,
    required this.setWatched,
    required this.alerts,
    this.placesChanged,
    this.alertSetting,
    this.alertKinds,
    this.map,
    this.directions,
    this.regions,
    this.hereOnMap,
    this.setHereOnMap,
  });

  final bool Function(String placeId) watched;
  final void Function(String placeId, bool on) setWatched;
  final PlaceAlerts alerts;

  /// After a saved place is made, changed or deleted: Weather reads the saved places again (a new one is noted before its
  /// switch is set) and the assistant's place list is published again.
  final Future<void> Function()? placesChanged;

  /// The alert setting in words ("Serious only, from Notifications"), for "Same as your alert setting".
  final String Function()? alertSetting;

  /// The kinds of alerts the sources that are on give (catalogue categories).
  final List<String> Function()? alertKinds;
  final PlaceMapBuilder? map;

  /// Directions on the map to a place.
  final void Function(NbPlace place, String name)? directions;

  /// The downloaded regions weather can be kept for (watched-place id `region:<name>`), listed after "Where I am".
  final Future<List<({String id, String name})>> Function()? regions;

  /// "Where I am" on the map (the position dot), and its marker's toggle.
  final bool Function()? hereOnMap;
  final void Function(bool on)? setHereOnMap;
}

/// The watched-place id of a saved place's entry.
String? watchId(NbEntry e) => e.place?.key == null ? null : 'place:${e.place!.key}';

/// A Places notebook: each place with its own marker colour (tap the marker to show or hide it on the map; a hidden place
/// shows an outlined marker with a slash), tap to open, press and hold to edit, and "+ Add place". The saved places' notebook
/// also lists "Where I am" first, with its weather and alerts.
class PlacesNotebookScreen extends StatefulWidget {
  const PlacesNotebookScreen({super.key, required this.deps, required this.notebookId});

  final NotebookDeps deps;
  final String notebookId;

  @override
  State<PlacesNotebookScreen> createState() => _PlacesNotebookScreenState();
}

class _PlacesNotebookScreenState extends State<PlacesNotebookScreen> {
  NotebookState get nb => widget.deps.notebook;
  PlaceNotebookDeps? get pd => widget.deps.placesDeps;
  List<NbEntry>? _entries;
  int _readAt = -1;
  ({double lat, double lon})? _here;
  List<({String id, String name})> _regions = const [];

  @override
  void initState() {
    super.initState();
    nb.addListener(_onChange);
    pd?.alerts.addListener(_onChange);
    pd?.alerts.load();
    _read();
    pd?.regions?.call().then((r) {
      if (mounted) setState(() => _regions = r);
    }).catchError((_) {});
    widget.deps.places.here().then((h) {
      if (mounted && h != null) setState(() => _here = h);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    nb.removeListener(_onChange);
    pd?.alerts.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (nb.revision != _readAt) _read();
    if (mounted) setState(() {});
  }

  Future<void> _read() async {
    _readAt = nb.revision;
    try {
      final list = await nb.entries(widget.notebookId);
      if (mounted) setState(() => _entries = [for (final e in list) if (!e.draft) e]);
    } catch (_) {
      if (mounted) setState(() => _entries = const []);
    }
  }

  Future<void> _toggleMap(Notebook book, NbEntry e) async {
    HapticFeedback.selectionClick();
    await nb.saveEntry(
      id: e.id,
      notebookId: e.notebookId,
      occurredAt: e.occurredAt,
      title: e.title,
      body: e.body,
      values: e.values,
      place: e.place,
      photos: e.photos,
      files: e.files,
      private: e.private,
      props: {...e.props, 'color': e.color ?? defaultMarkerColor(_entries ?? const []).id, 'on_map': !e.onMap},
    );
  }

  void _open(Notebook book, NbEntry e) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaceView(deps: widget.deps, book: book, entryId: e.id)));

  void _edit(Notebook book, NbEntry? e, {NbPlace? at}) {
    if (e != null) HapticFeedback.mediumImpact();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaceForm(deps: widget.deps, book: book, entry: e, at: at, others: _entries ?? const [])));
  }

  Future<void> _menu(Notebook book, String choice) async {
    switch (choice) {
      case 'import':
        await importPlacesInto(context, nb, notebookId: book.id, now: widget.deps.now);
      case 'edit':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NotebookEditor(notebook: nb, existing: book)));
      case 'map':
        await nb.setOnMap(book, !book.map);
      case 'home':
        final added = widget.deps.layout?.addShortcut(Shortcut.notebook(id: book.id, name: book.name, log: false)) ?? false;
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added ? 'Added to Home' : 'Already on Home')));
      case 'delete':
        final n = book.entryCount;
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text('Delete ${book.name} and its ${n == 1 ? '1 place' : '$n places'}? This can\'t be undone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(key: const ValueKey('confirm-delete'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (yes != true) return;
        widget.deps.layout?.removeShortcut(Shortcut.notebook(id: book.id, name: book.name, log: false));
        await nb.deleteNotebook(book.id);
        if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = nb.notebook(widget.notebookId);
    if (book == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This notebook is gone')));
    final k = context.t;
    final h = _here;
    final all = [for (final e in _entries ?? const <NbEntry>[]) if (!nb.isHidden(e.id)) e];
    double d(NbEntry e) => h == null || e.place == null ? double.infinity : distanceM(h.lat, h.lon, e.place!.lat, e.place!.lon);
    final list = [...all]..sort((a, b) {
        final c = d(a).compareTo(d(b));
        return c != 0 ? c : entryTitle(a).toLowerCase().compareTo(entryTitle(b).toLowerCase());
      });
    return Scaffold(
      appBar: AppBar(
        title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('places-menu'),
            onSelected: (c) => _menu(book, c),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'import', child: Text('Add places from a file')),
              if (!book.savedPlaces) const PopupMenuItem(value: 'edit', child: Text('Rename notebook')),
              if (book.placeCount > 0) PopupMenuItem(value: 'map', child: Text(book.map ? 'Hide all on map' : 'Show all on map')),
              if (widget.deps.layout != null) const PopupMenuItem(value: 'home', child: Text('Add to Home')),
              if (!book.savedPlaces) const PopupMenuItem(value: 'delete', child: Text('Delete notebook')),
            ],
          ),
        ],
      ),
      body: _entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (book.savedPlaces && pd != null) _whereIAm(k),
                if (book.savedPlaces && pd != null)
                  for (final r in _regions)
                    _Card(
                      key: ValueKey('place-${r.id}'),
                      leading: SizedBox(width: 44, height: 44, child: Icon(Icons.map_outlined, color: k.secondary)),
                      title: r.name,
                      detail: 'Downloaded region · weather ${pd!.watched(r.id) ? 'on' : 'off'}',
                      onTap: () => showWeatherSheet(context, pd!, placeId: r.id, name: r.name).then((_) => setState(() {})),
                      onLongPress: () {
                        HapticFeedback.mediumImpact();
                        showWeatherSheet(context, pd!, placeId: r.id, name: r.name).then((_) => setState(() {}));
                      },
                    ),
                for (final e in list) _row(book, e, k),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
                    child: Text(
                      'No places yet. Save the places that matter: home, a rally point, a water source.',
                      key: const ValueKey('places-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: k.secondary),
                    ),
                  )
                else
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
                    child: Text('Tap the marker to show or hide a place on the map. Tap a place to open it; press and hold to edit.',
                        style: TextStyle(fontSize: 14, color: k.secondary)),
                  ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(key: const ValueKey('add-place'), onPressed: () => _edit(book, null), icon: const Icon(Icons.add), label: const Text('Add place')),
                ),
              ],
            ),
    );
  }

  /// "Where I am": the fixed first row (the phone's position, never deleted or moved), with its marker toggle (the position on
  /// the map) and its weather and alerts.
  Widget _whereIAm(CacheTokens k) {
    final p = pd!;
    final on = p.watched('here');
    final shown = p.hereOnMap?.call() ?? true;
    return _Card(
      key: const ValueKey('place-here'),
      leading: Semantics(
        button: true,
        toggled: shown,
        label: 'Where I am marker, ${shown ? 'shown on the map' : 'hidden on the map'}',
        excludeSemantics: true,
        child: InkResponse(
          key: const ValueKey('marker-here'),
          radius: 24,
          onTap: p.setHereOnMap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  setState(() => p.setHereOnMap!(!shown));
                },
          child: SizedBox(width: 44, height: 44, child: Icon(shown ? Icons.my_location : Icons.location_disabled_outlined, color: k.accent)),
        ),
      ),
      title: 'Where I am',
      detail: 'Follows the phone · weather ${on ? 'on' : 'off'}',
      onTap: () => showWeatherSheet(context, p, placeId: 'here', name: 'Where I am').then((_) => setState(() {})),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        showWeatherSheet(context, p, placeId: 'here', name: 'Where I am').then((_) => setState(() {}));
      },
    );
  }

  Widget _row(Notebook book, NbEntry e, CacheTokens k) {
    final color = markerColor(e.color);
    final h = _here;
    final id = watchId(e);
    final detail = [
      if (e.place?.label != null && e.place!.label!.trim().isNotEmpty && e.place!.label != e.title) e.place!.label!,
      if (h != null && e.place != null) distanceText(distanceM(h.lat, h.lon, e.place!.lat, e.place!.lon)),
      if (book.savedPlaces && pd != null && id != null) 'weather ${pd!.watched(id) ? 'on' : 'off'}',
      if (e.photos.isNotEmpty) e.photos.length == 1 ? '1 photo' : '${e.photos.length} photos',
    ];
    final name = entryTitle(e);
    return Dismissible(
      key: ValueKey('place-${e.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: k.emergency,
        child: const Text('Delete', style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      confirmDismiss: (_) => confirmDeletePlace(context, name),
      onDismissed: (_) async {
        await nb.deleteEntry(e.id);
        if (id != null) {
          pd?.setWatched(id, false);
          await pd?.alerts.forget(id);
          await pd?.placesChanged?.call();
        }
      },
      child: _Card(
        leading: Semantics(
          button: true,
          toggled: e.onMap,
          label: '${color.spoken} marker, ${e.onMap ? 'shown on the map' : 'hidden on the map'}',
          onTapHint: e.onMap ? 'Hide on the map' : 'Show on the map',
          excludeSemantics: true,
          child: InkResponse(
            key: ValueKey('marker-${e.id}'),
            radius: 24,
            onTap: () => _toggleMap(book, e),
            child: SizedBox(width: 44, height: 44, child: Center(child: PlaceMarker(color: color, hidden: !e.onMap))),
          ),
        ),
        title: name,
        detail: detail.join(' · '),
        onTap: () => _open(book, e),
        onLongPress: () => _edit(book, e),
        actions: {const CustomSemanticsAction(label: 'Edit'): () => _edit(book, e)},
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.leading, required this.title, required this.detail, required this.onTap, required this.onLongPress, this.actions});

  final Widget leading;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Map<CustomSemanticsAction, VoidCallback>? actions;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      customSemanticsActions: actions,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                      if (detail.isNotEmpty) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks before a place is deleted. True when the person said Delete.
Future<bool> confirmDeletePlace(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('Its notes and photos go too, and its weather and alerts are no longer kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('confirm-delete-place'), onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: TextStyle(color: ctx.t.emergency))),
        ],
      ),
    ) ==
    true;

/// The "Weather and alerts" switch and gear of a place that is not being edited ("Where I am").
Future<void> showWeatherSheet(BuildContext context, PlaceNotebookDeps p, {required String placeId, required String name}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: ctx.t.text)),
                const SizedBox(height: 8),
                WeatherRow(
                  deps: p,
                  name: name,
                  on: p.watched(placeId),
                  rule: p.alerts.ruleFor(placeId),
                  onChanged: (on) => setState(() => p.setWatched(placeId, on)),
                  onRule: (r) async {
                    await p.alerts.set(placeId, r);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

/// The one "Weather and alerts" row: a switch, and a gear (the place's alert sheet) only when it is on.
class WeatherRow extends StatelessWidget {
  const WeatherRow({super.key, required this.deps, required this.name, required this.on, required this.rule, required this.onChanged, required this.onRule});

  final PlaceNotebookDeps deps;
  final String name;
  final bool on;
  final PlaceAlertRule rule;
  final ValueChanged<bool> onChanged;
  final ValueChanged<PlaceAlertRule> onRule;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      key: const ValueKey('weather-row'),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          Icon(Icons.wb_cloudy_outlined, color: k.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Weather and alerts', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: k.text)),
                if (on) Text(placeAlertLine(rule, deps.alertSetting?.call()), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
              ],
            ),
          ),
          if (on)
            IconButton(
              key: const ValueKey('weather-gear'),
              tooltip: 'Alerts for $name',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.settings_outlined, color: k.accent),
              onPressed: () async {
                final r = await showPlaceAlertSheet(context, placeName: name, rule: rule, alertSetting: deps.alertSetting?.call(), kinds: deps.alertKinds?.call() ?? const ['alerts', 'fire']);
                if (r != null) onRule(r);
              },
            ),
          Switch(key: const ValueKey('weather-switch'), value: on, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// One place, opened: its map, name, where it is, its notes (Markdown, formatted), photos, and Directions. Edit is in the bar
/// (the list's press and hold does the same).
class PlaceView extends StatelessWidget {
  const PlaceView({super.key, required this.deps, required this.book, required this.entryId});

  final NotebookDeps deps;
  final Notebook book;
  final String entryId;

  @override
  Widget build(BuildContext context) {
    final nb = deps.notebook;
    return ListenableBuilder(
      listenable: nb,
      builder: (context, _) => FutureBuilder<NbEntry?>(
        key: ValueKey(nb.revision),
        future: nb.entry(entryId),
        builder: (context, snap) {
          final e = snap.data;
          if (e == null) {
            return Scaffold(appBar: AppBar(), body: Center(child: snap.connectionState == ConnectionState.done ? const Text('This place is gone') : const CircularProgressIndicator()));
          }
          final k = context.t;
          final name = entryTitle(e);
          final p = e.place;
          final pd = deps.placesDeps;
          final id = watchId(e);
          return Scaffold(
            appBar: AppBar(
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  key: const ValueKey('place-edit'),
                  tooltip: 'Edit place',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final r = await Navigator.of(context).push(MaterialPageRoute<String>(builder: (_) => PlaceForm(deps: deps, book: book, entry: e)));
                    if (r == 'deleted' && context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (pd?.map != null && p != null) ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox(height: 200, child: pd!.map!(context, p, null))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    PlaceMarker(color: markerColor(e.color), hidden: !e.onMap),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text([if (p != null) p.coords, if (p?.label != null && p!.label != e.title) p.label!].join(' · '),
                          style: TextStyle(fontSize: 14, color: k.secondary)),
                    ),
                  ],
                ),
                if (book.savedPlaces && pd != null && id != null) ...[
                  const SizedBox(height: 10),
                  StatefulBuilder(
                    builder: (context, setState) => WeatherRow(
                      deps: pd,
                      name: name,
                      on: pd.watched(id),
                      rule: pd.alerts.ruleFor(id),
                      onChanged: (on) => setState(() => pd.setWatched(id, on)),
                      onRule: (r) async {
                        await pd.alerts.set(id, r);
                        setState(() {});
                      },
                    ),
                  ),
                ],
                if ((e.body ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  MarkdownBody(key: const ValueKey('place-notes'), data: e.body!, styleSheet: answerStyle(k), onTapLink: (text, href, title) {}),
                ],
                if (e.photos.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(spacing: 8, runSpacing: 8, children: [for (final ph in e.photos) NbThumb(notebook: nb, id: ph.id, size: 96)]),
                ],
                if (pd?.directions != null && p != null) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('place-directions'),
                      onPressed: () => pd!.directions!(p, name),
                      icon: const Icon(Icons.directions),
                      label: const Text('Directions'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Add place and Edit place, one full screen: the map with a search (an address, a place or coordinates; tap the map to move
/// the pin), the name, the marker colour, Show on the map, one "Weather and alerts" row (saved places), notes (Markdown),
/// photos, Save, and Delete place (with a confirm) when editing.
class PlaceForm extends StatefulWidget {
  const PlaceForm({super.key, required this.deps, required this.book, this.entry, this.at, this.others = const []});

  final NotebookDeps deps;
  final Notebook book;

  /// The place to edit; null adds one.
  final NbEntry? entry;

  /// Where a new place starts (a spot held on the map); null starts at Here.
  final NbPlace? at;

  /// The notebook's places (for the default colour).
  final List<NbEntry> others;

  @override
  State<PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends State<PlaceForm> {
  NotebookState get nb => widget.deps.notebook;
  PlaceNotebookDeps? get pd => widget.deps.placesDeps;
  late final TextEditingController _name = TextEditingController(text: widget.entry?.title ?? '');
  late final MarkdownController _notes = MarkdownController(text: widget.entry?.body ?? '');
  final TextEditingController _search = TextEditingController();
  late NbPlace? _pin = widget.entry?.place ?? widget.at;
  late MarkerColor _color = widget.entry?.color != null ? markerColor(widget.entry!.color) : defaultMarkerColor(widget.others);
  late bool _onMap = widget.entry?.onMap ?? true;
  late bool _weather = _id == null ? true : pd?.watched(_id!) ?? false;
  late PlaceAlertRule _rule = _id == null ? PlaceAlertRule.same : pd?.alerts.ruleFor(_id!) ?? PlaceAlertRule.same;
  late List<NbPhoto> _photos = [...?widget.entry?.photos];
  final List<NbPhoto> _added = [];
  List<NbPlace> _found = const [];
  bool _searching = false;
  bool _saving = false;
  String? _error;

  String? get _id => widget.entry == null ? null : watchId(widget.entry!);
  bool get _isNew => widget.entry == null;
  bool get _weatherApplies => widget.book.savedPlaces && pd != null;

  @override
  void initState() {
    super.initState();
    if (_pin == null) {
      widget.deps.places.herePlace().then((p) {
        if (mounted && _pin == null && p != null) setState(() => _pin = NbPlace(lat: p.lat, lon: p.lon));
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _find(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    final coords = parseLatLon(q);
    if (coords != null) {
      setState(() {
        _pin = coords;
        _found = const [];
      });
      return;
    }
    final s = widget.deps.places.search;
    if (s == null) return;
    setState(() => _searching = true);
    try {
      final r = await s(q);
      if (mounted) setState(() => _found = r);
    } catch (_) {
      if (mounted) setState(() => _found = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _pick(NbPlace p) {
    setState(() {
      _pin = NbPlace(lat: p.lat, lon: p.lon, label: p.label);
      _found = const [];
      if (_name.text.trim().isEmpty && p.label != null) _name.text = p.label!;
    });
  }

  Future<void> _save() async {
    final pin = _pin;
    final name = _name.text.trim();
    if (pin == null || name.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final e = widget.entry;
      final saved = await nb.saveEntry(
        id: e?.id,
        notebookId: widget.book.id,
        occurredAt: e?.occurredAt ?? isoLocal(widget.deps.now()),
        title: name,
        body: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        values: e?.values ?? const {},
        place: NbPlace(lat: pin.lat, lon: pin.lon, label: pin.label, key: e?.place?.key),
        photos: _photos,
        files: e?.files ?? const [],
        private: e?.private ?? false,
        props: {...?e?.props, 'color': _color.id, 'on_map': _onMap},
      );
      _added.clear();
      final id = watchId(saved);
      if (_weatherApplies && id != null) {
        await pd!.placesChanged?.call();
        pd!.setWatched(id, _weather);
        await pd!.alerts.set(id, _rule);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Not saved. Your phone may be out of space.';
        });
      }
    }
  }

  Future<void> _delete() async {
    final e = widget.entry;
    if (e == null || !await confirmDeletePlace(context, entryTitle(e))) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final id = watchId(e);
    await discardUnsaved(nb, photos: _added);
    if (!mounted) return;
    Navigator.pop(context, 'deleted');
    await nb.deleteEntry(e.id);
    if (id != null) {
      pd?.setWatched(id, false);
      await pd?.alerts.forget(id);
      await pd?.placesChanged?.call();
    }
    messenger.showSnackBar(SnackBar(content: Text('${entryTitle(e)} deleted')));
  }

  Future<void> _cancel() async {
    await discardUnsaved(nb, photos: _added);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final pin = _pin;
    final canSave = pin != null && _name.text.trim().isNotEmpty && !_saving;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(key: const ValueKey('place-close'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: _cancel),
          title: Text(_isNew ? 'Add place' : 'Edit place'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextField(
              key: const ValueKey('place-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search an address, place or coordinates',
                prefixIcon: const Icon(Icons.search),
                suffix: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
              onSubmitted: _find,
            ),
            for (final p in _found)
              ListTile(
                minTileHeight: 48,
                leading: Icon(Icons.place_outlined, color: k.secondary),
                title: Text(p.display, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => _pick(p),
              ),
            if (pd?.map != null) ...[
              const SizedBox(height: 8),
              ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox(height: 220, child: pd!.map!(context, pin, (p) => setState(() => _pin = p)))),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                pin == null
                    ? 'No position yet. Search for the place${pd?.map != null ? ' or tap the map' : ''}.'
                    : [pin.coords, if (pin.label != null) pin.label!, if (pd?.map != null) 'tap the map to move the pin'].join(' · '),
                key: const ValueKey('place-where'),
                style: TextStyle(fontSize: 13, color: k.secondary),
              ),
            ),
            TextField(
              key: const ValueKey('place-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Name', counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Text('Marker colour', style: TextStyle(fontSize: 14, color: k.secondary)),
            Wrap(
              children: [
                for (final c in kMarkerColors)
                  Semantics(
                    button: true,
                    selected: c.id == _color.id,
                    label: c.spoken,
                    excludeSemantics: true,
                    child: InkResponse(
                      key: ValueKey('swatch-${c.id}'),
                      radius: 22,
                      onTap: () => setState(() => _color = c),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: c.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.id == _color.id ? k.text : Colors.transparent, width: 2.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('place-on-map'),
              contentPadding: EdgeInsets.zero,
              secondary: PlaceMarker(color: _color, hidden: !_onMap),
              title: const Text('Show on the map'),
              value: _onMap,
              onChanged: (v) => setState(() => _onMap = v),
            ),
            if (_weatherApplies)
              WeatherRow(
                deps: pd!,
                name: _name.text.trim().isEmpty ? 'this place' : _name.text.trim(),
                on: _weather,
                rule: _rule,
                onChanged: (v) => setState(() => _weather = v),
                onRule: (r) => setState(() => _rule = r),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Notes', style: TextStyle(fontSize: 14, color: k.secondary)),
                const MarkdownHelpButton(),
              ],
            ),
            TextField(
              key: const ValueKey('place-notes-field'),
              controller: _notes,
              minLines: 3,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Gate codes, what is there, how to find it'),
            ),
            const SizedBox(height: 12),
            Text('Photos', style: TextStyle(fontSize: 14, color: k.secondary)),
            const SizedBox(height: 6),
            PhotoStrip(
              notebook: nb,
              ids: [for (final p in _photos) p.id],
              onAdded: _added.add,
              onChanged: (ids) {
                final known = {for (final p in [..._photos, ..._added]) p.id: p};
                final gone = [for (final p in _added) if (!ids.contains(p.id)) p];
                discardUnsaved(nb, photos: gone);
                _added.removeWhere(gone.contains);
                setState(() => _photos = [for (final id in ids) ?known[id]]);
              },
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: k.emergency))),
            const SizedBox(height: 20),
            FilledButton(key: const ValueKey('place-save'), onPressed: canSave ? _save : null, child: const Text('Save')),
            if (!_isNew) ...[
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('place-delete'),
                onPressed: _delete,
                child: Text('Delete place', style: TextStyle(color: k.emergency)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "43.615, -116.202" (or with a space instead of the comma) as a place; null for anything else. A machine format, not words.
NbPlace? parseLatLon(String s) {
  final m = RegExp(r'^\s*(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)\s*$').firstMatch(s);
  if (m == null) return null;
  final lat = double.parse(m.group(1)!), lon = double.parse(m.group(2)!);
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return NbPlace(lat: lat, lon: lon);
}

/// "Add places from a file": a KML, KMZ, GPX or GeoJSON file read into the notebook [notebookId] (or a new Places notebook);
/// says how many places came in.
Future<void> importPlacesInto(BuildContext context, NotebookState nb, {String? notebookId, required DateTime Function() now}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await withPickedFile((path, _) => nb.importPlaces(path, notebookId: notebookId, now: isoLocal(now())));
    if (r == null) return;
    final n = (r['places'] as num?)?.toInt() ?? 0;
    final shapes = ((r['lines'] as num?)?.toInt() ?? 0) + ((r['areas'] as num?)?.toInt() ?? 0);
    final into = (r['notebook'] as Map?)?['def']?['name'] ?? 'the notebook';
    messenger.showSnackBar(SnackBar(content: Text('${n == 1 ? '1 place' : '$n places'}${shapes > 0 ? ' and $shapes lines and areas' : ''} added to $into')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not read the file: ${e is CacheSearchException ? e.message : e}')));
  }
}
