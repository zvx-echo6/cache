import 'package:flutter/material.dart';

import '../../downloads/download_row.dart';
import '../../layout/adaptive.dart' show ContentWidth;
import '../../theme.dart';
import '../discover_state.dart';
import '../recipe.dart';
import '../words.dart';
import 'kit.dart';

/// Adding an activity: each download in the app's own download row pattern (title, one status line, the bar, one control), the
/// things made on the device as one row a group, and the search index work in its own words. Leaving the page changes nothing.
class ProgressPage extends StatelessWidget {
  const ProgressPage({super.key, required this.discover, required this.activities});

  final DiscoverState discover;
  final List<Activity> activities;

  String get _title => activities.length == 1 ? 'Adding ${activities.first.title}' : 'Adding ${activities.map((a) => a.title).join(' and ')}';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis)),
    body: ListenableBuilder(listenable: discover, builder: (context, _) => _body(context)),
    bottomNavigationBar: Dock(maxWidth: 560, children: [PillButton(key: const ValueKey('progress-hide'), label: 'Hide', outlined: true, onPressed: () => Navigator.of(context).maybePop())]),
  );

  Widget _body(BuildContext context) {
    final k = context.t;
    final d = discover;
    // Every item once, in the recipes' order.
    final seen = <String>{};
    final items = <(Activity, RecipeItem, DlState)>[];
    for (final a in activities) {
      for (final (i, s) in d.progress(a)) {
        if (seen.add(i.key)) items.add((a, i, s));
      }
    }
    final downloads = [for (final x in items) if (x.$2.kind.downloads) x];
    final groups = <String, List<(Activity, RecipeItem, DlState)>>{};
    for (final x in items.where((x) => !x.$2.kind.downloads)) {
      groups.putIfAbsent(groupOf(x.$2.kind), () => []).add(x);
    }
    final rows = downloads.length + groups.length;
    final done = downloads.where((x) => x.$3.phase == DlPhase.done).length + groups.length;
    final current = downloads.where((x) => x.$3.active).firstOrNull;
    final libs = [for (final x in downloads) if (x.$2.kind == ItemKind.library) x];
    final searchWaits = [
      for (final x in libs)
        if (d.device.searchLine(x.$2) case final line?) '${itemTitle(d, x.$2)} · ${line[0].toLowerCase()}${line.substring(1)}',
    ];
    return LayoutBuilder(
      builder: (context, c) => ListView(
        padding: ContentWidth.padFor(c.maxWidth, min: 12, maxWidth: 560).copyWith(top: 4, bottom: 16),
        children: [
          Container(
            key: const ValueKey('progress-card'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('$_title · $done of $rows done', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                if (current != null) ...[
                  const SizedBox(height: 2),
                  Text('${itemTitle(d, current.$2)} · ${dlBytes(current.$3.done, current.$3.total)}', style: TextStyle(fontSize: 13, color: k.secondary)),
                ],
                const SizedBox(height: 8),
                SpaceBar(fraction: rows == 0 ? 1 : (done + (current?.$3.fraction ?? 0)) / rows),
              ],
            ),
          ),
          const DLabel('Downloads'),
          RowStack(rows: [
            for (final (a, i, s) in downloads) _downloadRow(context, a, i, s),
            for (final e in groups.entries)
              DRow(key: ValueKey('progress-group-${e.key}'), title: e.key, subtitle: 'Done', subtitleOk: true, trailing: const _Done()),
          ]),
          if (libs.isNotEmpty) ...[
            const DLabel('Search'),
            RowStack(rows: [
              DRow(
                key: const ValueKey('progress-search'),
                title: searchWaits.isEmpty ? 'Search ready' : 'Getting search ready',
                subtitle: searchWaits.firstOrNull,
              ),
            ]),
          ],
          const DHint('You can leave this screen. It keeps going.'),
        ],
      ),
    );
  }

  Widget _downloadRow(BuildContext context, Activity a, RecipeItem i, DlState s) {
    final d = discover;
    var actions = d.device.actionsOf(context, i);
    // A download that could not start (no connection then) is tried again from its row.
    if (s.phase == DlPhase.failed && actions.resume == null) actions = DlActions(resume: () => d.retry(a, i), remove: actions.remove);
    return DRow(
      key: ValueKey('progress-${i.key}'),
      title: itemTitle(d, i),
      below: Padding(padding: const EdgeInsets.only(top: 2), child: DlStatus(state: s, actions: actions, done: 'Done', keyBase: 'progress-${i.key}')),
      trailing: s.phase == DlPhase.done ? const _Done() : dlControl(context, s, actions, keyBase: 'progress-${i.key}'),
    );
  }
}

class _Done extends StatelessWidget {
  const _Done();

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: k.ok, shape: BoxShape.circle),
      child: Icon(Icons.check, size: 16, color: k.surface),
    );
  }
}
