import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

/// How a piece of a status line is coloured.
enum Tone { normal, ok, warn, danger, quiet }

/// One piece of a status line: "Ready" in the good colour inside "Gemma 4 E2B · Ready · Web search off".
class Part {
  const Part(this.text, [this.tone = Tone.normal]);

  final String text;
  final Tone tone;
}

/// The pieces joined with " · ".
List<Part> joinParts(List<List<Part>> pieces) {
  final out = <Part>[];
  for (final p in pieces) {
    if (p.isEmpty) continue;
    if (out.isNotEmpty) out.add(const Part(' · '));
    out.addAll(p);
  }
  return out;
}

Color toneColor(CacheTokens k, Tone t) => switch (t) {
  Tone.normal => k.secondary,
  Tone.ok => k.ok,
  Tone.warn => k.warning,
  Tone.danger => k.emergency,
  Tone.quiet => k.secondary,
};

/// The small text under a row's name: one short line by default (it ends in an ellipsis), [maxLines] null for a fact that wraps.
Widget statusText(BuildContext context, List<Part> parts, {double size = 13, int? maxLines = 1}) {
  final k = context.t;
  return Text.rich(
    TextSpan(
      children: [for (final p in parts) TextSpan(text: p.text, style: TextStyle(color: toneColor(k, p.tone)))],
      style: TextStyle(fontSize: size, height: 1.35, color: k.secondary),
    ),
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
  );
}

/// A Settings page: a back arrow, the title and the content, with the margins of the design.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children, this.bottom});

  final String title;
  final List<Widget> children;

  /// Something fixed under the list.
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    children[i],
                  ],
                ],
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

class _RowPlace extends InheritedWidget {
  const _RowPlace({required this.first, required this.last, required super.child});

  final bool first;
  final bool last;

  static _RowPlace? of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<_RowPlace>();

  @override
  bool updateShouldNotify(_RowPlace old) => first != old.first || last != old.last;
}

/// A heading over a group, in small capitals.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(fontSize: 12, letterSpacing: 0.7, color: context.t.secondary, fontWeight: FontWeight.w500),
    ),
  );
}

/// Rows stacked tight: round on the outer corners, square on the ones between rows. An optional [label] sits above.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.label, required this.rows});

  final String? label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) GroupLabel(label!),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          _RowPlace(first: i == 0, last: i == rows.length - 1, child: rows[i]),
        ],
      ],
    );
  }
}

/// One row of a group: an optional icon (or other leading widget), a name, a status line and what sits at the end (a chevron by
/// default when it can be tapped).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.status,
    this.statusWidget,
    this.trailing,
    this.onTap,
    this.chevron,
    this.dim = false,
    this.danger = false,
    this.statusLines = 1,
    this.onHold,
    this.holdLabel = 'Options',
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final List<Part>? status;
  final Widget? statusWidget;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Shows a chevron; by default when [onTap] is set and there is no [trailing].
  final bool? chevron;

  /// Greyed (for example a switch that cannot be used yet).
  final bool dim;
  final bool danger;

  /// Lines the status may take; null lets a long fact wrap.
  final int? statusLines;

  /// Press and hold: the row's menu (also in the accessibility actions as [holdLabel]).
  final VoidCallback? onHold;
  final String holdLabel;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final place = _RowPlace.of(context);
    final first = place?.first ?? true;
    final last = place?.last ?? true;
    final radius = BorderRadius.vertical(
      top: Radius.circular(first ? 16 : 4),
      bottom: Radius.circular(last ? 16 : 4),
    );
    final showChevron = chevron ?? (onTap != null && trailing == null);
    final titleColor = danger ? k.emergency : (dim ? k.secondary : k.text);
    final lead = leading ?? (icon == null ? null : Icon(icon, size: 22, color: k.secondary));
    final hold = onHold;
    return Semantics(
      container: true,
      customSemanticsActions: hold == null ? null : {CustomSemanticsAction(label: holdLabel): hold},
      child: Material(
        color: k.surface,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: hold == null
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  hold();
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                children: [
                  if (lead != null) ...[lead, const SizedBox(width: 14)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: titleColor)),
                        if (status != null || statusWidget != null) ...[
                          const SizedBox(height: 2),
                          statusWidget ?? statusText(context, status!, maxLines: statusLines),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 10), trailing!],
                  if (showChevron) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row with a switch. [onChanged] null makes it unusable and dims it.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.status, required this.value, required this.onChanged});

  final String title;
  final List<Part>? status;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final on = onChanged;
    return SettingsRow(
      title: title,
      status: status,
      dim: on == null,
      onTap: on == null ? null : () => on(!value),
      trailing: Switch(value: value, onChanged: on),
    );
  }
}

/// A small outlined button at the end of a row ("Set up", "Replace").
class RowButton extends StatelessWidget {
  const RowButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: k.accent,
        side: BorderSide(color: k.accent, width: 1.5),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: const StadiumBorder(),
      ),
      child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
    );
  }
}

/// The one Advanced row at the bottom of a page.
class AdvancedRow extends StatelessWidget {
  const AdvancedRow({super.key, required this.status, required this.onTap});

  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: k.secondary.withValues(alpha: 0.5), width: 1.5)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Row(
            children: [
              Text('Advanced', style: TextStyle(fontSize: 15, color: k.text)),
              const SizedBox(width: 10),
              Expanded(child: Text(status, textAlign: TextAlign.end, style: TextStyle(fontSize: 14, color: k.secondary))),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line of small explanation under a group.
class NoteText extends StatelessWidget {
  const NoteText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: context.t.secondary)),
  );
}

void say(BuildContext context, String text, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(text), action: action));
}
