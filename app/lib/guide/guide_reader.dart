import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';
import 'app_links.dart';
import 'guide_book.dart';

/// Builds the screen an app link (`cache://`) opens over the reader, or null for one that does not open over it; set by the app's
/// shell, which has every screen's parts.
Widget? Function(AppPlace place)? appPlaceScreen;

/// "Ask Cache instead" under a guide search that found nothing: leaves the guide and asks the question in Ask; set by the app's
/// shell (null leaves the button out).
void Function(String question)? askCacheInstead;

/// Where the guide's screenshots are bundled: `<id>.png`, made by the golden tests in test/guide_shots (tools/guide/shots.txt).
const String kGuideShotsDir = 'assets/guide/shots';

/// The reader's widest line of text: past this a line is too long to read comfortably (tablets, phones on their side).
const double kGuideMaxWidth = 620;

const String _contentsRoute = 'guide-contents';

/// Opens the Cache guide, at [title]'s section when it is given (`Cache guide: <chapter>: <section>`).
Future<void> openGuide(BuildContext context, {String? title, GuideBook? book}) async {
  final b = book ?? await GuideBook.load();
  if (!context.mounted) return;
  final s = title == null ? null : b.byTitle(title);
  await Navigator.of(context).push(s == null ? guideContentsRoute(b) : _section(b, s));
}

/// The guide's contents as a page (named, so a section's Contents button finds it under itself).
MaterialPageRoute<void> guideContentsRoute(GuideBook book, {bool search = false, Future<void> Function(BuildContext context)? menu}) => MaterialPageRoute<void>(
  settings: const RouteSettings(name: _contentsRoute),
  builder: (_) => GuideReaderScreen(book: book, menu: menu, focusSearch: search),
);

MaterialPageRoute<void> _section(GuideBook book, GuideSection s, {Future<void> Function(BuildContext context)? menu}) =>
    MaterialPageRoute<void>(builder: (_) => GuideSectionScreen(book: book, section: s, menu: menu));

// ---- the guide's Markdown as the reader shows it -----------------------------------------------------------------------

/// A label the guide quotes ("Set up Cache"): the guide writes UI labels in double quotes, exactly as the app does (the guide's label
/// check keys on them). The reader shows the label without its quotes, in bold on a tinted ground, like the button it names.
final RegExp _label = RegExp(r'"([^"\n]{1,80})"');

/// [body] as the reader renders it: "the section X" names made links to that section, and each quoted label marked as a label.
/// Code (fenced blocks and `inline` spans) is left as it is. The library the assistant searches is built from the chapters as they
/// are (tools/guide/split.py), never from this.
///
/// A label is written as GitHub strikethrough (`~~Label~~`), which the guide never uses: the reader's style sheet draws that as a
/// label, not struck through, so it wraps with the line like any word and needs no Markdown parser of its own.
String guideMarkdown(GuideBook book, String body) {
  // A label inside a link's words is shown as part of the link (its words, without the quotes), so the whole link stays one tap.
  final linked = book.linkSections(body).replaceAllMapped(
    RegExp(r'\[([^\]\n]*)\]\(((?:cache://|#)[^)]*)\)'),
    (m) => '[${m.group(1)!.replaceAll('"', '')}](${m.group(2)})',
  );
  final out = StringBuffer();
  var fence = false;
  final lines = linked.split('\n');
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    if (line.startsWith('```')) fence = !fence;
    if (fence || !line.contains('"')) {
      out.write(line);
    } else {
      // Outside `code` spans only.
      final parts = line.split('`');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) out.write('`');
        out.write(i.isOdd ? parts[i] : parts[i].replaceAllMapped(_label, (m) {
          final t = m.group(1)!;
          // Strikethrough must not start or end with a space; such a quote is left as it is.
          return t.trim() != t || t.contains('~') ? m.group(0)! : '~~$t~~';
        }));
      }
    }
    if (n < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

/// The reader's style: body text a little larger than the app's, generous line height and space between paragraphs, headings
/// clearly bigger than the text, links underlined in the text, labels in bold on a tint.
MarkdownStyleSheet guideStyle(CacheTokens k) {
  TextStyle text({double size = 17, FontWeight? weight, FontStyle? style, Color? color, double height = 1.55}) =>
      TextStyle(fontSize: size, height: height, fontWeight: weight, fontStyle: style, color: color ?? k.text);
  final p = text();
  return MarkdownStyleSheet(
    p: p,
    pPadding: EdgeInsets.zero,
    a: text(color: k.accent).copyWith(decoration: TextDecoration.underline, decorationColor: k.accent),
    strong: text(weight: FontWeight.w700),
    em: text(style: FontStyle.italic),
    // A label ("Set up Cache"), see [guideMarkdown].
    del: text(weight: FontWeight.w600).copyWith(decoration: TextDecoration.none, backgroundColor: k.surface),
    h1: text(size: 24, weight: FontWeight.w700, height: 1.3),
    h2: text(size: 22, weight: FontWeight.w700, height: 1.3),
    h3: text(size: 19, weight: FontWeight.w700, height: 1.35),
    h4: text(size: 18, weight: FontWeight.w700, height: 1.35),
    h5: text(size: 17, weight: FontWeight.w700, height: 1.35),
    h6: text(size: 16, weight: FontWeight.w700, color: k.secondary, height: 1.35),
    h1Padding: const EdgeInsets.only(top: 12),
    h2Padding: const EdgeInsets.only(top: 12),
    h3Padding: const EdgeInsets.only(top: 10),
    h4Padding: const EdgeInsets.only(top: 8),
    h5Padding: const EdgeInsets.only(top: 8),
    h6Padding: const EdgeInsets.only(top: 6),
    listBullet: p,
    listIndent: 26,
    listBulletPadding: const EdgeInsets.only(right: 6),
    blockSpacing: 16,
    code: TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.45, color: k.text, backgroundColor: k.surface),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
    blockquote: text(color: k.secondary),
    blockquotePadding: const EdgeInsets.only(left: 14),
    blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: k.accent, width: 3))),
    horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: k.secondary, width: 1))),
    tableHead: text(weight: FontWeight.w700),
    tableBody: text(),
    tableBorder: TableBorder.all(color: k.secondary, width: 0.5),
    tableCellsPadding: const EdgeInsets.all(8),
  );
}

/// The id of a screenshot link (`shot:<id>`), or null.
String? guideShotId(Uri uri) => uri.scheme == 'shot' && uri.path.isNotEmpty ? uri.path : null;

/// A screenshot in the guide: the picture of the screen, its caption under it. The caption is what a screen reader says for the
/// picture (it is not read twice).
class GuideShot extends StatelessWidget {
  const GuideShot({super.key, required this.id, required this.caption});

  final String id;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        key: ValueKey('guide-shot-$id'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: k.secondary.withValues(alpha: 0.35)), borderRadius: BorderRadius.circular(14)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Image.asset(
                    '$kGuideShotsDir/$id.png',
                    semanticLabel: caption,
                    fit: BoxFit.contain,
                    // A picture missing from this build: the caption still says what it showed.
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Text(caption, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The guide's Markdown in the reader's style: labels, links that move within the guide or open a part of Cache, screenshots.
class GuideText extends StatelessWidget {
  const GuideText({super.key, required this.book, required this.markdown, required this.onLink});

  final GuideBook book;
  final String markdown;
  final void Function(String? href) onLink;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: guideMarkdown(book, markdown),
      styleSheet: guideStyle(context.t),
      builders: {'del': _LabelChip(context.t)},
      onTapLink: (_, href, _) => onLink(href),
      imageBuilder: (uri, _, alt) {
        final id = guideShotId(uri);
        // The guide shows only its own screenshots; it works offline, so it never loads a picture from the web.
        return id == null ? const SizedBox.shrink() : GuideShot(id: id, caption: alt ?? '');
      },
    );
  }
}

/// A label ("Set up Cache") as a small rounded chip in the line of text, in bold, like the button it names. It wraps with the line.
class _LabelChip extends MarkdownElementBuilder {
  _LabelChip(this.k);

  final CacheTokens k;

  // The element is the Markdown parser's (package:markdown); only its words are read.
  @override
  Widget? visitElementAfterWithContext(BuildContext context, Object? element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final words = ((element as dynamic).textContent as String?) ?? '';
    final style = (parentStyle ?? const TextStyle()).merge(preferredStyle).copyWith(backgroundColor: Colors.transparent);
    return Text.rich(
      TextSpan(children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: k.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: k.secondary.withValues(alpha: 0.35)),
            ),
            child: Text(words, style: style.copyWith(height: 1.25)),
          ),
        ),
      ]),
    );
  }
}

/// Keeps a page's text to a readable line length, centred on a wide screen.
Widget _readable(Widget child) => Center(
  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kGuideMaxWidth), child: child),
);

// ---- contents and search -----------------------------------------------------------------------------------------------

/// The guide's first page: a search within the guide, then the chapters, each opening to its sections. A search shows one line
/// per section that matches, with the words around the match; when nothing matches, "Ask Cache instead".
class GuideReaderScreen extends StatefulWidget {
  const GuideReaderScreen({super.key, required this.book, this.menu, this.focusSearch = false});

  final GuideBook book;

  /// The library's "..." menu (its usual actions); null leaves it out.
  final Future<void> Function(BuildContext context)? menu;

  /// Opened from a section's search button: the search box has the focus.
  final bool focusSearch;

  @override
  State<GuideReaderScreen> createState() => _GuideReaderScreenState();
}

class _GuideReaderScreenState extends State<GuideReaderScreen> {
  final _query = TextEditingController();
  final _focus = FocusNode();

  /// The chapters shown open: the first one at the start.
  final Set<int> _open = {0};

  @override
  void initState() {
    super.initState();
    if (widget.focusSearch) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openSection(GuideSection s) {
    _focus.unfocus();
    Navigator.of(context).push(_section(widget.book, s, menu: widget.menu));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final q = _query.text.trim();
    final hits = widget.book.search(q);
    final ask = askCacheInstead;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache guide'),
        actions: [
          if (widget.menu != null)
            IconButton(key: const ValueKey('guide-menu'), tooltip: 'More', icon: const Icon(Icons.more_horiz), onPressed: () => widget.menu!(context)),
        ],
      ),
      body: _readable(
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            TextField(
              key: const ValueKey('guide-search'),
              controller: _query,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search the guide',
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_query.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            if (q.isEmpty)
              for (final (i, c) in widget.book.chapters.indexed) ..._chapter(k, i, c)
            else if (hits.isEmpty) ...[
              const SizedBox(height: 8),
              Text('Nothing in the guide matches "$q".', key: const ValueKey('guide-no-hits'), style: TextStyle(fontSize: 16, color: k.secondary)),
              if (ask != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    key: const ValueKey('guide-ask-instead'),
                    onPressed: () => ask(q),
                    child: const Text('Ask Cache instead'),
                  ),
                ),
              ],
            ] else
              for (final s in hits) _hit(k, s, q),
          ],
        ),
      ),
    );
  }

  List<Widget> _chapter(CacheTokens k, int i, GuideChapter c) {
    final open = _open.contains(i);
    return [
      InkWell(
        key: ValueKey('guide-chapter-${i + 1}'),
        onTap: () => setState(() => open ? _open.remove(i) : _open.add(i)),
        child: Semantics(
          expanded: open,
          button: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Expanded(child: Text(c.heading, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: k.text))),
                if (!open) Text('${c.sections.length}', style: TextStyle(fontSize: 15, color: k.secondary)),
                const SizedBox(width: 4),
                Icon(open ? Icons.expand_less : Icons.expand_more, color: k.secondary),
              ],
            ),
          ),
        ),
      ),
      if (open)
        for (final s in c.sections)
          InkWell(
            key: ValueKey('guide-toc-${s.slug}'),
            onTap: () => _openSection(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 0, 10),
              child: Text(s.heading, style: TextStyle(fontSize: 16, height: 1.3, color: k.text)),
            ),
          ),
      Divider(height: 1, color: k.secondary.withValues(alpha: 0.25)),
    ];
  }

  Widget _hit(CacheTokens k, GuideSection s, String q) {
    final line = guideSnippet(s, q);
    final number = RegExp(r'^(\d+)\.').firstMatch(s.chapter.heading)?.group(1);
    return InkWell(
      key: ValueKey('guide-hit-${s.slug}'),
      onTap: () => _openSection(s),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.heading, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.text)),
                  if (line != null)
                    Text.rich(
                      TextSpan(children: [
                        for (final (text, bold) in line)
                          TextSpan(text: text, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: k.secondary),
                    ),
                ],
              ),
            ),
            if (number != null) ...[
              const SizedBox(width: 12),
              Text(number, semanticsLabel: 'Chapter $number', style: TextStyle(fontSize: 14, color: k.secondary)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The words around the first match of [query] in [s]'s text, as pieces (text, matched), for one line of a search result; null when
/// only the heading matched. Markdown is shown as words: links as their words, labels without quotes, no screenshots.
List<(String, bool)>? guideSnippet(GuideSection s, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return null;
  final plain = s.body
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[*_`#>"]'), '')
      .replaceAll(RegExp(r'^\s*(?:\d+\.|-)\s+', multiLine: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final lower = plain.toLowerCase();
  final at = lower.indexOf(words.first);
  if (at < 0) return null;
  final start = at > 30 ? plain.lastIndexOf(' ', at - 24) + 1 : 0;
  final end = (at + 90).clamp(0, plain.length);
  final text = '${start > 0 ? '…' : ''}${plain.substring(start, end)}${end < plain.length ? '…' : ''}';
  final out = <(String, bool)>[];
  final t = text.toLowerCase();
  var i = 0;
  while (i < text.length) {
    final next = [for (final w in words) (t.indexOf(w, i), w)].where((e) => e.$1 >= 0).fold<(int, String)?>(null, (b, e) => b == null || e.$1 < b.$1 ? e : b);
    if (next == null) {
      out.add((text.substring(i), false));
      break;
    }
    if (next.$1 > i) out.add((text.substring(i, next.$1), false));
    out.add((text.substring(next.$1, next.$1 + next.$2.length), true));
    i = next.$1 + next.$2.length;
  }
  return out;
}

// ---- a section ---------------------------------------------------------------------------------------------------------

/// One section of the guide on its own page: its text with labels, links and screenshots, then Previous, where it is in its chapter
/// ("2 of 6") and Next. Search and the contents are in the top bar. Links to other sections open them; app links open that part of
/// Cache over the guide, which keeps its place.
class GuideSectionScreen extends StatefulWidget {
  const GuideSectionScreen({super.key, required this.book, required this.section, this.menu});

  final GuideBook book;
  final GuideSection section;

  /// The library's menu, for the contents page this section goes back to.
  final Future<void> Function(BuildContext context)? menu;

  @override
  State<GuideSectionScreen> createState() => GuideSectionScreenState();
}

class GuideSectionScreenState extends State<GuideSectionScreen> {
  final ScrollController scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// The contents (with the search box focused for [search]): back to them when they are under this page, else in its place.
  void _toContents({bool search = false}) {
    final nav = Navigator.of(context);
    var under = false;
    nav.popUntil((r) {
      if (r.settings.name == _contentsRoute) under = true;
      return under || r.isFirst;
    });
    if (!under) {
      nav.push(guideContentsRoute(widget.book, search: search, menu: widget.menu));
    } else if (search) {
      // The contents page is showing again: focus its search.
      nav.pushReplacement(guideContentsRoute(widget.book, search: true, menu: widget.menu));
    }
  }

  void _go(GuideSection s) => Navigator.of(context).pushReplacement(_section(widget.book, s, menu: widget.menu));

  Future<void> _link(String? href) async {
    if (href == null) return;
    if (href.startsWith('#')) {
      final s = widget.book.bySlug(href.substring(1));
      if (s != null) await Navigator.of(context).push(_section(widget.book, s, menu: widget.menu));
      return;
    }
    if (!isAppLink(href)) return; // the guide works offline: web links do not open
    final place = appPlaceOf(href);
    if (place == AppPlace.drawArea && openAppPlace != null) {
      // Drawing an area happens on the map itself.
      Navigator.of(context).popUntil((r) => r.isFirst);
      openAppPlace!(place!);
      return;
    }
    final screen = place == null ? null : appPlaceScreen?.call(place);
    if (screen == null) {
      _say(kUnknownAppLink);
      return;
    }
    await Navigator.of(context).push(AppPlaceRoute(child: screen));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final s = widget.section;
    final all = s.chapter.sections;
    final i = all.indexOf(s);
    final sections = widget.book.sections;
    final at = sections.indexOf(s);
    final prev = at > 0 ? sections[at - 1] : null;
    final next = at >= 0 && at < sections.length - 1 ? sections[at + 1] : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.heading, key: ValueKey('guide-section-${s.slug}'), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(key: const ValueKey('guide-section-search'), tooltip: 'Search the guide', icon: const Icon(Icons.search), onPressed: () => _toContents(search: true)),
          IconButton(key: const ValueKey('guide-section-contents'), tooltip: 'Contents', icon: const Icon(Icons.toc), onPressed: _toContents),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('guide-section-page'),
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: _readable(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(s.chapter.heading, style: TextStyle(fontSize: 14, color: k.secondary)),
                    const SizedBox(height: 4),
                    Text(s.heading, style: TextStyle(fontSize: 24, height: 1.25, fontWeight: FontWeight.w700, color: k.text)),
                    const SizedBox(height: 16),
                    GuideText(book: widget.book, markdown: s.body, onLink: _link),
                  ],
                ),
              ),
            ),
          ),
          Material(
            color: k.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('guide-previous'),
                          onPressed: prev == null ? null : () => _go(prev),
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('Previous'),
                        ),
                      ),
                    ),
                    Text('${i + 1} of ${all.length}', key: const ValueKey('guide-position'), style: TextStyle(fontSize: 14, color: k.secondary)),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('guide-next'),
                          onPressed: next == null ? null : () => _go(next),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Next'), SizedBox(width: 4), Icon(Icons.chevron_right)]),
                        ),
                      ),
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

/// A part of Cache opened from the guide: it slides up over the reader, full height, with "Back to the guide" at the top. Closing
/// it in any way returns to the guide exactly where it was (the reader stays underneath).
class AppPlaceRoute extends PageRouteBuilder<void> {
  AppPlaceRoute({required Widget child})
    : super(
        pageBuilder: (context, _, _) => _BackToGuide(child: child),
        transitionsBuilder: (context, animation, _, page) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: page,
        ),
      );
}

class _BackToGuide extends StatelessWidget {
  const _BackToGuide({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: k.surface,
            child: SafeArea(
              bottom: false,
              child: InkWell(
                key: const ValueKey('back-to-guide'),
                onTap: () => Navigator.of(context).pop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.keyboard_arrow_down, color: k.accent),
                      const SizedBox(width: 8),
                      Text('Back to the guide', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: k.accent)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // The opened screen's own top bar sits under this one: no second safe-area inset.
          Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
        ],
      ),
    );
  }
}
