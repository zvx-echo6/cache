import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../platform/share_or_copy.dart' show shareOrCopy;
import '../../sharing/link_url.dart';
import '../../sharing/nearby.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'sharing_page.dart' show LinkQr;
import 'widgets.dart';

/// "Show my link code": this device's code and QR (as the old sheet gave), and Nearby, the Cache devices that have this page open
/// too, each with a Link button. Pops with the id of the device that linked (a code entered over there, or a Nearby link), or null.
class LinkCodePage extends StatefulWidget {
  const LinkCodePage({super.key, required this.sharing, required this.code, this.share, this.nearby});

  final SharingState sharing;
  final String code;

  /// Sends text through the phone's share sheet; the real one unless a test gives one.
  final Future<void> Function(String text)? share;

  /// The Nearby side; one on the sharing engine unless a test gives its own.
  final NearbyController? nearby;

  @override
  State<LinkCodePage> createState() => _LinkCodePageState();
}

class _LinkCodePageState extends State<LinkCodePage> {
  late final NearbyController _nearby = widget.nearby ?? NearbyController(widget.sharing.callQuiet);
  /// Who was linked, and since when, as the page opened.
  late final Map<Object?, Object?> _before;
  BuildContext? _dialog;
  bool _dialogUp = false; // set the moment it is asked for, before it has a context
  bool _closing = false, _refreshedForLink = false;
  Timer? _linkedTimer;

  @override
  void initState() {
    super.initState();
    _before = {for (final p in widget.sharing.peers) p['id']: p['linked']};
    _nearby.onDropped = _dropped;
    _nearby.addListener(_changed);
    widget.sharing.addListener(_sharingChanged);
    _nearby.open();
  }

  @override
  void dispose() {
    _linkedTimer?.cancel();
    widget.sharing.removeListener(_sharingChanged);
    _nearby.removeListener(_changed);
    _nearby.onDropped = null;
    _nearby.close();
    if (widget.nearby == null) _nearby.dispose();
    super.dispose();
  }

  /// The device that is linked now and was not (or was not linked) when this page opened.
  String? _fresh() {
    final p = widget.sharing.peers.where((p) => !_before.containsKey(p['id']) || _before[p['id']] != p['linked']).firstOrNull;
    return p == null || p['id'] is! String ? null : p['id'] as String;
  }

  /// A code entered on the other device linked it: this page is done (the question about settings follows on the page behind).
  void _sharingChanged() {
    if (_closing || _nearby.state.active) return;
    final id = _fresh();
    if (id == null) return;
    _closing = true;
    Navigator.of(context).pop(id);
  }

  void _dropped(String? reason) {
    if (mounted) say(context, nearbyDroppedMessage(reason));
  }

  void _changed() {
    if (!mounted) return;
    final st = _nearby.state;
    if (st.phase == NearbyPhase.linked && !_refreshedForLink) {
      _refreshedForLink = true;
      widget.sharing.refresh(); // the new device is in Linked devices when this page closes
      _linkedTimer = Timer(const Duration(seconds: 2), _done);
    }
    if (st.phase != NearbyPhase.linked) _refreshedForLink = false;
    if (st.active && !_dialogUp) {
      _dialogUp = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          _dialog = ctx;
          return _NearbyDialog(_nearby);
        },
      ).then((_) {
        _dialog = null;
        _dialogUp = false;
      });
    } else if (!st.active && _dialog != null) {
      Navigator.of(_dialog!).pop();
      _dialog = null;
    }
  }

  /// A moment after "Linked": the dialog goes and the page closes on Linked devices (which says "Linked with X"), where the new device is.
  Future<void> _done() async {
    if (!mounted || _closing) return;
    _nearby.acknowledge();
    await widget.sharing.refresh();
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context).pop(_fresh());
  }

  static Future<void> _systemShare(String text) => SharePlus.instance.share(ShareParams(text: text)).then((_) {});

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final code = widget.code;
    return ListenableBuilder(
      listenable: _nearby,
      builder: (context, _) {
        return SettingsPage(
          title: 'Show my link code',
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(20)),
              child: Column(
                children: [
                  // the white square carries its own quiet zone (see LinkQr)
                  LinkQr(link: buildLinkUrl(code)),
                  const SizedBox(height: 14),
                  _CodeText(code),
                  const SizedBox(height: 4),
                  Text('Works once, for 15 minutes', style: TextStyle(color: k.secondary)),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('copy-code'),
                    style: _pill,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      say(context, 'Copied');
                    },
                    child: const Text('Copy code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('share-link'),
                    style: _pill,
                    // a browser with no share sheet copies it instead, and says so
                    onPressed: () => shareOrCopy(context, buildLinkUrl(code), share: widget.share ?? _systemShare, copied: 'Link copied'),
                    child: const Text('Share link'),
                  ),
                ),
              ],
            ),
            if (_nearby.available) _section(context),
          ],
        );
      },
    );
  }

  static final ButtonStyle _pill = OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: const StadiumBorder());

  Widget _section(BuildContext context) {
    final busy = _nearby.linking != null || _nearby.state.active;
    final rows = <Widget>[
      for (final d in _nearby.devices)
        SettingsRow(
          key: ValueKey('nearby-${d.id}'),
          leading: Icon(_icon(d.kind), size: 24, color: context.t.secondary),
          title: d.name ?? 'Device nearby',
          statusWidget: Text(_via(d.via), style: TextStyle(fontSize: 13, color: context.t.secondary)),
          trailing: _nearby.linking == d.id
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
              : FilledButton(key: ValueKey('nearby-link-${d.id}'), onPressed: busy ? null : () => _nearby.link(d), child: const Text('Link')),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GroupLabel('Nearby'),
        const NoteText('Cache devices near you, over Wi-Fi. Open Show my link code on the other device too.'),
        const SizedBox(height: 8),
        if (rows.isNotEmpty) SettingsGroup(rows: rows) else NoteText(_nearby.looked ? 'No devices found yet.' : 'Looking for devices…'),
      ],
    );
  }

  static IconData _icon(String? kind) => switch (kind) {
    'computer' => Icons.laptop_outlined,
    'tablet' => Icons.tablet_outlined,
    _ => Icons.smartphone_outlined,
  };

  static String _via(String via) => switch (via) {
    'bluetooth' => 'Bluetooth',
    'wifi' => 'Same Wi-Fi',
    _ => 'Nearby',
  };
}

/// The whole link code, centred, in monospace and selectable, never cut short. It is one line when it fits; when it does not, it
/// is split after a dash into two lines of about the same length (`CACHE-7KQF-M2XD-P4WN-R7TA-` over `H3JC-V6YB-Q5LE-W2FS-ZQ`). A code with
/// no dash to split at (or lines still too wide) wraps wherever the text must.
class _CodeText extends StatelessWidget {
  const _CodeText(this.code);

  final String code;

  static const _style = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.35);

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(_style);
    return LayoutBuilder(
      builder: (context, box) {
        double width(String t) =>
            (TextPainter(text: TextSpan(text: t, style: style), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout()).width;
        var lines = [code];
        if (width(code) > box.maxWidth) {
          // the dash that leaves the two lines most even (the dash stays at the end of the first line)
          String best = '';
          var bestW = double.infinity;
          for (var i = code.indexOf('-'); i >= 0 && i < code.length - 1; i = code.indexOf('-', i + 1)) {
            final w = [width(code.substring(0, i + 1)), width(code.substring(i + 1))].reduce((a, b) => a > b ? a : b);
            if (w < bestW) {
              bestW = w;
              best = code.substring(0, i + 1);
            }
          }
          if (best.isNotEmpty && bestW <= box.maxWidth) lines = [best, code.substring(best.length)];
        }
        return SelectionArea(
          child: Column(
            key: const ValueKey('link-code-text'),
            children: [for (final l in lines) Text(l, textAlign: TextAlign.center, style: _style)],
          ),
        );
      },
    );
  }
}

/// The question over the page: "Link with Pixel 8?", through getting the words, the words with Cancel and Link, waiting for the
/// other device, and "Linked". It follows the controller, so it is the same on the device that tapped Link and the one that was asked.
class _NearbyDialog extends StatelessWidget {
  const _NearbyDialog(this.nearby);

  final NearbyController nearby;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) nearby.answer(false); // Back is Cancel
      },
      child: ListenableBuilder(
        listenable: nearby,
        builder: (context, _) {
          final st = nearby.state;
          final who = st.name ?? 'the other device';
          final k = context.t;
          final Widget body;
          final List<Widget> actions;
          switch (st.phase) {
            case NearbyPhase.words:
              body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Check that both screens show the same three words.', style: TextStyle(color: k.secondary, fontSize: 16, height: 1.4)),
                  const SizedBox(height: 16),
                  Text(st.words.join(' · '), key: const ValueKey('nearby-words'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                ],
              );
              actions = [
                TextButton(key: const ValueKey('nearby-cancel'), onPressed: () => nearby.answer(false), child: const Text('Cancel')),
                TextButton(key: const ValueKey('nearby-confirm'), onPressed: () => nearby.answer(true), child: const Text('Link')),
              ];
            case NearbyPhase.linked:
              body = Text('It is now in your linked devices.', key: const ValueKey('nearby-linked'), style: TextStyle(color: k.secondary, fontSize: 16, height: 1.4));
              actions = const []; // it closes by itself a moment later (see _done)
            default:
              body = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    st.phase == NearbyPhase.waiting ? 'Waiting for $who to confirm…' : 'Getting the three words…',
                    style: TextStyle(color: k.secondary, fontSize: 16, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
              );
              actions = [TextButton(key: const ValueKey('nearby-cancel'), onPressed: () => nearby.answer(false), child: const Text('Cancel'))];
          }
          return AlertDialog(
            title: Text(st.phase == NearbyPhase.linked ? 'Linked with $who' : 'Link with $who?', style: const TextStyle(fontWeight: FontWeight.w600)),
            content: body,
            actions: actions,
          );
        },
      ),
    );
  }
}
