import 'package:flutter/material.dart';

import '../../layout/adaptive.dart' show showFittedSheet;
import '../../maps/ui/format.dart' show formatBytes;
import '../../theme.dart';
import '../discover_state.dart';
import '../ledger.dart';
import '../recipe.dart';
import '../words.dart';
import 'kit.dart';

/// What the Get sheet says before anything installs: the total size against the free space, every outside source it connects
/// to, the settings it changes, and (behind "Show everything it adds") every item.
class GetSheetData {
  const GetSheetData({
    required this.icon,
    required this.title,
    required this.bytes,
    required this.free,
    this.connects = const [],
    this.changes = const [],
    this.downloads = const [],
    this.changeLines = const [],
    this.verb = 'Get',
  });

  final IconData icon;

  /// "Add Backcountry".
  final String title;
  final int bytes;
  final int? free;

  /// Who it connects to, and what for.
  final List<(String, String)> connects;

  /// The settings it changes (for the one-line summary).
  final List<SettingChange> changes;

  /// Every item it adds, one line each.
  final List<String> downloads;

  /// Every setting it changes, one line each.
  final List<String> changeLines;

  /// The button: Get, or Update.
  final String verb;

  bool get tooBig => free != null && bytes > free!;
}

/// The Get sheet for [a] with the person's Customize choices.
Future<GetSheetData> activitySheetData(DiscoverState d, Activity a, {String verb = 'Get'}) async {
  final p = await d.plan(a);
  return GetSheetData(
    icon: discoverIcon(a.icon),
    title: '${verb == 'Get' ? 'Add' : 'Update'} ${a.title}',
    bytes: d.addsBytes(p),
    free: d.device.freeBytes(),
    connects: d.connectsTo([for (final x in p.items) if (x.item.kind == ItemKind.liveSource ? x.isNew || x.already : x.isNew) x.item]),
    changes: p.changes,
    downloads: planDownloadLines(d, p),
    changeLines: [for (final c in p.changes) settingWords(d, c.key, c.after)],
    verb: verb,
  );
}

/// The Get sheet for libraries the person gets themselves (a library tile, a collection).
Future<GetSheetData> itemsSheetData(DiscoverState d, {required String title, required IconData icon, required Iterable<RecipeItem> items}) async {
  final missing = await d.missing(items);
  return GetSheetData(
    icon: icon,
    title: 'Add $title',
    bytes: missing.fold(0, (s, i) => s + d.bytesOf(i)),
    free: d.device.freeBytes(),
    connects: d.connectsTo(missing),
    downloads: [for (final i in missing) [itemTitle(d, i), ?itemSize(d, i)].join(' · ')],
  );
}

/// Shows the Get sheet; true when the person tapped Get.
Future<bool> showGetSheet(BuildContext context, GetSheetData data) async =>
    await showFittedSheet<bool>(context: context, showDragHandle: true, builder: (ctx) => GetSheet(data: data, onGet: () => Navigator.pop(ctx, true), onCancel: () => Navigator.pop(ctx, false))) ??
    false;

class GetSheet extends StatefulWidget {
  const GetSheet({super.key, required this.data, required this.onGet, required this.onCancel, this.startOpen = false});

  final GetSheetData data;
  final VoidCallback onGet;
  final VoidCallback onCancel;

  /// Opens with the details showing (renders).
  final bool startOpen;

  @override
  State<GetSheet> createState() => _GetSheetState();
}

class _GetSheetState extends State<GetSheet> {
  late bool _open = widget.startOpen;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = widget.data;
    final free = d.free;
    final summary = changesSummary(d.changes);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const ValueKey('get-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHead(
              icon: d.icon,
              title: d.title,
              line: [formatBytes(d.bytes), if (free != null) '${formatBytes(free)} free'].join(' · '),
              lineWarn: d.tooBig ? 'Needs ${formatBytes(d.bytes - free!)} more free space' : null,
            ),
            if (d.connects.isNotEmpty) ...[
              const SizedBox(height: 10),
              FactRow(key: const ValueKey('get-connects'), label: 'Connects to', value: d.connects.map((c) => c.$1).join(', ')),
            ],
            if (summary != null) ...[
              const SizedBox(height: 10),
              FactRow(key: const ValueKey('get-changes'), label: 'Changes', value: summary),
            ],
            const SizedBox(height: 4),
            SeeAllToggle(key: const ValueKey('get-details'), label: _open ? 'Hide details' : 'Show everything it adds', open: _open, onTap: () => setState(() => _open = !_open)),
            if (_open) ...[
              if (d.downloads.isNotEmpty) ...[const DLabel('Downloads'), MiniList(key: const ValueKey('get-downloads'), lines: d.downloads)],
              if (d.connects.isNotEmpty) ...[const DLabel('Connects to'), MiniList(lines: [for (final c in d.connects) '${c.$1} · ${c.$2}'])],
              if (d.changeLines.isNotEmpty) ...[const DLabel('Changes'), MiniList(key: const ValueKey('get-change-lines'), lines: d.changeLines)],
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
            PillButton(key: const ValueKey('get-confirm'), label: d.verb, onPressed: d.tooBig ? null : widget.onGet),
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('get-cancel'),
              onPressed: widget.onCancel,
              style: TextButton.styleFrom(foregroundColor: k.accent, textStyle: buttonText(context, 14, FontWeight.w500)),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHead extends StatelessWidget {
  const _SheetHead({required this.icon, required this.title, required this.line, this.lineWarn});

  final IconData icon;
  final String title;
  final String line;
  final String? lineWarn;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          DTile(icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: k.text)),
                Text(line, key: const ValueKey('sheet-size'), style: TextStyle(fontSize: 13, color: k.secondary)),
                if (lineWarn != null) Text(lineWarn!, key: const ValueKey('sheet-too-big'), style: TextStyle(fontSize: 13, color: k.emergency)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the Remove sheet says: what goes, what stays and why, and the settings put back.
class RemoveSheetData {
  const RemoveSheetData({required this.icon, required this.title, required this.frees, required this.goes, required this.kept, required this.restores, required this.keptSettings});

  final IconData icon;
  final String title;
  final int frees;
  final List<String> goes;
  final List<String> kept;
  final List<String> restores;
  final List<String> keptSettings;
}

Future<RemoveSheetData> removeSheetData(DiscoverState d, Activity a) async {
  final p = await d.planRemove(a);
  return RemoveSheetData(
    icon: discoverIcon(a.icon),
    title: a.title,
    frees: p.goes.where((i) => i.kind.downloads).fold(0, (s, i) => s + d.bytesOf(i)),
    goes: [for (final i in p.goes) [itemTitle(d, i), ?itemSize(d, i)].join(' · ')],
    kept: [for (final (i, why) in p.kept) '${itemTitle(d, i)} · $why'],
    restores: [for (final c in p.restores) settingWords(d, c.key, c.after)],
    keptSettings: [for (final k in p.keptSettings) '${settingWords(d, k, d.device.readSetting(k))} · kept'],
  );
}

/// Shows the Remove sheet; true when the person tapped Remove.
Future<bool> showRemoveSheet(BuildContext context, RemoveSheetData data) async =>
    await showFittedSheet<bool>(context: context, showDragHandle: true, builder: (ctx) => RemoveSheet(data: data, onRemove: () => Navigator.pop(ctx, true), onCancel: () => Navigator.pop(ctx, false))) ??
    false;

class RemoveSheet extends StatefulWidget {
  const RemoveSheet({super.key, required this.data, required this.onRemove, required this.onCancel});

  final RemoveSheetData data;
  final VoidCallback onRemove;
  final VoidCallback onCancel;

  @override
  State<RemoveSheet> createState() => _RemoveSheetState();
}

class _RemoveSheetState extends State<RemoveSheet> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final d = widget.data;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const ValueKey('remove-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHead(icon: d.icon, title: 'Remove ${d.title}?', line: 'Frees ${formatBytes(d.frees)}'),
            const SizedBox(height: 10),
            const FactRow(label: 'Kept', value: 'Your notes, places and settings you changed'),
            const SizedBox(height: 4),
            SeeAllToggle(key: const ValueKey('remove-details'), label: _open ? 'Hide details' : 'Show details', open: _open, onTap: () => setState(() => _open = !_open)),
            if (_open) ...[
              if (d.goes.isNotEmpty) ...[const DLabel('Removes'), MiniList(lines: d.goes)],
              if (d.kept.isNotEmpty) ...[const DLabel('Stays'), MiniList(lines: d.kept)],
              if (d.restores.isNotEmpty) ...[const DLabel('Settings put back'), MiniList(lines: d.restores)],
              if (d.keptSettings.isNotEmpty) ...[const DLabel('Settings left as they are'), MiniList(lines: d.keptSettings)],
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
            PillButton(key: const ValueKey('remove-confirm'), label: 'Remove', outlined: true, danger: true, onPressed: widget.onRemove),
            const SizedBox(height: 4),
            TextButton(
              onPressed: widget.onCancel,
              style: TextButton.styleFrom(foregroundColor: k.accent, textStyle: buttonText(context, 14, FontWeight.w500)),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
