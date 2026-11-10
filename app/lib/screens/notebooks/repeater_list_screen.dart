import 'package:flutter/material.dart';

import '../../layout/adaptive.dart';

import '../../maps/ui/layer_sheet.dart' show updateRepeaterList;
import '../../maps/ui/repeater_card.dart' show repeaterDistance;
import '../../maps/user_layers.dart';
import '../../nav/units.dart';
import '../../theme.dart';
import 'notebook_screen.dart' show NotebookDeps;

/// "Repeaters: [name]": an imported repeater list as a notebook. One line a repeater ("146.880 · Idaho Falls", the callsign under
/// it), nearest first, with a search box. Tap shows it on the map with its card; press and hold offers Show on map and Directions.
/// The rows are the file's: a list changes by "Update from a file" (the same steps as Add from a file).
class RepeaterListScreen extends StatefulWidget {
  const RepeaterListScreen({super.key, required this.deps, required this.listId, this.focusItem});

  final NotebookDeps deps;
  final String listId;

  /// The repeater to scroll to and mark (its card's "Open in notebook").
  final int? focusItem;

  @override
  State<RepeaterListScreen> createState() => _RepeaterListScreenState();
}

class _RepeaterListScreenState extends State<RepeaterListScreen> {
  static const double rowHeight = 64;
  Fmt get _fmt => widget.deps.fmt ?? const Fmt(UnitSystem.imperial);
  UserLayersState get u => widget.deps.userLayers!;
  late Future<RepeaterNotebookSource?> _source = u.repeaterSource(widget.listId);
  ({double lat, double lon})? _here;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  String _q = '';
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    widget.deps.places.here().then((h) {
      if (mounted && h != null) setState(() => _here = h);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// "146.880 MHz" as the row's first words: the number (the unit is the same on every row).
  static String _freq(Repeater r) => (r.frequency ?? '').replaceFirst(RegExp(r'\s*MHz$'), '');

  List<({Repeater repeater, double? metres})> _rows(RepeaterNotebookSource s) {
    final h = _here;
    final all = h == null ? [for (final r in s.rows) (repeater: r, metres: null)] : s.nearest(h.lat, h.lon);
    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return all;
    return [
      for (final x in all)
        if (words.every('${x.repeater.name} ${x.repeater.town ?? ''} ${x.repeater.frequency ?? ''}'.toLowerCase().contains)) x,
    ];
  }

  Future<void> _update(UserLayer list) async {
    final newId = await updateRepeaterList(context, u, list);
    if (newId != null && mounted) {
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => RepeaterListScreen(deps: widget.deps, listId: newId)));
    }
  }

  Future<void> _hold(Repeater r) async {
    final d = widget.deps;
    final choice = await showFittedSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(r.name, style: Theme.of(ctx).textTheme.titleMedium)),
            if (d.onShowRepeater != null)
              ListTile(key: const ValueKey('repeater-show'), leading: const Icon(Icons.map_outlined), title: const Text('Show on map'), onTap: () => Navigator.pop(ctx, 'show')),
            if (d.onRepeaterDirections != null)
              ListTile(key: const ValueKey('repeater-row-directions'), leading: const Icon(Icons.directions), title: const Text('Directions'), onTap: () => Navigator.pop(ctx, 'directions')),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'show') d.onShowRepeater?.call(r);
    if (choice == 'directions') d.onRepeaterDirections?.call(r);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return FutureBuilder<RepeaterNotebookSource?>(
      future: _source,
      builder: (context, snap) {
        final s = snap.data;
        final list = s?.list ?? u.repeaterLists.where((l) => l.id == widget.listId).firstOrNull;
        final Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Center(child: CircularProgressIndicator());
        } else if (s == null) {
          body = Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('This list could not be read.', style: TextStyle(fontSize: 15, color: k.text)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: () => setState(() => _source = u.repeaterSource(widget.listId)), child: const Text('Try again')),
                ],
              ),
            ),
          );
        } else if (s.rows.isEmpty) {
          body = Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('No repeaters found in that file.', key: const ValueKey('repeaters-empty'), style: TextStyle(fontSize: 15, color: k.text)),
                  const SizedBox(height: 12),
                  FilledButton(key: const ValueKey('repeaters-choose-file'), onPressed: () => _update(s.list), child: const Text('Choose another file')),
                ],
              ),
            ),
          );
        } else {
          final rows = _rows(s);
          final focus = widget.focusItem;
          if (focus != null && !_scrolled) {
            _scrolled = true;
            final i = rows.indexWhere((x) => x.repeater.item == focus);
            if (i > 2) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scroll.hasClients) _scroll.jumpTo(((i - 2) * rowHeight).clamp(0, _scroll.position.maxScrollExtent));
              });
            }
          }
          body = Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: TextField(
                  key: const ValueKey('repeaters-search'),
                  controller: _query,
                  onChanged: (v) => setState(() => _q = v.trim()),
                  textInputAction: TextInputAction.search,
                  style: TextStyle(fontSize: 15, color: k.text),
                  decoration: InputDecoration(
                    hintText: 'Search ${s.rows.length == 1 ? '1 repeater' : '${s.rows.length} repeaters'}',
                    hintStyle: TextStyle(color: k.secondary),
                    prefixIcon: Icon(Icons.search, color: k.secondary),
                    filled: true,
                    fillColor: k.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                ),
              ),
              if (rows.isEmpty)
                Padding(padding: const EdgeInsets.all(24), child: Text('No repeater matches your search.', style: TextStyle(fontSize: 14, color: k.secondary)))
              else
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemExtent: rowHeight,
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i].repeater;
                      final h = _here;
                      final dist = h == null ? null : repeaterDistance(r, _fmt, fromLat: h.lat, fromLon: h.lon);
                      final marked = r.item == focus;
                      return Material(
                        key: ValueKey('repeater-row-${r.item}'),
                        color: marked ? k.accent.withValues(alpha: 0.14) : k.surface,
                        borderRadius: BorderRadius.circular(i == 0 ? 14 : 4),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: widget.deps.onShowRepeater == null ? null : () => widget.deps.onShowRepeater!(r),
                          onLongPress: () => _hold(r),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text([_freq(r), ?r.town].where((x) => x.isNotEmpty).join(' · '),
                                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                                      Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.secondary)),
                                    ],
                                  ),
                                ),
                                if (dist != null) Text(dist, style: TextStyle(fontSize: 13, color: k.secondary)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        }
        return Scaffold(
          appBar: AppBar(leading: paneShowButton(context), 
            title: Text(list == null ? 'Repeaters' : 'Repeaters: ${list.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              if (list != null)
                PopupMenuButton<String>(
                  key: const ValueKey('repeaters-menu'),
                  onSelected: (_) => _update(list),
                  itemBuilder: (_) => const [PopupMenuItem(value: 'update', child: Text('Update from a file'))],
                ),
            ],
          ),
          body: SafeArea(top: false, child: body),
        );
      },
    );
  }
}
