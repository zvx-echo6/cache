import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../desktop/desktop.dart';
import '../theme.dart';

/// Escapes citation markers like [1] so markdown shows them as plain text and never as a link.
/// Text inside code (fenced or inline) is left alone.
String protectCitations(String text) {
  final code = RegExp(r'```[\s\S]*?(?:```|$)|`[^`\n]*`');
  final out = StringBuffer();
  var at = 0;
  String esc(String s) => s.replaceAllMapped(RegExp(r'(?<!\\)\[(\d+)\]'), (m) => '\\[${m.group(1)}\\]');
  for (final m in code.allMatches(text)) {
    out.write(esc(text.substring(at, m.start)));
    out.write(m.group(0));
    at = m.end;
  }
  out.write(esc(text.substring(at)));
  return out.toString();
}

/// The answer as shown when it cites nothing (no sources): citation marks like [1], [1, 2], [1,2,3] or [1-3] are left out, with the
/// space before each. Display only: the stored text and what the model reads are not changed. Other bracketed text stays, and so does
/// text inside code. Sources are numbered from 1, so a bracket with a 0 in it ([0], [0, 1]) is never a citation and stays. A no-sources
/// answer can still lose a bracket like "[1, 2]" written as an interval; that is accepted.
String dropCitationMarks(String text) {
  final code = RegExp(r'```[\s\S]*?(?:```|$)|`[^`\n]*`');
  final mark = RegExp(r'[ \t]?\[\s*\d+(?:\s*[,\-\u2013]\s*\d+)*\s*\]');
  // A mark with the number 0 in it is kept.
  String cite(Match m) => RegExp(r'\d+').allMatches(m.group(0)!).any((n) => int.parse(n.group(0)!) == 0) ? m.group(0)! : '';
  final out = StringBuffer();
  var at = 0;
  for (final m in code.allMatches(text)) {
    out.write(text.substring(at, m.start).replaceAllMapped(mark, cite));
    out.write(m.group(0));
    at = m.end;
  }
  out.write(text.substring(at).replaceAllMapped(mark, cite));
  return out.toString();
}

/// Style sheet built only from the theme tokens, so all themes read well.
MarkdownStyleSheet answerStyle(CacheTokens k, {double text = 18, double line = 1.45}) {
  TextStyle body({double? size, FontWeight? weight, FontStyle? style, Color? color}) =>
      TextStyle(fontSize: size ?? text, height: line, fontWeight: weight, fontStyle: style, color: color ?? k.text);
  final p = body();
  return MarkdownStyleSheet(
    p: p,
    pPadding: EdgeInsets.zero,
    a: body(color: k.accent),
    strong: body(weight: FontWeight.w700),
    em: body(style: FontStyle.italic),
    del: body(color: k.secondary),
    h1: body(size: 24, weight: FontWeight.w700),
    h2: body(size: 21, weight: FontWeight.w700),
    h3: body(size: 19, weight: FontWeight.w700),
    h4: body(weight: FontWeight.w700),
    h5: body(weight: FontWeight.w700),
    h6: body(weight: FontWeight.w700, color: k.secondary),
    h1Padding: const EdgeInsets.only(top: 8),
    h2Padding: const EdgeInsets.only(top: 6),
    h3Padding: const EdgeInsets.only(top: 4),
    listBullet: p,
    listIndent: 22,
    blockSpacing: 12,
    code: TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.4, color: k.text, backgroundColor: k.surface),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
    blockquote: body(color: k.secondary),
    blockquotePadding: const EdgeInsets.only(left: 14),
    blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: k.accent, width: 3))),
    horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: k.secondary, width: 1))),
    tableHead: body(weight: FontWeight.w700),
    tableBody: body(),
    tableBorder: TableBorder.all(color: k.secondary, width: 0.5),
    tableCellsPadding: const EdgeInsets.all(8),
  );
}

/// An assistant answer rendered as markdown. User messages stay plain text elsewhere.
class AnswerMarkdown extends StatelessWidget {
  const AnswerMarkdown(this.text, {super.key, this.dropCitations = false});

  final String text;

  /// The answer cites nothing: its citation marks are not shown ([dropCitationMarks]).
  final bool dropCitations;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: protectCitations(dropCitations ? dropCitationMarks(text) : text),
      selectable: true,
      // The Linux desktop reads at 16 with 1.6 between lines.
      styleSheet: isLinuxDesktop(context) ? answerStyle(context.t, text: 16, line: 1.6) : answerStyle(context.t),
      onTapLink: (text, href, title) {}, // links never open: the app works offline
    );
  }
}
