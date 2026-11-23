import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/web_link.dart';
import '../../theme.dart';
import '../point_facts/land_at.dart';
import '../point_facts/point_facts.dart';
import '../units.dart';

/// The number as a `tel:` address: digits, a leading plus and the dialer's own pause and star and hash characters; spaces,
/// brackets, dashes and dots dropped. Null when it holds no digit (nothing a dialer could call).
String? telUri(String phone) {
  final kept = phone.trim().replaceAll(RegExp(r'[^0-9+*#,;]'), '');
  if (!RegExp(r'[0-9]').hasMatch(kept)) return null;
  // A plus only means anything first.
  final plus = kept.startsWith('+') ? '+' : '';
  return 'tel:$plus${kept.replaceAll('+', '')}';
}

/// The website as an address the browser takes: `https://` added when the places data gives a bare domain. Null for anything that
/// is not a web address (http or https).
Uri? webUri(String site) {
  final t = site.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;
  // Another kind of link ("mailto:a@b.org", "javascript:...") is not a web address; "example.org:8080" (a port) is.
  final other = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:(?!\d)').hasMatch(t) && !RegExp(r'^https?://', caseSensitive: false).hasMatch(t);
  if (other) return null;
  final u = Uri.tryParse(RegExp(r'^https?://', caseSensitive: false).hasMatch(t) ? t : 'https://$t');
  if (u == null || !isWebLink(u) || u.host.isEmpty) return null;
  return u;
}

void _say(BuildContext context, String text, {SnackBarAction? action}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

/// Dials [phone]: the phone's dialer opens with the number filled in (the person presses call there). Says what it is doing, and says
/// plainly when the phone cannot.
Future<void> callPhone(BuildContext context, String phone) async {
  final uri = telUri(phone);
  if (uri == null) return _say(context, 'This number cannot be dialed');
  _say(context, 'Opening the phone app');
  try {
    await WebLinks.open(uri);
  } catch (_) {
    if (context.mounted) _say(context, "Couldn't open the phone app. Copy the number instead.", action: SnackBarAction(label: 'Copy number', onPressed: () => WebLinks.copy(phone)));
  }
}

/// Opens [site] in the phone's browser; offline it says so, with Copy link.
Future<void> openWebsite(BuildContext context, String site) async {
  final uri = webUri(site);
  if (uri == null) return _say(context, 'This web address cannot be opened');
  final link = uri.toString();
  if (await isOffline()) {
    if (context.mounted) _say(context, kOfflineLinkMessage, action: SnackBarAction(label: 'Copy link', onPressed: () => WebLinks.copy(link)));
    return;
  }
  if (context.mounted) _say(context, 'Opening the website');
  try {
    await WebLinks.open(link);
  } catch (_) {
    if (context.mounted) _say(context, "Couldn't open the website. Copy the link instead.", action: SnackBarAction(label: 'Copy link', onPressed: () => WebLinks.copy(link)));
  }
}

/// A row of the card that does something when tapped (call, open) and keeps the text copyable: a long press, or the copy button
/// at the end, copies it.
class ActionLine extends StatelessWidget {
  const ActionLine({super.key, required this.icon, required this.text, required this.hint, required this.onTap, required this.copyText, required this.copyLabel});

  final IconData icon;
  final String text;

  /// What a tap does, for a screen reader ("Call", "Open website").
  final String hint;
  final VoidCallback onTap;
  final String copyText;
  final String copyLabel;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Semantics(
      button: true,
      label: '$hint $text',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: copyText));
          _say(context, 'Copied');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: k.secondary),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(fontSize: 16, color: k.text, decoration: TextDecoration.underline, decorationColor: k.secondary))),
              IconButton(
                key: ValueKey('copy-$copyLabel'),
                tooltip: copyLabel,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: Icon(Icons.copy, color: k.secondary),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: copyText));
                  _say(context, 'Copied');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Elevation: 4,200 ft" and "Land: Bureau of Land Management" for a point, from the phone's own map data. Each row appears when
/// its answer arrives and only when there is one: no data for the spot, nothing shown.
class PointFactRows extends StatefulWidget {
  const PointFactRows({super.key, required this.facts, required this.lat, required this.lon, required this.fmt});

  final PointFacts facts;
  final double lat;
  final double lon;
  final Fmt fmt;

  @override
  State<PointFactRows> createState() => _PointFactRowsState();
}

class _PointFactRowsState extends State<PointFactRows> {
  double? _elevation;
  LandAnswer? _land;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PointFactRows old) {
    super.didUpdateWidget(old);
    if (old.lat != widget.lat || old.lon != widget.lon) {
      _elevation = null;
      _land = null;
      _load();
    }
  }

  void _load() {
    final gen = ++_gen;
    final f = widget.facts, lat = widget.lat, lon = widget.lon;
    f.elevationM(lat, lon).then<void>((v) {
      if (mounted && gen == _gen) setState(() => _elevation = v);
    }).catchError((Object _) {});
    f.land(lat, lon).then<void>((v) {
      if (mounted && gen == _gen) setState(() => _land = v);
    }).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final e = _elevation, land = _land;
    Widget row(Key key, IconData icon, String text, {String? sub}) => Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: k.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, style: TextStyle(fontSize: 16, color: k.text)),
                    if (sub != null) Text(sub, style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (e != null) row(const ValueKey('place-card-elevation'), Icons.terrain, 'Elevation: ${widget.fmt.height(e)}'),
        if (land != null) row(const ValueKey('place-card-land'), Icons.landscape_outlined, 'Land: ${land.text}', sub: land.unit),
      ],
    );
  }
}
