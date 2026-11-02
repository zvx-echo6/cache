import 'package:flutter/material.dart';

import '../theme.dart';

/// Notebook text is Markdown, stored as typed (and written to Obsidian and Logseq as it is). There are no formatting buttons:
/// [MarkdownController] formats it as it is typed, the way Obsidian's live preview does, without changing a character:
/// headings, bold, italic, strikethrough, lists, checkboxes, quotes, code, links, tables and links between entries
/// (`[[...]]`). The marks stay in the text and are drawn faint. Tapping the box of a `- [ ]` line ticks it; Enter after a list
/// item starts the next one (Enter on an empty item ends the list).
class MarkdownController extends TextEditingController {
  MarkdownController({super.text});

  @override
  set value(TextEditingValue v) {
    final old = super.value;
    super.value = _onType(old, v);
  }

  /// List continuation and tapping a checkbox.
  static TextEditingValue _onType(TextEditingValue old, TextEditingValue v) {
    // One newline typed at the cursor, at the end of a list item.
    if (v.text.length == old.text.length + 1 && v.selection.isCollapsed && v.selection.start > 0 && v.text[v.selection.start - 1] == '\n') {
      final at = v.selection.start - 1;
      if (v.text.substring(0, at) + v.text.substring(at + 1) == old.text) {
        final lineStart = v.text.lastIndexOf('\n', at - 1) + 1;
        final line = v.text.substring(lineStart, at);
        final m = _listItem.firstMatch(line);
        if (m != null) {
          final marker = m.group(0)!;
          if (line.trim() == marker.trim()) {
            // An empty item: Enter ends the list.
            final t = v.text.substring(0, lineStart) + v.text.substring(at + 1);
            return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: lineStart));
          }
          var next = marker;
          final n = RegExp(r'^(\s*)(\d+)([.)])').firstMatch(marker);
          if (n != null) next = '${n.group(1)}${int.parse(n.group(2)!) + 1}${n.group(3)} ';
          next = next.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
          final t = v.text.substring(0, at + 1) + next + v.text.substring(at + 1);
          return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: at + 1 + next.length));
        }
      }
    }
    // The cursor put inside a checkbox's brackets by a tap (no typing): tick or untick it.
    if (v.text == old.text && v.selection.isCollapsed && v.selection != old.selection) {
      final o = v.selection.start;
      final lineStart = o == 0 ? 0 : v.text.lastIndexOf('\n', o - 1) + 1;
      final lineEnd = v.text.indexOf('\n', lineStart);
      final line = v.text.substring(lineStart, lineEnd < 0 ? v.text.length : lineEnd);
      final m = _task.firstMatch(line);
      if (m != null) {
        final box = lineStart + m.group(1)!.length; // the '['
        if (o == box + 1 || o == box + 2) {
          final done = v.text[box + 1] != ' ';
          final t = v.text.replaceRange(box + 1, box + 2, done ? ' ' : 'x');
          return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: box + 3));
        }
      }
    }
    return v;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (withComposing && value.isComposingRangeValid) {
      // While the keyboard is composing a word the plain text is shown, so the composing underline lines up.
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return markdownSpan(text, base, context.t);
  }
}

final RegExp _listItem = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s(?:\[[ xX]\]\s)?');
final RegExp _task = RegExp(r'^(\s*[-*+]\s)\[[ xX]\](\s|$)');

/// [text] drawn with its Markdown formatted: every character kept, in order (the spans join back to [text]).
TextSpan markdownSpan(String text, TextStyle base, CacheTokens k) {
  final faint = TextStyle(color: k.secondary.withValues(alpha: 0.7), fontWeight: FontWeight.w400, fontStyle: FontStyle.normal);
  final code = TextStyle(fontFamily: 'monospace', backgroundColor: k.surface, fontSize: (base.fontSize ?? 16) * 0.92);
  final out = <InlineSpan>[];
  var inFence = false;
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final nl = i < lines.length - 1 ? '\n' : '';
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.add(TextSpan(text: line + nl, style: faint.merge(code)));
      continue;
    }
    if (inFence) {
      out.add(TextSpan(text: line + nl, style: code));
      continue;
    }
    final h = RegExp(r'^(#{1,6})(\s+)').firstMatch(line);
    if (h != null) {
      final level = h.group(1)!.length;
      final size = (base.fontSize ?? 16) * (level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.15 : 1.05);
      final hs = TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: k.text);
      out.add(TextSpan(text: h.group(0), style: faint.copyWith(fontSize: size)));
      out.add(TextSpan(children: _inline(line.substring(h.end), hs, faint, code, k), style: hs));
      if (nl.isNotEmpty) out.add(const TextSpan(text: '\n'));
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      out.add(TextSpan(text: line + nl, style: code.copyWith(backgroundColor: Colors.transparent)));
      continue;
    }
    final q = RegExp(r'^(\s*>\s?)').firstMatch(line);
    if (q != null) {
      final qs = TextStyle(fontStyle: FontStyle.italic, color: k.secondary);
      out.add(TextSpan(text: q.group(0), style: TextStyle(color: k.accent, fontWeight: FontWeight.w700)));
      out.add(TextSpan(children: _inline(line.substring(q.end), qs, faint, code, k), style: qs));
      if (nl.isNotEmpty) out.add(const TextSpan(text: '\n'));
      continue;
    }
    final t = _task.firstMatch(line);
    if (t != null) {
      final boxEnd = t.group(1)!.length + 3;
      final done = line[t.group(1)!.length + 1] != ' ';
      out.add(TextSpan(text: line.substring(0, t.group(1)!.length), style: TextStyle(color: k.accent)));
      out.add(TextSpan(text: line.substring(t.group(1)!.length, boxEnd), style: TextStyle(color: k.accent, fontFamily: 'monospace', fontWeight: FontWeight.w700)));
      final rest = TextStyle(decoration: done ? TextDecoration.lineThrough : null, color: done ? k.secondary : null);
      out.add(TextSpan(children: _inline(line.substring(boxEnd), rest, faint, code, k), style: rest));
      if (nl.isNotEmpty) out.add(const TextSpan(text: '\n'));
      continue;
    }
    final l = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s)').firstMatch(line);
    if (l != null) {
      out.add(TextSpan(text: l.group(0), style: TextStyle(color: k.accent, fontWeight: FontWeight.w700)));
      out.addAll(_inline(line.substring(l.end), const TextStyle(), faint, code, k));
      if (nl.isNotEmpty) out.add(const TextSpan(text: '\n'));
      continue;
    }
    out.addAll(_inline(line, const TextStyle(), faint, code, k));
    if (nl.isNotEmpty) out.add(const TextSpan(text: '\n'));
  }
  return TextSpan(style: base, children: out);
}

/// Inline marks of one line: `code`, [[entry links]], [links](url), **bold**, ~~strikethrough~~, *italic* and _italic_.
final RegExp _inlineRe = RegExp(r'(`[^`\n]+`)|(\[\[[^\]\n]+\]\])|(\[[^\]\n]+\]\([^)\n]*\))|(\*\*[^*\n]+\*\*)|(~~[^~\n]+~~)|(\*[^*\s][^*\n]*\*)|(\b_[^_\s][^_\n]*_\b)');

List<InlineSpan> _inline(String s, TextStyle style, TextStyle faint, TextStyle code, CacheTokens k) {
  final out = <InlineSpan>[];
  var at = 0;
  for (final m in _inlineRe.allMatches(s)) {
    if (m.start > at) out.add(TextSpan(text: s.substring(at, m.start), style: style));
    final t = m.group(0)!;
    final link = TextStyle(color: k.accent, decoration: TextDecoration.underline, decorationColor: k.accent);
    if (m.group(1) != null) {
      out.add(TextSpan(text: t, style: style.merge(code)));
    } else if (m.group(2) != null) {
      out.add(TextSpan(text: '[[', style: faint));
      out.add(TextSpan(text: t.substring(2, t.length - 2), style: style.merge(link)));
      out.add(TextSpan(text: ']]', style: faint));
    } else if (m.group(3) != null) {
      final close = t.indexOf('](');
      out.add(TextSpan(text: '[', style: faint));
      out.add(TextSpan(text: t.substring(1, close), style: style.merge(link)));
      out.add(TextSpan(text: t.substring(close), style: faint));
    } else {
      final (mark, st) = m.group(4) != null
          ? ('**', const TextStyle(fontWeight: FontWeight.w700))
          : m.group(5) != null
              ? ('~~', const TextStyle(decoration: TextDecoration.lineThrough))
              : (t[0], const TextStyle(fontStyle: FontStyle.italic));
      out.add(TextSpan(text: mark, style: faint));
      out.add(TextSpan(text: t.substring(mark.length, t.length - mark.length), style: style.merge(st)));
      out.add(TextSpan(text: mark, style: faint));
    }
    at = m.end;
  }
  if (at < s.length) out.add(TextSpan(text: s.substring(at), style: style));
  return out;
}

/// The one-screen formatting cheat sheet behind the small "?".
Future<void> showMarkdownHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final k = ctx.t;
        const rows = [
          ('# Heading', 'A heading (## smaller)'),
          ('**bold**', 'Bold'),
          ('*italic*', 'Italic'),
          ('~~done~~', 'Crossed out'),
          ('- item', 'A list (1. for numbers)'),
          ('- [ ] task', 'A checkbox; tap the box to tick it'),
          ('> quote', 'A quote'),
          ('`code`', 'Code'),
          ('[text](https://…)', 'A link'),
          ('[[Water plan]]', 'A link to another entry'),
          ('| A | B |', 'A table row'),
        ];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            children: [
              Text('Formatting', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: k.text)),
              const SizedBox(height: 4),
              Text('Type these marks and the text formats as you type.', style: TextStyle(fontSize: 14, color: k.secondary)),
              const SizedBox(height: 8),
              for (final (mark, what) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 170, child: Text(mark, style: TextStyle(fontFamily: 'monospace', fontSize: 15, color: k.accent))),
                      Expanded(child: Text(what, style: TextStyle(fontSize: 15, color: k.text))),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );

/// The small "?" that opens the cheat sheet (a 44 pt target around a small drawing).
class MarkdownHelpButton extends StatelessWidget {
  const MarkdownHelpButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('markdown-help'),
        tooltip: 'Formatting help',
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        iconSize: 18,
        icon: Icon(Icons.help_outline, color: context.t.secondary),
        onPressed: () => showMarkdownHelp(context),
      );
}
