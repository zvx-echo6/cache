import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../maps/ui/format.dart';
import '../../settings/data_kinds.dart';
import '../../sharing/settings_sync.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'settings_link_pages.dart';
import 'widgets.dart';

/// Settings > Sharing and sync: this device's identity, linked devices, what it shares, and transfers.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key, required this.sharing, this.settingsSync});

  final SharingState sharing;

  /// Settings between linked devices (each device's page); null where the app has none (tests).
  final SettingsSync? settingsSync;

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

  Future<void> _peer(Map<String, dynamic> p) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharingDevicePage(sharing: s, peer: p['id'] as String, settingsSync: widget.settingsSync)));

  Future<void> _kind(DataKind k) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharingKindPage(sharing: s, kind: k)));

  Future<void> _toggle(DataKind k, bool on) => toggleKind(context, s, k, on, _run);

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
                  SettingsRow(
                    key: ValueKey('peer-${p['id']}'),
                    icon: Icons.devices_other,
                    title: p['name'] as String? ?? '',
                    status: peerStatus(p),
                    onTap: () => _peer(p),
                  ),
                SettingsRow(icon: Icons.qr_code_2, title: 'Show my link code', onTap: _busy ? null : _showCode),
                SettingsRow(icon: Icons.keyboard_outlined, title: 'Enter a link code', onTap: _busy ? null : _enterCode),
              ],
            ),
            SettingsGroup(
              label: 'Shared with linked devices',
              rows: [
                for (final k in s.shareKinds)
                  SettingsRow(
                    key: ValueKey('share-${k.id}'),
                    title: k.sharingLabel,
                    status: kindSummary(s, k),
                    chevron: false,
                    // The row opens the kind; the switch turns the whole kind on or off.
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_right, color: context.t.secondary.withValues(alpha: 0.8)),
                        const SizedBox(width: 10),
                        Switch(value: s.kindOn(k), onChanged: _busy ? null : (v) => _toggle(k, v)),
                      ],
                    ),
                    onTap: () => _kind(k),
                  ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  key: const ValueKey('sync-all'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync all now'),
                  onPressed: _busy ? null : () => _run(s.syncNow),
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
            const NoteText(
              'Tap a kind to choose what of it is shared. Switching a kind or an item off stops sharing it; the files stay, here and on '
              'the other devices. Files and folders whose names start with a dot are never shared.',
            ),
            _Log(entries: [for (final e in (st['log'] as List? ?? const [])) (e as Map).cast<String, dynamic>()]),
          ],
        );
      },
    );
  }
}

/// "Connected directly · 2 min ago", "Not reachable · last seen 3 h ago".
List<Part> peerStatus(Map<String, dynamic> p) {
  final err = p['error'] as String?;
  final seen = p['last_seen'] as int?;
  if (err == null && seen != null) {
    return [Part(p['via'] == 'relay' ? 'Connected through a relay' : 'Connected directly', Tone.ok), Part(' · ${_ago(seen)}')];
  }
  if (err != null) return [const Part('Not reachable', Tone.warn), Part(' · last seen ${_ago(seen)}')];
  return const [Part('Checking…')];
}

/// A kind's line: "4 of 6 shared · 11.3 GB", "Not shared".
List<Part> kindSummary(SharingState s, DataKind k) {
  if (!s.kindOn(k)) {
    final offers = s.offersOfKind(k);
    if (offers.isEmpty) return const [Part('Not shared', Tone.quiet)];
    final bytes = offers.fold<int>(0, (n, o) => n + ((o['bytes'] as num?)?.toInt() ?? 0));
    final who = {for (final o in offers) if (o['peer_name'] is String) o['peer_name'] as String}.join(', ');
    return [const Part('Not shared', Tone.quiet), Part(' · $who has ${formatBytes(bytes)}')];
  }
  final items = s.itemsOf(k);
  final on = [for (final i in items) if (s.itemOn(k, i.item)) i];
  final parts = [
    Part(items.isEmpty ? 'Shared · nothing yet' : '${on.length} of ${items.length} shared · ${formatBytes(on.fold<int>(0, (n, i) => n + i.bytes))}'),
  ];
  final shares = s.sharesOfKind(k);
  int sum(String f) => shares.fold(0, (n, sh) => n + ((sh[f] as num?)?.toInt() ?? 0));
  if (sum('pending_files') > 0) parts.add(Part(' · ${formatBytes(sum('pending_bytes'))} to get', Tone.warn));
  return parts;
}

/// Turns a whole kind on or off; switching it on says first when what the other devices hold of it is more than fits.
Future<void> toggleKind(BuildContext context, SharingState s, DataKind k, bool on, Future<void> Function(Future<void> Function()) run) async {
  if (on) {
    final offered = s.offersOfKind(k).fold<int>(0, (n, o) => n + ((o['bytes'] as num?)?.toInt() ?? 0));
    final free = s.status['free_bytes'] as int?;
    final reserve = s.status['reserve_bytes'] as int? ?? 0;
    if (offered > 0 && free != null && offered > free - reserve) {
      say(context, '${k.sharingLabel} from the other device is ${formatBytes(offered)}; ${formatBytes(free)} is free. It will fetch what fits and pause.');
    }
  }
  await run(() => s.setShared(k, on));
}

/// Settings > Sharing and sync > a kind (Library, Maps, ...): the kind's switch, Sync all, and every item with its own switch
/// and Sync now. New items follow the kind's switch; a private notebook starts off.
class SharingKindPage extends StatefulWidget {
  const SharingKindPage({super.key, required this.sharing, required this.kind});

  final SharingState sharing;
  final DataKind kind;

  @override
  State<SharingKindPage> createState() => _SharingKindPageState();
}

/// "New libraries and ZIMs you add follow the Share Library switch."
String _newItemsNote(DataKind k) {
  const keep = 'Turning one off keeps your copy and theirs.';
  return switch (k.id) {
    'library' => 'New libraries and ZIMs you add follow the Share ${k.sharingLabel} switch. $keep',
    'regions' => 'New map layers follow the Share ${k.sharingLabel} switch. Directions, places and off-road are shared together, for every region. $keep',
    'models' => 'New models you add follow the Share ${k.sharingLabel} switch. $keep',
    'notebooks' => 'New notebooks you add follow the Share ${k.sharingLabel} switch. Private notebooks start off. $keep',
    'videos' => 'New videos you save follow the Share ${k.sharingLabel} switch. $keep',
    _ => 'New items follow the Share ${k.sharingLabel} switch. $keep',
  };
}

/// "1.4 GB · on Desk · Private".
List<Part>? _itemDetail(SharedItem i) {
  final parts = joinParts([
    if (i.bytes > 0) [Part(formatBytes(i.bytes))],
    if (!i.here && i.peers.isNotEmpty) [Part('on ${i.peers.join(', ')}')],
    if (i.item.private) [const Part('Private')],
  ]);
  return parts.isEmpty ? null : parts;
}

class _SharingKindPageState extends State<SharingKindPage> {
  SharingState get s => widget.sharing;
  DataKind get k => widget.kind;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    s.refreshItems();
  }

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

  Future<void> _sync(Future<void> Function() f, String done) => _run(() async {
    await f();
    if (mounted) say(context, done);
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final on = s.kindOn(k);
        final items = s.itemsOf(k)..sort((a, b) => a.item.name.toLowerCase().compareTo(b.item.name.toLowerCase()));
        return SettingsPage(
          title: k.sharingLabel,
          children: [
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('kind-switch'),
                  title: 'Share ${k.sharingLabel}',
                  status: kindSummary(s, k),
                  trailing: Switch(value: on, onChanged: _busy || !s.running ? null : (v) => toggleKind(context, s, k, v, _run)),
                  onTap: _busy || !s.running ? null : () => toggleKind(context, s, k, !on, _run),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(child: GroupLabel('Items')),
                    TextButton.icon(
                      key: const ValueKey('kind-sync'),
                      icon: const Icon(Icons.sync, size: 20),
                      label: const Text('Sync all'),
                      onPressed: _busy || !on ? null : () => _sync(() => s.syncKind(k), 'Syncing ${k.sharingLabel}'),
                    ),
                  ],
                ),
                if (items.isEmpty)
                  NoteText('Nothing of ${k.sharingLabel} on this device or the linked devices yet.')
                else
                  SettingsGroup(
                    rows: [
                      for (final i in items)
                        _ItemRow(
                          key: ValueKey('item-${i.item.key}'),
                          item: i,
                          on: s.itemOn(k, i.item),
                          busy: _busy,
                          onChanged: (v) => _run(() => s.setItem(k, i.item, v)),
                          onSync: () => _sync(() => s.syncItem(i.item), 'Syncing ${i.item.name}'),
                        ),
                    ],
                  ),
              ],
            ),
            NoteText(_newItemsNote(k)),
          ],
        );
      },
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({super.key, required this.item, required this.on, required this.busy, required this.onChanged, required this.onSync});

  final SharedItem item;
  final bool on;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final name = item.item.name;
    return SettingsRow(
      title: name,
      status: _itemDetail(item),
      onTap: busy ? null : () => onChanged(!on),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Sync $name now',
            icon: const Icon(Icons.sync, size: 20),
            color: context.t.secondary,
            onPressed: busy || !on ? null : onSync,
          ),
          const SizedBox(width: 4),
          Switch(value: on, onChanged: busy ? null : onChanged),
        ],
      ),
    );
  }
}

/// Settings > Sharing and sync > a linked device: how it is connected and when it was last seen, its free space when it says,
/// how settings go between the two (Settings), Sync now with it alone, Rename (what this device calls it) and Unlink.
class SharingDevicePage extends StatefulWidget {
  const SharingDevicePage({super.key, required this.sharing, required this.peer, this.settingsSync});

  final SharingState sharing;

  /// Settings between linked devices; null where the app has none (tests).
  final SettingsSync? settingsSync;

  /// The device's key.
  final String peer;

  @override
  State<SharingDevicePage> createState() => _SharingDevicePageState();
}

class _SharingDevicePageState extends State<SharingDevicePage> {
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

  Future<void> _rename(String now) async {
    final ctl = TextEditingController(text: now);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(key: const ValueKey('peer-name'), controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && name != now) await _run(() => s.renamePeer(widget.peer, name));
  }

  Future<void> _unlink() => _run(() async {
    await s.unlink(widget.peer);
    if (mounted) Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final p = s.peerOf(widget.peer);
        if (p == null) return const SettingsPage(title: 'Linked device', children: [NoteText('This device is no longer linked.')]);
        final name = p['name'] as String? ?? '';
        final free = p['free_bytes'];
        final k = context.t;
        return SettingsPage(
          title: name,
          children: [
            Material(
              key: const ValueKey('device-status'),
              color: k.surface,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    statusText(context, peerStatus(p), size: 14, maxLines: null),
                    if (free is int) ...[const SizedBox(height: 2), statusText(context, [Part('${formatBytes(free)} free')], size: 14)],
                  ],
                ),
              ),
            ),
            if (widget.settingsSync != null)
              DeviceSettingsSection(
                key: const ValueKey('device-settings'),
                sync: widget.settingsSync!,
                peer: widget.peer,
                name: name,
                // Known once it has answered: an older version never says it keeps links.
                known: p['link_known'] == true || p['last_seen'] == null,
                busy: _busy,
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  key: const ValueKey('device-sync'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync now'),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await s.syncPeer(widget.peer);
                          if (context.mounted) say(context, 'Syncing with $name');
                        }),
                ),
              ],
            ),
            SettingsGroup(
              rows: [
                SettingsRow(key: const ValueKey('device-rename'), icon: Icons.edit_outlined, title: 'Rename', chevron: false, onTap: _busy ? null : () => _rename(name)),
                SettingsRow(
                  key: const ValueKey('device-unlink'),
                  leading: Icon(Icons.link_off, size: 22, color: k.emergency),
                  title: 'Unlink',
                  danger: true,
                  status: const [Part('It can no longer connect to this device. Files already here stay.')],
                  statusLines: null,
                  chevron: false,
                  onTap: _busy ? null : _unlink,
                ),
              ],
            ),
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
