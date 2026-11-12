import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../maps/ui/format.dart';
import '../../settings/data_kinds.dart';
import '../../sharing/link_inbox.dart';
import '../../sharing/link_url.dart';
import '../../sharing/settings_sync.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'settings_link_pages.dart';
import 'widgets.dart';

/// Settings > Sharing and sync: this device's identity, linked devices, what it shares, and transfers.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key, required this.sharing, this.settingsSync, this.inbox, this.share});

  final SharingState sharing;

  /// Settings between linked devices (each device's page); null where the app has none (tests).
  final SettingsSync? settingsSync;

  /// Where a `cachelink:` link from outside waits; the app's own inbox unless a test gives one.
  final LinkInbox? inbox;

  /// Sends text through the phone's share sheet; the real one unless a test gives one.
  final Future<void> Function(String text)? share;

  @override
  State<SharingPage> createState() => _SharingPageState();
}

/// The QR of a device's link (see link_url.dart): what a system camera reads and opens in Cache.
class LinkQr extends StatelessWidget {
  const LinkQr({super.key, required this.link});

  final String link;

  @override
  Widget build(BuildContext context) =>
      QrImageView(data: link, size: 260, backgroundColor: Colors.white, errorCorrectionLevel: QrErrorCorrectLevel.L);
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
  LinkInbox get _inbox => widget.inbox ?? linkInbox;
  bool _busy = false;
  bool _incomingOpen = false;

  @override
  void initState() {
    super.initState();
    _inbox.pageOpen = true;
    _inbox.addListener(_incomingSoon);
    s.addListener(_incomingSoon);
    _incomingSoon();
  }

  @override
  void dispose() {
    _inbox.pageOpen = false;
    _inbox.take(); // a link still waiting (sharing never started) is dropped, not shown later out of the blue
    _inbox.removeListener(_incomingSoon);
    s.removeListener(_incomingSoon);
    super.dispose();
  }

  void _incomingSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _incoming());
    WidgetsBinding.instance.scheduleFrame();
  }

  /// A `cachelink:` link that came from outside (a camera, another app): once sharing runs, the code goes into the same
  /// "Enter a link code" box with the code filled in, and nothing is linked until the person taps Link. A link that cannot be
  /// read, or whose device is this one or already linked, is said and changes nothing.
  Future<void> _incoming() async {
    if (!mounted || _incomingOpen || _busy || !s.running || _inbox.pending == null) return;
    final link = _inbox.take()!;
    _incomingOpen = true;
    try {
      final String code;
      try {
        code = _checked(linkCodeFrom(link), strict: true);
      } on BadLinkCode catch (e) {
        if (mounted) say(context, e.message);
        return;
      }
      if (mounted) await _enterCode(initial: code);
    } finally {
      _incomingOpen = false;
    }
  }

  /// [code] when it can be linked; throws [BadLinkCode] for this device's own code or one already linked, and, when [strict] (a
  /// link from outside), for a code that cannot be read. A typed or pasted code that cannot be read here is left to the sync
  /// engine, which gives the same messages.
  String _checked(String code, {bool strict = false}) {
    final LinkCodeInfo info;
    try {
      info = decodeLinkCode(code);
    } on BadLinkCode {
      if (strict) rethrow;
      return code;
    }
    if (info.id.toLowerCase() == s.myId?.toLowerCase()) throw const BadLinkCode("that is this device's own code");
    final linked = s.peers.where((p) => (p['id'] as String?)?.toLowerCase() == info.id.toLowerCase()).firstOrNull;
    if (linked != null) throw BadLinkCode('Already linked with ${linked['name'] ?? info.name}');
    return code;
  }

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) say(context, '$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _incomingSoon();
      }
    }
  }

  /// Right after a new link: asks how settings go between the two ([askSettingsLink]).
  Future<void> _ask(String peer) async {
    final sync = widget.settingsSync;
    if (sync == null || !mounted || s.peerOf(peer) == null) return;
    await sync.markNew(peer);
    if (!mounted) return;
    await askSettingsLink(context, sync, peer, s.peerOf(peer)?['name'] as String? ?? 'the other device');
  }

  /// Shows the link code until the other device links with it (the sheet then closes and the question follows) or it is closed.
  Future<void> _showCode() async {
    String? linked;
    await _run(() async {
      final code = await s.linkCode();
      if (!mounted) return;
      final before = {for (final p in s.peers) p['id']: p['linked']};
      BuildContext? sheet;
      void onSharing() {
        if (linked != null || sheet == null) return;
        final fresh = s.peers.where((p) => !before.containsKey(p['id']) || before[p['id']] != p['linked']).firstOrNull;
        if (fresh == null || fresh['id'] is! String) return;
        linked = fresh['id'] as String;
        Navigator.of(sheet!).pop();
      }

      s.addListener(onSharing);
      try {
        await _codeSheet(code, (ctx) => sheet = ctx);
      } finally {
        s.removeListener(onSharing);
      }
    });
    if (linked != null) await _ask(linked!);
  }

  Future<void> _codeSheet(String code, void Function(BuildContext) opened) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        opened(ctx);
        return SafeArea(
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
                  child: LinkQr(link: buildLinkUrl(code)),
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
                TextButton.icon(
                  key: const ValueKey('share-link'),
                  icon: const Icon(Icons.share),
                  label: const Text('Share link'),
                  onPressed: () => (widget.share ?? _systemShare)(buildLinkUrl(code)),
                ),
              ],
            ),
          ),
        );
      },
    );

  static Future<void> _systemShare(String text) => SharePlus.instance.share(ShareParams(text: text)).then((_) {});

  /// "Enter a link code". [initial] fills the box (a code that came in as a link). The clipboard is read only when Paste is tapped.
  Future<void> _enterCode({String? initial}) async {
    final ctl = TextEditingController(text: initial ?? '');
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
    String? linked;
    await _run(() async {
      // A pasted or typed link works as well as a code; a code that is not one, or is already linked, is said before connecting.
      final r = await s.link(_checked(linkCodeFrom(code)));
      if (mounted) say(context, 'Linked with ${r.name}');
      if (r.peer.isNotEmpty) linked = r.peer;
    });
    if (linked != null) await _ask(linked!);
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
                    statusLines: versionMismatch(p) == null ? 2 : null,
                    onTap: () => _peer(p),
                  ),
                SettingsRow(key: const ValueKey('show-code'), icon: Icons.qr_code_2, title: 'Show my link code', onTap: _busy ? null : _showCode),
                SettingsRow(key: const ValueKey('enter-code'), icon: Icons.keyboard_outlined, title: 'Enter a link code', onTap: _busy ? null : _enterCode),
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
            for (final k in s.shareKinds)
              if (s.kindWarning?.call(k.id) case final w?) NoteText(w, key: ValueKey('share-warning-${k.id}')),
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

/// "Connected directly · Last seen 2 min ago", "Not reachable · Last seen 3 h ago", "Not reachable · Never connected since linking".
/// The time is kept across restarts, so before the first check of a session it is told as a fact of the past ("Last seen 3 h ago
/// via a relay"), not as a connection.
List<Part> peerStatus(Map<String, dynamic> p) {
  final mismatch = versionMismatch(p);
  if (mismatch != null) {
    final name = p['name'] as String? ?? 'This device';
    return [
      Part(
        mismatch == 'peer_older' ? 'Version mismatch: $name needs to update Cache' : 'Version mismatch: update Cache on this device to sync with $name',
        Tone.warn,
        Icons.warning_amber_rounded,
      ),
      Part(' · ${versionPair(p)}'),
    ];
  }
  final err = p['error'] as String?;
  final seen = p['last_seen'] as int?;
  final relay = p['via'] == 'relay';
  final lastSeen = seen == null ? 'Never connected since linking' : 'Last seen ${_ago(seen)}';
  if (err != null) return [const Part('Not reachable', Tone.warn), Part(' · $lastSeen')];
  if (seen == null) return const [Part('Checking…')];
  if (p['live'] == false) return [Part('$lastSeen via ${relay ? 'a relay' : 'direct'}')];
  return [Part(relay ? 'Connected through a relay' : 'Connected directly', Tone.ok), Part(' · $lastSeen')];
}

/// Asks before a linked device is unlinked. True when the person said Unlink.
Future<bool> confirmUnlink(BuildContext context, String name) async => await showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('Unlink $name?'),
    content: const Text('It can no longer connect to this device. Files already here stay.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      TextButton(key: const ValueKey('confirm-unlink'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlink')),
    ],
  ),
) == true;

/// How long a linked device may go without once answering before Unlink is offered by itself.
const Duration kNeverReachedAfter = Duration(days: 7);

/// A device that has not answered once since it was linked, more than a week ago (the person may well want it gone).
bool neverReached(Map<String, dynamic> p, [DateTime? now]) {
  if (p['last_seen'] != null) return false;
  final linked = p['linked'] as int?;
  if (linked == null) return false;
  return (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(linked)) > kNeverReachedAfter;
}

/// The link's `compat` when the two devices cannot sync: `peer_older` (the other device needs to update) or `peer_newer` (this one does);
/// null for a link that works or one whose status does not say (the engine does not send `compat` yet).
String? versionMismatch(Map<String, dynamic> p) {
  final c = p['compat'];
  return c == 'peer_older' || c == 'peer_newer' ? c as String : null;
}

/// "1.2.0 · this device 1.1.0" (the other device's version, then this one's). Cache 1.0 sends no version, so it reads "1.0 or earlier".
String versionPair(Map<String, dynamic> p) => '${p['peer_version'] ?? '1.0 or earlier'} · this device ${p['our_version'] ?? ''}'.trim();

/// A kind's line: "4 of 6 shared · 11.3 GB", "Not shared".
List<Part> kindSummary(SharingState s, DataKind k) {
  // Something stops this kind (notebook sync on a newer format): the line says so, the note under the list says what to do.
  if (s.kindWarning?.call(k.id) != null) return const [Part('Not syncing', Tone.warn)];
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
                      onPressed: _busy || !on || !s.canSync ? null : () => _sync(() => s.syncKind(k), 'Syncing ${k.sharingLabel}'),
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
                          canSync: s.canSync,
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
  const _ItemRow({super.key, required this.item, required this.on, required this.busy, required this.onChanged, required this.onSync, this.canSync = true});

  final SharedItem item;
  final bool on;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onSync;

  /// False when every linked device is on a version that cannot sync with this one.
  final bool canSync;

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
            onPressed: busy || !on || !canSync ? null : onSync,
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
  bool _checking = false;

  /// Check again: asks the device for its version now, shows Checking… and then what it found.
  Future<void> _check(String name) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final c = await s.checkVersion(widget.peer);
      // 'busy': a check of this device is already going (the button says Checking…), so nothing more to say.
      if (mounted && c != 'busy') {
        say(
          context,
          switch (c) {
            'ok' => 'Versions match. Syncing with $name starts again.',
            'unreachable' || 'unknown' => 'Could not reach $name.',
            'network_off' => 'Sync is paused: no network it may use.',
            _ => 'Still a different version.',
          },
        );
      }
    } catch (e) {
      if (mounted) say(context, '$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
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

  /// Both Unlink controls (the row and the button for a device never reached) ask once first.
  Future<void> _unlink(String name) async {
    if (!await confirmUnlink(context, name)) return;
    await _run(() async {
      await s.unlink(widget.peer);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final p = s.peerOf(widget.peer);
        if (p == null) return const SettingsPage(title: 'Linked device', children: [NoteText('This device is no longer linked.')]);
        final name = p['name'] as String? ?? '';
        final free = p['free_bytes'];
        final mismatch = versionMismatch(p);
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
                    statusText(context, _checking ? const [Part('Checking…')] : peerStatus(p), size: 14, maxLines: null),
                    if (mismatch != null) ...[
                      const SizedBox(height: 8),
                      statusText(
                        context,
                        [
                          Part(
                            mismatch == 'peer_older'
                                ? 'Nothing syncs with $name until $name is updated. The link stays, and syncing starts again by itself once both devices run matching versions.'
                                : 'Nothing syncs with $name until this device is updated. The link stays, and syncing starts again by itself once both devices run matching versions.',
                            Tone.quiet,
                          ),
                        ],
                        size: 14,
                        maxLines: null,
                      ),
                    ],
                    if (free is int) ...[const SizedBox(height: 2), statusText(context, [Part('${formatBytes(free)} free')], size: 14)],
                    if (neverReached(p)) ...[
                      const SizedBox(height: 10),
                      Text("This device hasn't connected since it was linked.", key: const ValueKey('device-never'), style: TextStyle(fontSize: 14, color: k.text)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const ValueKey('device-unlink-never'),
                        icon: Icon(Icons.link_off, size: 18, color: k.emergency),
                        label: Text('Unlink', style: TextStyle(color: k.emergency)),
                        onPressed: _busy ? null : () => _unlink(name),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.settingsSync != null && mismatch == null)
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
                if (mismatch != null)
                  TextButton.icon(
                    key: const ValueKey('device-check'),
                    icon: const Icon(Icons.refresh),
                    label: Text(_checking ? 'Checking…' : 'Check again'),
                    onPressed: _checking ? null : () => _check(name),
                  ),
                TextButton.icon(
                  key: const ValueKey('device-sync'),
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync now'),
                  onPressed: _busy || mismatch != null
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
                  onTap: _busy ? null : () => _unlink(name),
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
