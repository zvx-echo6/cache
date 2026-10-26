import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';
import '../../settings/location_access.dart';
import '../../theme.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > Notifications and location: alert pop-ups, quiet hours, ringing through for extreme alerts, and the location permission.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> with WidgetsBindingObserver {
  LocationAccess? _access;

  SettingsDeps get d => widget.deps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the phone's settings: the permission may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _read();
  }

  Future<void> _read() async {
    final a = await d.hub.locationAccess.read();
    if (mounted) setState(() => _access = a);
  }

  Future<void> _locationTapped() async {
    switch (_access) {
      case LocationAccess.denied:
        if (!d.location.enabled) await d.location.setEnabled(true);
        await d.location.request(explain: () async => true);
        await _read();
        if (mounted && _access == LocationAccess.denied) say(context, 'Location was not allowed. You can allow it in the phone\'s settings.');
      case LocationAccess.always || LocationAccess.whileUsing || LocationAccess.blocked || null:
        await d.location.openAppSettings();
    }
  }

  List<Part> _locationStatus() => switch (_access) {
    null => const [Part('Checking…')],
    LocationAccess.always => const [Part('Always', Tone.ok), Part(' · keeps alerts and updates working in the background')],
    LocationAccess.whileUsing => const [Part('While using the app', Tone.warn), Part(' · alerts and updates pause when Cache is closed. Tap to change it.')],
    LocationAccess.denied => const [Part('Off', Tone.warn), Part(' · tap to allow')],
    LocationAccess.blocked => const [Part('Blocked', Tone.danger), Part(" · tap to open the phone's settings")],
  };

  @override
  Widget build(BuildContext context) {
    final s = d.hub.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => SettingsPage(
        title: 'Notifications and location',
        children: [
          SettingsGroup(
            label: 'Pop-ups',
            rows: [
              SwitchRow(
                title: 'Alert pop-ups',
                status: const [Part('Weather alerts and fires near your places')],
                value: s.alertPopups,
                onChanged: s.setAlertPopups,
              ),
              SettingsRow(
                title: 'Quiet hours',
                status: s.quiet.on ? [Part('${s.quiet.label} · alerts still arrive, silently')] : const [Part('Off')],
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuietHoursPage(settings: s))),
              ),
              SwitchRow(
                title: 'Ring through for extreme alerts',
                status: const [Part('Evacuation orders, tornado and flash flood warnings')],
                value: s.ringThroughExtreme,
                onChanged: s.setRingThroughExtreme,
              ),
            ],
          ),
          SettingsGroup(
            label: 'Location',
            rows: [
              SettingsRow(title: 'Location access', status: _locationStatus(), onTap: _locationTapped),
            ],
          ),
          const NoteText('Location is used only on this phone, never sent anywhere.'),
        ],
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
                  status: const [Part('Alerts still arrive, silently')],
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
            const NoteText('Extreme alerts can still ring through. Change that on the page before.'),
          ],
        );
      },
    );
  }
}
