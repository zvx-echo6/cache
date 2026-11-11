import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'build_api.dart';
import 'build_state.dart';
import 'build_text.dart';
import 'device_api.dart' show DeviceException;

/// A white card on the page tint, the shape every panel of these pages has.
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 10), this.accentEdge = false, this.warnEdge = false, this.onTap, this.selected = false});

  final Widget child;
  final EdgeInsets padding;

  /// A bar of the accent colour on the left: a card that asks to be read.
  final bool accentEdge;
  final bool warnEdge;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final edge = warnEdge ? k.warning : (accentEdge ? k.accent : null);
    final inner = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: edge != null
            ? Border(left: BorderSide(color: edge, width: 3))
            : (selected ? Border.all(color: k.accent, width: 1.5) : null),
      ),
      padding: padding,
      child: child,
    );
    return Material(
      color: k.surface,
      borderRadius: BorderRadius.circular(14),
      child: onTap == null ? inner : InkWell(borderRadius: BorderRadius.circular(14), onTap: onTap, child: inner),
    );
  }
}

/// A line of small print.
class Small extends StatelessWidget {
  const Small(this.text, {super.key, this.warn = false, this.size = 12, this.maxLines});

  final String text;
  final bool warn;
  final double size;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Text(text, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, style: TextStyle(fontSize: size, height: 1.35, color: warn ? k.warning : k.secondary));
  }
}

/// The page title row of a detail page: back arrow when the page can go back, the title, and the page's actions.
AppBar pageBar(BuildContext context, String title, {List<Widget> actions = const []}) => AppBar(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: actions,
    );

/// The red button of a confirm that destroys something.
ButtonStyle dangerStyle(BuildContext context) {
  final k = context.t;
  return FilledButton.styleFrom(backgroundColor: k.emergency, foregroundColor: Colors.white);
}

/// A thin bar for one book or one batch; amber while building is paused.
class SlimBar extends StatelessWidget {
  const SlimBar({super.key, this.value, this.paused = false, this.height = 4});

  final double? value;
  final bool paused;
  final double height;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        backgroundColor: k.secondary.withValues(alpha: 0.22),
        valueColor: AlwaysStoppedAnimation(paused ? k.warning : k.primary),
      ),
    );
  }
}

/// A small square with the first letter of a title, as in the Library list.
class BookLetter extends StatelessWidget {
  const BookLetter(this.title, {super.key, this.size = 28});

  final String title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final letter = title.trim().isEmpty ? '?' : title.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: k.background, borderRadius: BorderRadius.circular(8)),
      child: Text(letter, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: k.accent)),
    );
  }
}

/// The words of a failed call, without the device's own text when it could name the machine.
String callWords(Object e, {String fallback = 'Something went wrong. Try again.'}) {
  if (e is DeviceException) {
    if (e.code == 'unauthorized') return 'Sign in again.';
    if (e.code == 'unreachable') return 'This device could not be reached. Try again.';
    if (e.message.isNotEmpty) return e.message;
  }
  return fallback;
}

void say(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

/// [say] for the words of an upload ("Uploading 3 PDFs. Keep this tab open."): they go as soon as [done] completes, instead of
/// waiting out the toast's own time.
void sayUntil(BuildContext context, String text, Future<void> done) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  final bar = messenger.showSnackBar(SnackBar(content: Text(text)));
  var open = true;
  unawaited(bar.closed.whenComplete(() => open = false));
  unawaited(done.catchError((Object _) {}).whenComplete(() {
    if (open) bar.close();
  }));
}

/// "Building 8%", "Paused", "2 failed", or null: the badge of a built library in the Library list.
String? buildBadge(BuildController c, BuildLibrary l) {
  final p = c.progressOf(l.id);
  if (p.total == 0) return null;
  if (!c.isBuilding(l.id)) return p.attention > 0 ? '${p.attention} failed' : null;
  if (c.queue.paused) return 'Paused';
  final pct = p.total == 0 ? 0 : (p.finished * 100 / p.total).floor();
  return 'Building $pct%';
}

/// The line under a built library in the list: "Built from your PDFs · 214 books · 1.9 GB".
String builtLibraryLine(BuildLibrary l, int? bytes) => ['Built from your PDFs', bookCount(l.books), if (bytes != null) _size(bytes)].join(' · ');

String _size(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(bytes >= 100 << 20 ? 0 : 1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// A rounded box with a dashed edge: a drop zone.
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.radius = 18, this.color});

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return CustomPaint(
      painter: _DashedPainter(color ?? k.secondary.withValues(alpha: 0.7), radius, k.surface.withValues(alpha: 0.6)),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DashedPainter extends CustomPainter {
  _DashedPainter(this.color, this.radius, this.fill);

  final Color color;
  final double radius;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(1);
    canvas.drawRRect(rrect, Paint()..color = fill);
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, (d + 7).clamp(0, m.length)), paint);
        d += 12;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) => old.color != color || old.radius != radius || old.fill != fill;
}
