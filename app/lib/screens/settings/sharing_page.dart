import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../maps/ui/format.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'widgets.dart';

/// Settings > Sharing and sync: this device's identity, linked devices, what it shares, and transfers.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key, required this.sharing});

  final SharingState sharing;

  @override
  State<SharingPage> createState() => _SharingPageState();
}

String _ago(int? ms) {
  if (ms == null) return 'never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

class _SharingPageState extends State<SharingPage> {
  SharingState get s => widget.sharing;
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) say(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCode() => _run(() async {
    final code = await s.linkCode();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Link code for ${s.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Works once, for 15 minutes', style: TextStyle(color: ctx.t.secondary)),
              const SizedBox(height: 14),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: QrImageView(data: code, size: 260, backgroundColor: Colors.white, errorCorrectionLevel: QrErrorCorrectLevel.L),
              ),
              const SizedBox(height: 12),
              SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 11), maxLines: 4),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy code'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  say(ctx, 'Copied');
                },
              ),
            ],
          ),
        ),
      ),
    );
  });

  Future<void> _enterCode() async {
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter a link code'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'CACHE1-…', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final clip = await Clipboard.getData('text/plain');
              if (clip?.text != null) ctl.text = clip!.text!;
            },
            child: const Text('Paste'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Link')),
        ],
      ),
    );
    if (code == null || code.isEmpty) return;
    await _run(() async {
      final name = await s.link(code);
      if (mounted) say(context, 'Linked with $name');
    });
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await _run(() => s.rename(name));
  }

  Future<void> _peer(Map<String, dynamic> p) async {
    final unlink = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(p['name'] as String? ?? ''), subtitle: SelectableText(p['id'] as String? ?? '', style: const TextStyle(fontSize: 11))),
            ListTile(
              leading: Icon(Icons.link_off, color: ctx.t.emergency),
              title: Text('Unlink', style: TextStyle(color: ctx.t.emergency)),
              subtitle: const Text('It can no longer connect to this device. Files already here stay.'),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
    if (unlink == true) await _run(() => s.unlink(p['id'] as String));
  }

  List<Part> _peerStatus(Map<String, dynamic> p) {
    final err = p['error'] as String?;
    final seen = p['last_seen'] as int?;
    if (err == null && seen != null) {
      return [Part(p['via'] == 'relay' ? 'Connected through a relay' : 'Connected directly', Tone.ok), Part(' · ${_ago(seen)}')];
    }
    if (err != null) return [const Part('Not reachable', Tone.warn), Part(' · last seen ${_ago(seen)}')];
    return const [Part('Checking…')];
  }

  List<Part> _kindStatus(ShareKind k) {
    final sh = s.shareOf(k.id);
    final offers = s.offersOf(k.id);
    if (sh == null) {
      if (offers.isEmpty) return const [Part('Not shared', Tone.quiet)];
      return [
        for (final o in offers) Part('${o['peer_name']} has ${o['files']} files, ${formatBytes(o['bytes'] as int)}'),
        const Part(' · tick to get them'),
      ];
    }
    final parts = [Part('${sh['files']} files · ${formatBytes(sh['bytes'] as int)}')];
    final pending = sh['pending_files'] as int? ?? 0;
    if (pending > 0) parts.add(Part(' · $pending to get, ${formatBytes(sh['pending_bytes'] as int)}', Tone.warn));
    return parts;
  }

  Future<void> _toggle(ShareKind k, bool on) async {
    if (on) {
      final offered = s.offersOf(k.id).fold<int>(0, (n, o) => n + (o['bytes'] as int));
      final free = s.status['free_bytes'] as int?;
      final reserve = s.status['reserve_bytes'] as int? ?? 0;
      if (offered > 0 && free != null && offered > free - reserve) {
        say(context, '${k.label} from the other device is ${formatBytes(offered)}; ${formatBytes(free)} is free. It will fetch what fits and pause.');
      }
    }
    await _run(() => s.setShared(k, on));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (!s.enabled) {
          return SettingsPage(
            title: 'Sharing and sync',
            children: [
              const NoteText(
                'Link your Cache devices and keep their library, maps, models and videos the same, over Wi-Fi nearby or the internet. '
                'Devices talk to each other directly; nothing goes through a Cache server. Setting up creates this device\'s identity.',
              ),
              FilledButton(onPressed: _busy ? null : () => _run(s.setUp), child: const Text('Set up sharing')),
            ],
          );
        }
        if (!s.running) {
          return SettingsPage(
            title: 'Sharing and sync',
            children: [
              if (s.starting) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
              if (s.error != null) NoteText(s.error!),
              if (!s.starting) FilledButton(onPressed: () => _run(s.init), child: const Text('Try again')),
            ],
          );
        }
        final st = s.status;
        final relay = st['relay'] as String?;
        final online = st['network'] == true;
        final t = s.transfer;
        return SettingsPage(
          title: 'Sharing and sync',
          children: [
            SettingsGroup(
              label: 'This device',
              rows: [
                SettingsRow(
                  icon: Icons.smartphone,
                  title: s.name,
                  status: [
                    online ? Part(relay != null ? 'Online' : 'Local network only', relay != null ? Tone.ok : Tone.warn) : const Part('Paused: no network it may use', Tone.warn),
                    if (st['free_bytes'] is int) Part(' · ${formatBytes(st['free_bytes'] as int)} free, keeps ${formatBytes(st['reserve_bytes'] as int)} free'),
                  ],
                  onTap: _rename,
                ),
              ],
            ),
            SettingsGroup(
              label: 'Linked devices',
              rows: [
                for (final p in s.peers)
                  SettingsRow(icon: Icons.devices_other, title: p['name'] as String? ?? '', status: _peerStatus(p), onTap: () => _peer(p)),
                SettingsRow(icon: Icons.qr_code_2, title: 'Show my link code', onTap: _busy ? null : _showCode),
                SettingsRow(icon: Icons.keyboard_outlined, title: 'Enter a link code', onTap: _busy ? null : _enterCode),
              ],
            ),
            SettingsGroup(
              label: 'Shared with linked devices',
              rows: [
                for (final k in s.kinds)
                  SettingsRow(
                    title: k.label,
                    status: _kindStatus(k),
                    trailing: Checkbox(value: s.shareOf(k.id) != null, onChanged: _busy ? null : (v) => _toggle(k, v ?? false)),
                    onTap: _busy ? null : () => _toggle(k, s.shareOf(k.id) == null),
                  ),
              ],
            ),
            if (t != null)
              SettingsGroup(
                label: 'Transfer',
                rows: [
                  SettingsRow(
                    title: '${t['share']}: ${t['path']}',
                    statusWidget: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: (t['size'] as int) == 0 ? null : (t['done'] as int) / (t['size'] as int)),
                        const SizedBox(height: 4),
                        Text('${formatBytes(t['done'] as int)} of ${formatBytes(t['size'] as int)} from ${(t['from'] as List).join(', ')}'),
                      ],
                    ),
                  ),
                ],
              ),
            if (s.paused != null) NoteText(s.paused!),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [TextButton.icon(icon: const Icon(Icons.sync), label: const Text('Sync now'), onPressed: _busy ? null : () => _run(s.syncNow))],
            ),
            const NoteText('Files and folders whose names start with a dot are never shared. Unticking stops sharing; the files stay on this device.'),
            _Log(entries: [for (final e in (st['log'] as List? ?? const [])) (e as Map).cast<String, dynamic>()]),
          ],
        );
      },
    );
  }
}

class _Log extends StatelessWidget {
  const _Log({required this.entries});

  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      title: const Text('Activity'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 6),
      children: [
        for (final e in entries.take(30))
          ListTile(
            dense: true,
            title: Text(e['text'] as String? ?? ''),
            trailing: Text(_ago(e['at'] as int?), style: TextStyle(color: context.t.secondary, fontSize: 12)),
          ),
      ],
    );
  }
}
