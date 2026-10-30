import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../theme.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Notifications: the one "Pop up for" choice (Serious only, All alerts, None) and quiet hours. Every alert is listed in
/// Weather either way.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  SettingsDeps get d => widget.deps;

  /// None asks once: Cache will then not interrupt even for an evacuation.
  Future<void> _choose(PopUpFor v) async {
    final s = d.hub.settings;
    if (v == PopUpFor.none && !s.toldNoPopUps) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No pop-ups at all?'),
          content: const Text('Cache will not interrupt you for anything, not even an evacuation order. Alerts are still listed in Weather.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep pop-ups')),
            TextButton(key: const ValueKey('confirm-no-popups'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn off')),
          ],
        ),
      );
      if (ok != true) return;
      s.setToldNoPopUps();
    }
    s.setPopUpFor(v);
  }

  @override
  Widget build(BuildContext context) {
    final s = d.hub.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SettingsPage(
        title: 'Notifications',
        children: [
          SettingsGroup(
            label: 'Pop up for',
            rows: [
              for (final v in PopUpFor.values) _ChoiceRow(choice: v, selected: s.popUpFor == v, onTap: () => _choose(v)),
              SettingsRow(
                key: const ValueKey('quiet-hours'),
                leading: const AlertGlyph(Icons.bedtime_outlined),
                title: 'Quiet hours',
                status: s.quiet.on ? [Part('${formatMinutes(s.quiet.from)}–${formatMinutes(s.quiet.to)} · serious still ring')] : const [Part('Off')],
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuietHoursPage(settings: s))),
              ),
            ],
          ),
          const NoteText('Every alert is listed in Weather either way.'),
        ],
      ),
    );
  }
}

/// The square glyph at the start of an alert row: "!!" on red for serious, "!" on yellow for all, a dash for none. The glyph carries
/// the meaning, so the colour is never the only sign.
class AlertGlyph extends StatelessWidget {
  const AlertGlyph(this.icon, {super.key, this.text, this.color});

  final IconData? icon;
  final String? text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final fill = color ?? k.background;
    final on = color == null ? k.secondary : k.background;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(7)),
      child: text != null
          ? Text(text!, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: on, height: 1))
          : Icon(icon, size: 18, color: on),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.choice, required this.selected, required this.onTap});

  final PopUpFor choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final (String title, String detail, Widget glyph) = switch (choice) {
      PopUpFor.serious => ('Serious only', 'Evacuations, severe warnings, fires within 10 mi', AlertGlyph(null, text: '!!', color: k.emergency)),
      PopUpFor.all => ('All alerts', 'Adds watches and advisories', AlertGlyph(null, text: '!', color: k.warning)),
      PopUpFor.none => ('None', 'Nothing pops up', const AlertGlyph(Icons.remove)),
    };
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: SettingsRow(
        key: ValueKey('popup-${choice.name}'),
        leading: glyph,
        title: title,
        status: [Part(detail)],
        trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? k.accent : k.secondary),
        onTap: onTap,
      ),
    );
  }
}

/// The quiet hours: a switch and the two times.
class QuietHoursPage extends StatelessWidget {
  const QuietHoursPage({super.key, required this.settings});

  final AppSettings settings;

  Future<void> _pick(BuildContext context, {required bool from}) async {
    final q = settings.quiet;
    final at = from ? q.from : q.to;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: at ~/ 60, minute: at % 60),
      helpText: from ? 'Quiet hours start' : 'Quiet hours end',
    );
    if (t == null) return;
    final m = t.hour * 60 + t.minute;
    settings.setQuiet(from ? q.copyWith(from: m) : q.copyWith(to: m));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final q = settings.quiet;
        final k = context.t;
        return SettingsPage(
          title: 'Quiet hours',
          children: [
            SettingsGroup(
              rows: [
                SwitchRow(
                  title: 'Quiet hours',
                  status: const [Part('Alerts arrive silently; serious ones still ring')],
                  value: q.on,
                  onChanged: (v) => settings.setQuiet(q.copyWith(on: v)),
                ),
                SettingsRow(
                  key: const ValueKey('quiet-from'),
                  title: 'From',
                  dim: !q.on,
                  trailing: Text(formatMinutes(q.from), style: TextStyle(fontSize: 17, color: (q.on ? k.text : k.secondary))),
                  chevron: false,
                  onTap: q.on ? () => _pick(context, from: true) : null,
                ),
                SettingsRow(
                  key: const ValueKey('quiet-to'),
                  title: 'To',
                  dim: !q.on,
                  trailing: Text(formatMinutes(q.to), style: TextStyle(fontSize: 17, color: (q.on ? k.text : k.secondary))),
                  chevron: false,
                  onTap: q.on ? () => _pick(context, from: false) : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
