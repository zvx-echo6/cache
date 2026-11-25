import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../maps/ui/format.dart';
import '../../platform.dart' as plat;
import '../../settings/data_kinds.dart';
import '../../sharing/link_inbox.dart';
import '../../sharing/link_scan.dart';
import '../../sharing/link_url.dart';
import '../../sharing/settings_sync.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'link_code_page.dart';
import 'ways_to_connect_page.dart';
import 'link_scan_screen.dart';
import 'settings_link_pages.dart';
import 'widgets.dart';
import '../../update/update_ui.dart' show updateCacheSnackAction;
import '../../platform/device_lock.dart';

/// Settings > Sharing and sync: this device's identity, linked devices, what it shares, and transfers.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key, required this.sharing, this.settingsSync, this.inbox, this.share, this.onAndroid, this.onIos, this.onOpenItem, this.scanner});

  /// What an item's row opens (see [ShareItemOpener]); null: rows only toggle sharing.
  final ShareItemOpener? onOpenItem;

  /// The platform as the page's background-sync note sees it; null: the real one (tests give theirs).
  final bool? onAndroid, onIos;

  final SharingState sharing;

  /// Settings between linked devices (each device's page); null where the app has none (tests).
  final SettingsSync? settingsSync;

  /// Where a `cachelink:` link from outside waits; the app's own inbox unless a test gives one.
  final LinkInbox? inbox;

  /// Sends text through the phone's share sheet; the real one unless a test gives one.
  final Future<void> Function(String text)? share;

  /// Reads a link code from the camera ("Scan a code"); null: this platform's own (none on Linux and the web, where the button is hidden).
  final LinkScanner? scanner;

  @override
  State<SharingPage> createState() => _SharingPageState();
}

/// The QR of a device's link (see link_url.dart): what a system camera reads and opens in Cache.
///
/// Made to scan: error correction Q, every module [kQrModulePx] logical pixels wide (a whole number of device pixels on a phone) and a
/// quiet zone of [kQrQuietModules] modules, all inside the white square, black on white in light and dark. A link too long for that
/// width (an old, long code) is drawn smaller, never refused.
const kQrModulePx = 6.0;
const kQrQuietModules = 4;

class LinkQr extends StatelessWidget {
  const LinkQr({super.key, required this.link});

  final String link;

  /// The modules along one side, for [link] at error correction Q.
  static int modulesFor(String link) =>
      QrValidator.validate(data: link, errorCorrectionLevel: QrErrorCorrectLevel.Q).qrCode?.moduleCount ?? 21;

  @override
  Widget build(BuildContext context) {
    final modules = modulesFor(link);
    final whole = modules + 2 * kQrQuietModules;
    return LayoutBuilder(
      builder: (context, box) {
        final px = box.maxWidth.isFinite && box.maxWidth < whole * kQrModulePx ? box.maxWidth / whole : kQrModulePx;
        return QrImageView(
          data: link,
          size: whole * px,
          padding: EdgeInsets.all(kQrQuietModules * px),
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.Q,
        );
      },
    );
  }
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

  /// The new-device message was on screen: it is told once, so leaving the page marks it shown.
  bool _sawNewDevice = false;

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
    if (_sawNewDevice) s.dismissNewDevice();
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
        if (mounted) say(context, e.message, action: e.newer ? updateCacheSnackAction(context) : null);
        return;
      }
      if (mounted) await _enterCode(initial: code);
    } finally {
      _incomingOpen = false;
    }
  }

  /// [code] when it can be linked; throws [BadLinkCode] for this device's own code or one already linked, and, when [strict] (a
  /// link from outside), for a code that cannot be read. A typed or pasted code that cannot be read here is left to the sync
  /// engine, which gives the same messages; a code from a newer Cache is said here either way.
  String _checked(String code, {bool strict = false}) {
    final LinkCodeInfo info;
    // A short code carries no device in it to read here; the engine says whose it is, and its own messages.
    if (isShortLinkCode(code)) return code;
    try {
      info = decodeLinkCode(code);
    } on BadLinkCode catch (e) {
      if (strict || e.newer) rethrow;
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
      // The engine names a code from a newer Cache by its kind, never by its text.
      final newer = e is CacheSearchException && e.code == kNewerCodeKind;
      // "Update Cache here" goes to the update, as the update banner does
      if (mounted) say(context, newer ? kNewerCode : '$e', action: newer ? updateCacheSnackAction(context) : null);
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
    await askSettingsLink(
      context,
      sync,
      peer,
      s.peerOf(peer)?['name'] as String? ?? 'the other device',
      openDevice: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharingDevicePage(sharing: s, peer: peer, settingsSync: widget.settingsSync))),
    );
  }

  /// Opens the "Show my link code" page, which stays until the other device links with the code or a Nearby link is made (the
  /// question about settings then follows) or it is closed.
  Future<void> _showCode() async {
    String? linked;
    await _run(() async {
      final code = await s.linkCode();
      if (!mounted) return;
      linked = await Navigator.of(context).push<String>(MaterialPageRoute<String>(builder: (_) => LinkCodePage(sharing: s, code: code, share: widget.share)));
    });
    if (linked != null) {
      if (mounted) say(context, 'Linked with ${s.peerOf(linked!)?['name'] ?? 'the other device'}');
      await _ask(linked!);
    }
  }

  /// "Enter a link code". [initial] fills the box (a code that came in as a link). The clipboard is read only when Paste is tapped.
  Future<void> _enterCode({String? initial}) async {
    final ctl = TextEditingController(text: initial ?? '');
    final scanner = widget.scanner ?? defaultLinkScanner();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter a link code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'CACHE-…', border: OutlineInputBorder()),
            ),
            if (scanner != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('scan-code'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan a code'),
                // A code read is linked as if typed and Link tapped.
                onPressed: () async {
                  final read = await Navigator.of(ctx).push<String>(MaterialPageRoute(builder: (_) => LinkScanScreen(scanner: scanner)));
                  if (read != null && ctx.mounted) {
                    ctl.text = read;
                    Navigator.pop(ctx, read);
                  }
                },
              ),
              const SizedBox(height: 4),
              const Text('Cache uses the camera only to read the link code.', style: TextStyle(fontSize: 12)),
            ],
          ],
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

  Future<void> _kind(DataKind k) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SharingKindPage(sharing: s, kind: k, onOpenItem: widget.onOpenItem)));

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
              NoteText(
                'Link your Cache devices and keep their library, maps, models and videos the same, over Wi-Fi nearby or the internet. '
                'Devices talk to each other directly; nothing goes through a Cache server. '
                '${s.onServer ? 'Setting up gives Cache on this computer its own identity for linking with your devices.' : 'Setting up creates this device\'s identity.'}',
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
        if (s.newDevice) _sawNewDevice = true;
        final st = s.status;
        final relay = st['relay'] as String?;
        final online = st['network'] == true;
        final t = s.transfer;
        return SettingsPage(
          title: 'Sharing and sync',
          children: [
            if (s.newDevice) const NoteText('This is a new device: link it to your other devices again'),
            SettingsGroup(
              label: 'This device',
              rows: [
                SettingsRow(
                  icon: s.onServer ? Icons.dns : Icons.smartphone,
                  title: s.name,
                  status: [
                    // "Wi-Fi and 2 entry points · 10.0 GB free" (a browser's server has no entry points to list).
                    online ? Part(s.onServer ? (relay != null ? 'Online' : 'Local network only') : thisDeviceWays(s.entriesOn), s.onServer ? (relay != null ? Tone.ok : Tone.warn) : Tone.normal) : const Part('Paused: no network it may use', Tone.warn),
                    if (st['free_bytes'] is int) Part(' · ${formatBytes(st['free_bytes'] as int)} free'),
                  ],
                  statusLines: 2,
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
                    status: peerStatus(p, entryHost: s.entryHostOf),
                    statusLines: 2,
                    onTap: () => _peer(p),
                  ),
                SettingsRow(key: const ValueKey('show-code'), icon: Icons.qr_code_2, title: 'Show my link code', onTap: _busy ? null : _showCode),
                SettingsRow(key: const ValueKey('enter-code'), icon: Icons.keyboard_outlined, title: 'Enter a link code', onTap: _busy ? null : _enterCode),
              ],
            ),
            if (!s.onServer)
              SettingsGroup(
                label: 'Ways to connect',
                rows: [
                  SettingsRow(
                    key: const ValueKey('ways-to-connect'),
                    title: 'Ways to connect',
                    status: [Part(waysSummary(s.entriesOn))],
                    statusLines: 2,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WaysToConnectPage(sharing: s))),
                  ),
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
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final result = s.syncResult(working: 'Syncing with your devices');
                          await s.syncNow();
                          if (context.mounted) say(context, result);
                        }),
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
            if (syncBackgroundNote(android: widget.onAndroid, ios: widget.onIos) case final note?) NoteText(note),
            _Log(entries: s.activity),
          ],
        );
      },
    );
  }
}

/// How a linked device is reached now, from the engine's `via` and `speed` (step 3's class of the link).
enum RouteKind { wifi, entry, slow, relay, direct }

/// The way [p] is reached, and, through an entry point, the host it comes in through ([entryHost] gives it for an id; null or an
/// unknown id says "the internet"). Only what the engine knows: Wi-Fi, an entry point, or a link it judges slow (a slow link that is
/// not Wi-Fi and not through an entry point, and live now). Through an entry point or on Wi-Fi the route is named as it is, however
/// fast it measures.
({RouteKind kind, String? host}) peerRoute(Map<String, dynamic> p, {String? Function(String id)? entryHost}) {
  final via = p['via'];
  final entryId = SharingState.entryIdOfVia(via);
  if (entryId != null) return (kind: RouteKind.entry, host: entryHost?.call(entryId));
  if (via == 'wifi') return (kind: RouteKind.wifi, host: null);
  if (p['speed'] == 'slow' && p['live'] != false) return (kind: RouteKind.slow, host: null);
  return (kind: via == 'relay' ? RouteKind.relay : RouteKind.direct, host: null);
}

/// "Same Wi-Fi · Last seen just now", "Through rt.example.net · Last seen just now", "Connected, slow link: small items only · Last seen
/// 5 min ago", "Connected directly · Last seen 2 min ago", "Not reachable · Last seen 3 h ago", "Not reachable · Never connected since
/// linking". The time is kept across restarts, so before the first check of a session it is told as a fact of the past ("Last seen 3 h
/// ago via a relay"), not as a connection.
List<Part> peerStatus(Map<String, dynamic> p, {String? Function(String id)? entryHost}) {
  final err = p['error'] as String?;
  final seen = p['last_seen'] as int?;
  final r = peerRoute(p, entryHost: entryHost);
  final through = r.host ?? 'the internet';
  final lastSeen = seen == null ? 'Never connected since linking' : 'Last seen ${_ago(seen)}';
  if (err != null) return [const Part('Not reachable', Tone.warn), Part(' · $lastSeen')];
  if (seen == null) return const [Part('Checking…')];
  if (p['live'] == false) {
    final how = switch (r.kind) {
      RouteKind.relay => 'a relay',
      RouteKind.wifi => 'Wi-Fi',
      RouteKind.entry => through,
      RouteKind.slow || RouteKind.direct => 'direct',
    };
    return [Part('$lastSeen via $how')];
  }
  final now = switch (r.kind) {
    RouteKind.relay => 'Connected through a relay',
    RouteKind.wifi => 'Same Wi-Fi',
    RouteKind.entry => 'Through $through',
    RouteKind.slow => 'Connected, slow link: small items only',
    RouteKind.direct => 'Connected directly',
  };
  return [Part(now, Tone.ok), Part(' · $lastSeen')];
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
  const SharingKindPage({super.key, required this.sharing, required this.kind, this.onOpenItem});

  final ShareItemOpener? onOpenItem;

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
                      onPressed: _busy || !on ? null : () => _sync(() => s.syncKind(k), s.syncResult(shareIds: k.shared().keys, working: 'Syncing ${k.sharingLabel}')),
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
                          onSync: () => _sync(() => s.syncItem(i.item), s.syncResult(shareIds: [i.item.share], working: 'Syncing ${i.item.name}')),
                          onOpen: widget.onOpenItem?.call(context, k, i.item),
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
  const _ItemRow({super.key, required this.item, required this.on, required this.busy, required this.onChanged, required this.onSync, this.onOpen});

  /// The row opens the item; null: the row toggles sharing (the Switch always does).

  final SharedItem item;
  final bool on;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onSync;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final name = item.item.name;
    return SettingsRow(
      title: name,
      status: _itemDetail(item),
      onTap: onOpen ?? (busy ? null : () => onChanged(!on)),
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
/// how settings go between the two (Settings), Sync now with it alone, Rename (what
/// this device calls it) and Unlink.
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

  /// Both Unlink controls (the row and the button for a device never reached) ask once first, then for the
  /// phone's own screen lock (with none set, the confirm alone is enough).
  Future<void> _unlink(String name) async {
    if (!await confirmUnlink(context, name)) return;
    final lock = await DeviceLock.confirm(title: 'Unlink $name?', description: "Confirm it's you to unlink this device.");
    if (!mounted) return;
    if (lock == DeviceLockResult.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not unlinked')));
      return;
    }
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
        final k = context.t;
        final status = peerStatus(p, entryHost: s.entryHostOf);
        return SettingsPage(
          title: name,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GroupLabel('Status'),
                Material(
                  key: const ValueKey('device-status'),
                  color: k.surface,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // How it is reached, then when it was last seen: the row's line, with its first part as the heading.
                        Text(status.first.text, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: k.text)),
                        if (status.length > 1) ...[
                          const SizedBox(height: 2),
                          statusText(context, [Part(status.skip(1).map((x) => x.text).join().replaceFirst(' · ', ''))], size: 14, maxLines: null),
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
              ],
            ),
            if (s.waitingFor(widget.peer).isNotEmpty) _Waiting(items: s.waitingFor(widget.peer)),
            if (widget.settingsSync != null)
              DeviceSettingsSection(
                key: const ValueKey('device-settings'),
                sync: widget.settingsSync!,
                peer: widget.peer,
                name: name,
                // Known once it has answered: an older version never says it keeps links.
                known: p['link_known'] == true || p['last_seen'] == null,
                busy: _busy,
                label: 'This link',
              ),
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('device-activity'),
                  title: 'Activity',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ActivityPage(sharing: s))),
                ),
                SettingsRow(key: const ValueKey('device-rename'), title: 'Rename', onTap: _busy ? null : () => _rename(name)),
              ],
            ),
            FilledButton(
              key: const ValueKey('device-sync'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final result = s.syncResult(peer: widget.peer, working: 'Syncing with $name');
                      await s.syncPeer(widget.peer);
                      if (context.mounted) say(context, result);
                    }),
              child: const Text('Sync now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            OutlinedButton(
              key: const ValueKey('device-unlink'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: const StadiumBorder(),
                foregroundColor: k.emergency,
                side: BorderSide(color: k.emergency.withValues(alpha: 0.7), width: 1.5),
              ),
              onPressed: _busy ? null : () => _unlink(name),
              child: const Text('Unlink', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ],
        );
      },
    );
  }
}

/// A device's Activity: the engine's log and this app's own lines, newest first (the same list as the Activity on Sharing and sync).
class _ActivityPage extends StatelessWidget {
  const _ActivityPage({required this.sharing});

  final SharingState sharing;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sharing,
    builder: (context, _) {
      final entries = sharing.activity;
      return SettingsPage(
        title: 'Activity',
        children: [
          if (entries.isEmpty) const NoteText('Nothing yet.'),
          for (final e in entries.take(30))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
              title: Text(e['text'] as String? ?? ''),
              trailing: Text(_ago(e['at'] as int?), style: TextStyle(color: context.t.secondary, fontSize: 12)),
            ),
        ],
      );
    },
  );
}

/// What waits for a faster connection, grouped by kind the way mockup 5 names it: "Region map" for the map files (any number) and "N
/// photos" for a notebook's photos. Any other kind is named by its share's name (a library, models, videos...), and a folder's whole
/// list by its share's name too; each row adds up the sizes of its files.
List<({String label, int bytes})> waitingGroups(List<Map<String, dynamic>> items) {
  const maps = {'maps', 'regions'};
  const photoExt = {'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif'};
  final order = <String>[];
  final bytes = <String, int>{};
  final photos = <String, int>{};
  final names = <String, String>{};
  for (final w in items) {
    final share = (w['share_id'] as String?) ?? '';
    final path = (w['path'] as String?) ?? '';
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final String key;
    if (maps.contains(share)) {
      key = 'maps';
      names[key] = 'Region map';
    } else if (share == 'notebooks' && w['what'] == 'file' && photoExt.contains(ext)) {
      key = 'photos';
      photos[key] = (photos[key] ?? 0) + 1;
    } else {
      key = 'share:$share';
      names[key] = (w['share'] as String?) ?? share;
    }
    if (!order.contains(key)) order.add(key);
    bytes[key] = (bytes[key] ?? 0) + ((w['size'] as num?)?.toInt() ?? 0);
  }
  return [
    for (final key in order)
      (
        label: key == 'photos' ? (photos[key] == 1 ? '1 photo' : '${photos[key]} photos') : names[key]!,
        bytes: bytes[key]!,
      ),
  ];
}

/// "Waiting for a faster connection": what the engine holds back from a device until a faster link, one row per kind with its size.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.items});

  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Column(
      key: const ValueKey('device-waiting'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('Waiting for a faster connection'),
        SettingsGroup(
          rows: [
            for (final g in waitingGroups(items))
              SettingsRow(
                title: g.label,
                chevron: false,
                trailing: g.bytes > 0 ? Text(formatBytes(g.bytes), style: TextStyle(fontSize: 15, color: k.secondary)) : null,
              ),
          ],
        ),
        const SizedBox(height: 10),
        const NoteText('These go the next time the devices are on the same Wi-Fi, or both use an entry point that allows files this big.'),
      ],
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

/// What the Sharing page says about syncing with Cache closed: on Android about once an hour, on iPhone only when iOS allows it
/// (iOS decides if and when it runs Cache in the background, and gives it seconds); nothing elsewhere.
String? syncBackgroundNote({bool? android, bool? ios}) {
  if (android ?? plat.isAndroid) {
    return 'When Cache is closed, this phone syncs about once an hour if a linked device is in reach.';
  }
  if (ios ?? plat.isIOS) {
    return 'On iPhone, background sync runs only when iOS allows it, so it can be late. Open Cache to sync now.';
  }
  return null;
}
