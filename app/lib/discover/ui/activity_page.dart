import 'package:flutter/material.dart';

import '../../layout/adaptive.dart' show ContentWidth;
import '../../maps/ui/format.dart' show formatBytes;
import '../../theme.dart';
import '../discover_state.dart';
import '../ledger.dart';
import '../recipe.dart';
import '../words.dart';
import 'flows.dart';
import 'kit.dart';
import 'progress_page.dart';

/// An activity's page, like an app's listing: its header with Get (Added, Update), what it is for, what it includes, what it
/// connects to, and Customize with the full list of items.
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.discover, required this.activity});

  final DiscoverState discover;
  final Activity activity;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: ListenableBuilder(
      listenable: discover,
      builder: (context, _) => LayoutBuilder(
        builder: (context, c) => ListView(
          padding: ContentWidth.padFor(c.maxWidth, min: 12, maxWidth: 560).copyWith(bottom: 24),
          children: [ActivityListing(discover: discover, activity: activity)],
        ),
      ),
    ),
  );
}

/// The listing itself (also drawn under the Get and Remove sheets).
class ActivityListing extends StatelessWidget {
  const ActivityListing({super.key, required this.discover, required this.activity});

  final DiscoverState discover;
  final Activity activity;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = discover, a = activity;
    final status = d.status(a);
    final chosen = [for (final i in a.items) if (!d.leftOutOf(a).contains(i.key)) i];
    final connects = d.connectsTo([for (final i in chosen) if (i.kind == ItemKind.liveSource) i]);
    return Computed<int>(
      listenable: d,
      compute: () => d.sizeOf(a),
      builder: (context, sized) {
        final size = sized ?? d.totalBytes(a);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              child: Row(
                children: [
                  DTile(discoverIcon(a.icon), size: 64),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: k.text)),
                        const SizedBox(height: 2),
                        Text(a.tagline, style: TextStyle(fontSize: 13, color: k.secondary)),
                        const SizedBox(height: 2),
                        Text(formatBytes(size), key: const ValueKey('activity-size'), style: TextStyle(fontSize: 13, color: k.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: switch (status) {
                ActivityStatus.notAdded => PillButton(key: const ValueKey('activity-get'), label: 'Get', onPressed: () => getActivity(context, d, a)),
                ActivityStatus.update => PillButton(key: const ValueKey('activity-update'), label: 'Update', onPressed: () => updateActivity(context, d, a)),
                ActivityStatus.adding => PillButton(
                    key: const ValueKey('activity-progress'),
                    label: 'Adding… See progress',
                    outlined: true,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProgressPage(discover: d, activities: [a]))),
                  ),
                ActivityStatus.added => PillButton(key: const ValueKey('activity-added'), label: 'Added', outlined: true, onPressed: () => removeActivity(context, d, a)),
              },
            ),
            if (a.description.isNotEmpty) DHint(a.description, top: 8),
            const DLabel('Includes'),
            DChips(labels: includesChips(chosen)),
            if (connects.isNotEmpty) ...[
              const DLabel('Connects to'),
              RowStack(rows: [
                for (final (who, what) in connects) DRow(leading: DTile(discoverIcon('globe')), title: who, subtitle: what),
              ]),
            ],
            const SizedBox(height: 8),
            RowStack(rows: [
              DRow(
                key: const ValueKey('activity-customize'),
                leading: DTile(discoverIcon('sliders')),
                title: 'Customize',
                subtitle: 'Leave items out',
                trailing: Icon(Icons.chevron_right, color: k.secondary, size: 20),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomizePage(discover: d, activity: a))),
              ),
            ]),
          ],
        );
      },
    );
  }
}

/// Customize: every item of the activity with a switch, grouped, and what they add against the free space.
class CustomizePage extends StatelessWidget {
  const CustomizePage({super.key, required this.discover, required this.activity});

  final DiscoverState discover;
  final Activity activity;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: discover,
    builder: (context, _) {
      final d = discover, a = activity;
      final out = d.leftOutOf(a);
      // Every item, switched on or not, planned as if it were on (what it would add, what is shared).
      return Computed<InstallPlan>(
        listenable: d,
        compute: () => d.plan(a, leftOut: const {}),
        builder: (context, plan) {
          final all = plan?.items ?? [for (final i in a.items) PlannedItem(i)];
          final adds = all.where((p) => !out.contains(p.item.key) && p.isNew && p.item.kind.downloads).fold<int>(0, (s, p) => s + d.bytesOf(p.item));
          final sections = <Widget>[];
          for (final g in kGroupOrder) {
            final inGroup = [for (final p in all) if (sameGroup(p.item.kind, g)) p];
            if (inGroup.isEmpty) continue;
            sections
              ..add(DLabel(groupOf(g)))
              ..add(RowStack(rows: [
                for (final p in inGroup)
                  () {
                    final (line, ok) = customizeLine(d, p);
                    final on = !out.contains(p.item.key);
                    return DRow(
                      key: ValueKey('customize-${p.item.key}'),
                      title: itemTitle(d, p.item),
                      subtitle: line,
                      subtitleOk: ok,
                      onTap: () => d.setLeftOut(a, p.item.key, on),
                      trailing: Switch(value: on, onChanged: (v) => d.setLeftOut(a, p.item.key, !v)),
                    );
                  }(),
              ]));
          }
          return Scaffold(
            appBar: AppBar(title: const Text('Customize')),
            body: LayoutBuilder(
              builder: (context, c) => ListView(
                padding: ContentWidth.padFor(c.maxWidth, min: 12, maxWidth: 560).copyWith(bottom: 16),
                children: [const DHint('Switch off anything you do not want.', top: 2), ...sections],
              ),
            ),
            bottomNavigationBar: Dock(
              maxWidth: 560,
              children: [
                SpaceLine(label: (s) => 'Adds $s', bytes: adds, free: d.device.freeBytes()),
                PillButton(
                  key: const ValueKey('customize-done'),
                  label: 'Done',
                  onPressed: () async {
                    // An added activity takes the new choices now: what is switched off is released, and anything switched on is
                    // approved on the Get sheet first.
                    if (d.ledger.has(a.id) && !await applyCustomize(context, d, a)) return;
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
