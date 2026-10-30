import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../chat/answer_markdown.dart' show answerStyle;
import '../theme.dart';
import 'app_links.dart';
import 'guide_book.dart';

/// Builds the screen an app link (`cache://`) opens over the reader, or null for one that does not open over it; set by the app's
/// shell, which has every screen's parts.
Widget? Function(AppPlace place)? appPlaceScreen;

/// Opens the Cache guide, at [title]'s section when it is given (`Cache guide: <chapter>: <section>`).
Future<void> openGuide(BuildContext context, {String? title, GuideBook? book}) async {
  final b = book ?? await GuideBook.load();
  if (!context.mounted) return;
  final s = title == null ? null : b.byTitle(title);
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => s == null ? GuideReaderScreen(book: b) : GuideChapterScreen(book: b, chapter: s.chapter, section: s),
  ));
}

/// The guide's first page: its chapters, and a search box within the guide.
class GuideReaderScreen extends StatefulWidget {
  const GuideReaderScreen({super.key, required this.book, this.menu});

  final GuideBook book;

  /// The library's "..." menu (its usual actions); null leaves it out.
  final Future<void> Function(BuildContext context)? menu;

  @override
  State<GuideReaderScreen> createState() => _GuideReaderScreenState();
}

class _GuideReaderScreenState extends State<GuideReaderScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(GuideChapter c, [GuideSection? s]) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GuideChapterScreen(book: widget.book, chapter: c, section: s)));

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final q = _query.text.trim();
    final hits = widget.book.search(q);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cache guide'),
        actions: [
          if (widget.menu != null)
            IconButton(key: const ValueKey('guide-menu'), tooltip: 'More', icon: const Icon(Icons.more_horiz), onPressed: () => widget.menu!(context)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            key: const ValueKey('guide-search'),
            controller: _query,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search the guide'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (q.isEmpty)
            for (final (i, c) in widget.book.chapters.indexed)
              ListTile(
                key: ValueKey('guide-chapter-${i + 1}'),
                contentPadding: EdgeInsets.zero,
                title: Text(c.heading, style: TextStyle(fontSize: 17, color: k.text)),
                subtitle: Text('${c.sections.length} sections', style: TextStyle(color: k.secondary)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(c),
              )
          else if (hits.isEmpty)
            Text('Nothing in the guide matches.', style: TextStyle(fontSize: 15, color: k.secondary))
          else
            for (final s in hits)
              ListTile(
                key: ValueKey('guide-hit-${s.slug}'),
                contentPadding: EdgeInsets.zero,
                title: Text(s.heading, style: TextStyle(fontSize: 16, color: k.text)),
                subtitle: Text(s.chapter.heading, style: TextStyle(color: k.secondary)),
                onTap: () => _open(s.chapter, s),
              ),
        ],
      ),
    );
  }
}

/// One chapter, all its sections on one page, opened at [section] when it is given. Links to other sections move there; app
/// links open that part of Cache over the guide, which keeps its place.
class GuideChapterScreen extends StatefulWidget {
  const GuideChapterScreen({super.key, required this.book, required this.chapter, this.section});

  final GuideBook book;
  final GuideChapter chapter;
  final GuideSection? section;

  @override
  State<GuideChapterScreen> createState() => GuideChapterScreenState();
}

class GuideChapterScreenState extends State<GuideChapterScreen> {
  final ScrollController scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};

  @override
  void initState() {
    super.initState();
    final s = widget.section;
    if (s != null) WidgetsBinding.instance.addPostFrameCallback((_) => _show(s));
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _show(GuideSection s) {
    final c = _keys[s.slug]?.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _link(String? href) async {
    if (href == null) return;
    if (href.startsWith('#')) {
      final s = widget.book.bySlug(href.substring(1));
      if (s == null) return;
      if (identical(s.chapter, widget.chapter)) {
        _show(s);
      } else {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GuideChapterScreen(book: widget.book, chapter: s.chapter, section: s)));
      }
      return;
    }
    if (!isAppLink(href)) return; // the guide works offline: web links do not open
    final place = appPlaceOf(href);
    final screen = place == null ? null : appPlaceScreen?.call(place);
    if (place == AppPlace.drawArea && openAppPlace != null) {
      // Drawing an area happens on the map itself.
      Navigator.of(context).popUntil((r) => r.isFirst);
      openAppPlace!(place!);
      return;
    }
    if (screen == null) {
      _say(kUnknownAppLink);
      return;
    }
    await Navigator.of(context).push(AppPlaceRoute(child: screen));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final style = answerStyle(k);
    final c = widget.chapter;
    return Scaffold(
      appBar: AppBar(title: Text(c.heading, maxLines: 1, overflow: TextOverflow.ellipsis)),
      // Not a lazy list: every section is laid out, so a link can scroll to any of them.
      body: SingleChildScrollView(
        key: const ValueKey('guide-chapter-page'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          if (c.intro.isNotEmpty) MarkdownBody(data: widget.book.linkSections(c.intro), styleSheet: style, onTapLink: (_, href, _) => _link(href)),
          for (final s in c.sections) ...[
            Padding(
              key: _keys.putIfAbsent(s.slug, GlobalKey.new),
              padding: const EdgeInsets.only(top: 20, bottom: 6),
              child: Text(s.heading, key: ValueKey('guide-section-${s.slug}'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
            ),
            MarkdownBody(data: widget.book.linkSections(s.body), styleSheet: style, onTapLink: (_, href, _) => _link(href)),
          ],
          ],
        ),
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
