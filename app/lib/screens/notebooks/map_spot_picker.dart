import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../notebook/notebook_model.dart';
import '../../notebook/pin_image.dart';
import '../../notebook/place_style.dart';
import '../../notebook/places.dart';
import '../../theme.dart';
import 'places_screen.dart' show parseLatLon;

/// The map of the full-screen picker: [target] is where it should look (it moves there when it changes), [onMoving] is told the
/// middle of the map while the camera moves and [onCentre] when it comes to rest, [onTap] when the map is tapped.
typedef SpotMapBuilder = Widget Function(BuildContext context, NbPlace? target, ValueChanged<NbPlace> onMoving, ValueChanged<NbPlace> onCentre, ValueChanged<NbPlace> onTap);

/// "Choose on map": a full-screen map to put a place's pin on. Pan and zoom the map under a fixed crosshair and press "Use this
/// spot"; a tap on the map moves it there; search and "Where I am" move the map. Cancel keeps the previous pin. Answers the chosen
/// [NbPlace] (its name when the spot is the one a search found), or null.
class MapSpotPicker extends StatefulWidget {
  const MapSpotPicker({super.key, required this.map, required this.places, required this.start, required this.icon, required this.tint, required this.pinStyle});

  final SpotMapBuilder map;
  final PlaceChoices places;

  /// The pin the form has (the map opens there), or null.
  final NbPlace? start;

  /// The pin drawn on the crosshair: the place's map icon, its colour for the theme, and the person's Pin style.
  final IconData icon;
  final Color tint;
  final PinStyle pinStyle;

  @override
  State<MapSpotPicker> createState() => _MapSpotPickerState();
}

class _MapSpotPickerState extends State<MapSpotPicker> {
  final TextEditingController _search = TextEditingController();
  late NbPlace? _target = widget.start;
  late NbPlace? _centre = widget.start;
  NbPlace? _named;
  List<NbPlace> _found = const [];
  bool _searching = false;
  String? _note;

  /// The person has touched the map: the position fix that was asked for on opening leaves it where they put it ("Where I am"
  /// is their own press and always moves it).
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    if (_target == null) _here(quiet: true);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Bumped when the map is sent to the spot it is already aimed at (the person panned away and pressed "Where I am" again):
  /// the map is then opened afresh on it, as a changed target is what moves it.
  int _again = 0;

  void _go(NbPlace p, {bool named = false}) => setState(() {
        if (_target != null && _target!.lat == p.lat && _target!.lon == p.lon) _again++;
        _target = NbPlace(lat: p.lat, lon: p.lon);
        _centre = _target;
        _named = named ? p : null;
        _found = const [];
        _note = null;
      });

  Future<void> _here({bool quiet = false}) async {
    try {
      final p = await widget.places.herePlace();
      if (!mounted) return;
      if (p != null) {
        if (quiet && _touched) return;
        _go(p);
      } else if (!quiet) {
        setState(() => _note = 'Where you are is not known yet. Check that location is on.');
      }
    } catch (_) {
      if (mounted && !quiet) setState(() => _note = 'Where you are is not known yet. Check that location is on.');
    }
  }

  Future<void> _find(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    final coords = parseLatLon(q);
    if (coords != null) return _go(coords);
    final s = widget.places.search;
    if (s == null) return;
    setState(() => _searching = true);
    try {
      final r = await s(q);
      if (mounted) setState(() => _found = r);
    } catch (_) {
      if (mounted) setState(() => _found = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// The name only goes with the spot while the crosshair is still on the place the search found (about 40 m).
  NbPlace? _answer() {
    final c = _centre;
    if (c == null) return null;
    final n = _named;
    if (n != null && (n.lat - c.lat).abs() < 0.0004 && (n.lon - c.lon).abs() < 0.0006) return NbPlace(lat: c.lat, lon: c.lon, label: n.label);
    return NbPlace(lat: c.lat, lon: c.lon);
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final c = _centre;
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              key: ValueKey(_again),
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _touched = true,
              child: widget.map(
                context,
                _target,
                (p) => setState(() => _centre = p),
                (p) => setState(() => _centre = p),
                (p) => _go(p),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(child: _Crosshair(icon: widget.icon, tint: widget.tint, style: widget.pinStyle, ring: k.surface)),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Material(
              color: k.surface,
              elevation: 0,
              child: Container(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
                padding: EdgeInsets.fromLTRB(8, top + 4, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        TextButton(key: const ValueKey('picker-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                        const Expanded(child: Text('Choose on map', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
                        const SizedBox(width: 72),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TextField(
                        key: const ValueKey('picker-search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search an address, place or coordinates',
                          prefixIcon: const Icon(Icons.search),
                          suffix: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                        ),
                        onSubmitted: _find,
                      ),
                    ),
                    for (final p in _found.take(4))
                      ListTile(
                        minTileHeight: 48,
                        leading: Icon(Icons.place_outlined, color: k.secondary),
                        title: Text(p.display, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          FocusScope.of(context).unfocus();
                          _go(p, named: true);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: k.surface,
              child: Container(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: k.secondary.withValues(alpha: 0.25)))),
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c == null ? 'Move the map to the spot' : c.coords, key: const ValueKey('picker-coords'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text)),
                    Text(_note ?? 'Move the map under the crosshair, or tap it', style: TextStyle(fontSize: 13, color: k.secondary)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton.icon(key: const ValueKey('picker-here'), onPressed: _here, icon: const Icon(Icons.my_location), label: const Text('Where I am')),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(key: const ValueKey('picker-use'), onPressed: c == null ? null : () => Navigator.pop(context, _answer()), child: const Text('Use this spot')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The fixed crosshair over the middle of the map, with the pin in its style standing on it.
class _Crosshair extends StatelessWidget {
  const _Crosshair({required this.icon, required this.tint, required this.style, required this.ring});

  final IconData icon;
  final Color tint;
  final PinStyle style;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    const size = 48.0;
    // The teardrop's point is at the foot of its square; the icon and the badge are centred.
    final lift = style == PinStyle.teardrop ? size * 0.44 : 0.0;
    final line = context.t.text;
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: const Size(120, 120), painter: _TicksPainter(line, ring)),
          Transform.translate(offset: Offset(0, -lift), child: PinGlyph(icon: icon, tint: tint, style: style, size: size)),
        ],
      ),
    );
  }
}

class _TicksPainter extends CustomPainter {
  _TicksPainter(this.line, this.casing);
  final Color line, casing;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (final (w, col) in [(4.5, casing), (2.0, line)]) {
      final p = Paint()
        ..color = col
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 4; i++) {
        final a = i * math.pi / 2;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * 30, c + d * 46, p);
      }
    }
    canvas.drawCircle(c, 3.5, Paint()..color = casing);
    canvas.drawCircle(c, 2, Paint()..color = line);
  }

  @override
  bool shouldRepaint(_TicksPainter old) => old.line != line || old.casing != casing;
}
