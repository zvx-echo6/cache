import 'package:flutter/material.dart';

import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'entry_point_page.dart';
import 'widgets.dart';

/// "Wi-Fi and local network, 2 entry points": what the Ways to connect row on Sharing and sync says. The count is of the entry points
/// that are on; with none, it is left out. (Only what the engine does today: no Bluetooth until there is a Bluetooth link to say.)
String waysSummary(int entriesOn, {bool bluetooth = false}) => bluetooth ? switch (entriesOn) {
  0 => 'Wi-Fi, Bluetooth and local network',
  1 => 'Wi-Fi, Bluetooth and 1 entry point',
  _ => 'Wi-Fi, Bluetooth and $entriesOn entry points',
} : switch (entriesOn) {
  0 => 'Wi-Fi and local network',
  1 => 'Wi-Fi and local network, 1 entry point',
  _ => 'Wi-Fi and local network, $entriesOn entry points',
};

/// "Wi-Fi", "Wi-Fi and 2 entry points": the first part of This device's line on Sharing and sync.
String thisDeviceWays(int entriesOn, {bool bluetooth = false, bool ipAllowed = true}) => !ipAllowed ? (bluetooth ? 'Bluetooth' : 'No connection') : bluetooth ? switch (entriesOn) {
  0 => 'Wi-Fi and Bluetooth',
  1 => 'Wi-Fi, Bluetooth and 1 entry point',
  _ => 'Wi-Fi, Bluetooth and $entriesOn entry points',
} : switch (entriesOn) {
  0 => 'Wi-Fi',
  1 => 'Wi-Fi and 1 entry point',
  _ => 'Wi-Fi and $entriesOn entry points',
};

/// "Checked just now", "Checked 2 min ago".
String checkedText(int? ms) {
  if (ms == null) return 'Checked just now';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return 'Checked just now';
  if (d.inMinutes < 60) return 'Checked ${d.inMinutes} min ago';
  if (d.inHours < 24) return 'Checked ${d.inHours} h ago';
  return 'Checked ${d.inDays} d ago';
}

/// The state part of an entry point's status line: "Connected", "Not answering" (red, with a warning mark), "Off".
Part entryStateWord(EntryPoint e) => switch (e.state) {
  'off' => const Part('Off'),
  'connected' => const Part('Connected', Tone.ok),
  'not_answering' => const Part('Not answering', Tone.danger, Icons.warning_amber_rounded),
  // No "Network name or passphrase doesn't match" state here: it returns only with an upstream IFAC-failure counter (Prns drops a frame
  // that fails IFAC without one). Inferring it from bytes with no valid frame fired for the right passphrase on a quiet rnsd (2026-11-25).
  'nothing_heard' => const Part('Connected, nothing heard yet'),
  'not_running' => const Part('Not running'),
  _ => const Part('Connecting…'),
};

/// Settings > Sharing and sync > Ways to connect: the entry points under "Over the internet" the ones the person
/// added, each opening its page with its own switch beside it, then "Add an entry point". The Wi-Fi and Bluetooth rows of the design are
/// left out until there are switches that do something.
class WaysToConnectPage extends StatefulWidget {
  const WaysToConnectPage({super.key, required this.sharing});

  final SharingState sharing;

  @override
  State<WaysToConnectPage> createState() => _WaysToConnectPageState();
}

class _WaysToConnectPageState extends State<WaysToConnectPage> {
  SharingState get s => widget.sharing;
  bool _busy = false;

  Future<void> _on(EntryPoint e, bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await s.entryPointOn(e.id, on);
    } catch (err) {
      if (mounted) say(context, '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(EntryPoint e) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EntryPointPage(sharing: s, id: e.id)));

  void _add() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EntryPointPage(sharing: s)));

  Future<void> _bluetooth(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await s.setBluetooth(on); } catch (e) { if (mounted) say(context, '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _allowBluetooth() async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await s.allowBluetooth(); } catch (e) { if (mounted) say(context, '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = s.entries;
        return SettingsPage(
          title: 'Ways to connect',
          children: [
            const NoteText("Cache uses every way that's on to reach your other devices."),
            if (s.bluetoothStatus.supported) ...[
              SettingsGroup(rows: [SettingsRow(
                key: const ValueKey('bluetooth-way'),
                icon: Icons.bluetooth,
                title: 'Bluetooth',
                status: [Part(!s.bluetoothWanted ? 'Off' : s.bluetoothStatus.error != null ? 'Bluetooth could not start'
                  : s.bluetoothStatus.permissions.isNotEmpty ? 'Permission needed'
                  : !s.bluetoothStatus.enabled ? 'Turn on Bluetooth on this device'
                  : s.bluetoothStatus.active ? 'Ready for nearby devices' : 'Starting…')],
                trailing: Switch(value: s.bluetoothWanted, onChanged: _busy ? null : _bluetooth),
                onTap: _busy ? null : () => _bluetooth(!s.bluetoothWanted),
              )]),
              if (s.bluetoothWanted && s.bluetoothStatus.permissions.isNotEmpty)
                OutlinedButton(onPressed: _busy ? null : _allowBluetooth, child: const Text('Allow Bluetooth')),
              const NoteText('Bluetooth peering runs while Cache is open. Small changes can sync without Wi-Fi or mobile data.'),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GroupLabel('Over the internet'),
                const NoteText("Add Reticulum entry points to reach your devices from anywhere. Every one that's on is used at the same time."),
                const SizedBox(height: 10),
                if (list.isEmpty)
                  Material(
                    key: const ValueKey('no-entries'),
                    color: k.surface,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('No entry points yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 2),
                          _Plain(s.bluetoothWanted && s.bluetoothStatus.enabled ? 'Your devices can connect over Wi-Fi or Bluetooth.' : 'For now your devices connect only over Wi-Fi.'),
                        ],
                      ),
                    ),
                  )
                else
                  SettingsGroup(
                    rows: [for (final e in list) _EntryRow(entry: e, busy: _busy, onOpen: () => _open(e), onOn: (v) => _on(e, v))],
                  ),
              ],
            ),
            OutlinedButton.icon(
              key: const ValueKey('add-entry'),
              icon: const Icon(Icons.add),
              label: const Text('Add an entry point'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _add,
            ),
            const NoteText('Cache comes with none and only uses ones you add. They sync to your other linked devices. Nothing goes through our servers.'),
          ],
        );
      },
    );
  }
}

class _Plain extends StatelessWidget {
  const _Plain(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 13, height: 1.35, color: context.t.secondary));
}

/// One entry point: its text opens its page; its switch sits beside a divider.
class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.busy, required this.onOpen, required this.onOn});

  final EntryPoint entry;
  final bool busy;
  final VoidCallback onOpen;
  final ValueChanged<bool> onOn;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final e = entry;
    final off = !e.on;
    return SettingsRow(
      key: ValueKey('entry-${e.id}'),
      icon: Icons.public,
      title: e.host,
      dim: off,
      status: [
        if (e.private) const Part('Private', Tone.normal, Icons.lock_outline),
        if (e.private) const Part(' · '),
        Part('Port ${e.port}'),
        const Part(' · '),
        entryStateWord(e),
      ],
      statusLines: 2,
      chevron: false,
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
          const SizedBox(width: 10),
          Container(width: 1, height: 40, color: k.secondary.withValues(alpha: 0.3)),
          const SizedBox(width: 10),
          Switch(key: ValueKey('entry-switch-${e.id}'), value: e.on, onChanged: busy ? null : onOn),
        ],
      ),
    );
  }
}
