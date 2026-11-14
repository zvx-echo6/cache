import 'package:flutter/material.dart';

import '../layout/adaptive.dart' show ReadingWidth, paneClose;
import '../search/search_access.dart';
import '../theme.dart';

/// The wash the PDF reader paints over a cited passage.
const Color _kPassageMark = Color(0x66FFD54F);

/// What the screen shows: the document, and the text of the passage that was opened (to mark it), when it could be read.
class _Loaded {
  const _Loaded(this.document, this.passage);
  final ReadDocument document;
  final String? passage;
}

/// Reads a whole library document, page by page, from the passage the reader came from. The pages are built as they scroll
/// into view, and the list opens at the page holding that passage, which is marked.
class LibraryDocumentScreen extends StatefulWidget {
  const LibraryDocumentScreen({super.key, required this.sources, required this.address});
  final SearchAccess sources;
  final String address;

  @override
  State<LibraryDocumentScreen> createState() => _LibraryDocumentScreenState();
}

class _LibraryDocumentScreenState extends State<LibraryDocumentScreen> {
  late Future<_Loaded> _loaded;
  final _centre = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loaded = _load();
  }

  Future<_Loaded> _load() async {
    final doc = await widget.sources.readDocument(widget.address);
    String? passage;
    try {
      passage = (await widget.sources.read(widget.address, maxChars: 6000)).text.trim();
    } catch (_) {
      passage = null; // the document still reads; only the mark is lost
    }
    return _Loaded(doc, passage);
  }

  @override
  void didUpdateWidget(covariant LibraryDocumentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.address != widget.address || oldWidget.sources != widget.sources) _loaded = _load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Loaded>(
    future: _loaded,
    builder: (context, snapshot) {
      final ready = snapshot.connectionState == ConnectionState.done;
      final loaded = ready && !snapshot.hasError ? snapshot.data : null;
      final title = loaded?.document.title.trim().isNotEmpty == true ? loaded!.document.title : 'Document';
      final close = Navigator.of(context).canPop() ? () => Navigator.of(context).pop() : paneClose(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: close == null ? null : IconButton(tooltip: 'Back', onPressed: close, icon: const Icon(Icons.arrow_back)),
        ),
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : loaded == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This document could not be opened.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('retry-library-document'),
                      onPressed: () => setState(() {
                        _loaded = _load();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              )
            : _pages(context, loaded),
      );
    },
  );

  Widget _pages(BuildContext context, _Loaded loaded) {
    final doc = loaded.document;
    final colors = context.t;
    final pages = doc.pages;
    final at = pages.isEmpty ? 0 : doc.atPage.clamp(0, pages.length - 1);
    final style = TextStyle(fontSize: 18, height: 1.5, color: colors.text);
    final side = ReadingWidth.padFor(context, MediaQuery.sizeOf(context).width, min: 24);

    Widget pageAt(int i) {
      final p = pages[i];
      final label = p.pageLabel;
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('p. $label', key: ValueKey('document-page-heading-$i'), style: TextStyle(fontSize: 13, color: colors.secondary)),
              ),
            _pageText(i, p, i == at ? loaded.passage : null, style),
          ],
        ),
      );
    }

    // Pages from the opened one onward grow down from the centre; the ones before it grow up from it, so the list opens at the
    // opened page without measuring anything above it, and every page is built only when it comes into view.
    return CustomScrollView(
      center: _centre,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side.left, 0, side.right, 0),
          sliver: SliverList.builder(itemCount: at, itemBuilder: (_, i) => pageAt(at - 1 - i)),
        ),
        SliverPadding(
          key: _centre,
          padding: EdgeInsets.fromLTRB(side.left, 24, side.right, 24),
          sliver: SliverList.builder(
            itemCount: pages.length - at + (doc.truncated ? 1 : 0),
            itemBuilder: (_, i) => at + i < pages.length
                ? pageAt(at + i)
                : Text('The rest of this document is too long to show here.', style: TextStyle(fontSize: 13, color: colors.secondary)),
          ),
        ),
      ],
    );
  }

  /// A page's text, selectable. The opened passage, when it is on this page, carries the wash.
  Widget _pageText(int i, DocumentPageText p, String? passage, TextStyle style) {
    final key = ValueKey('document-page-text-$i');
    final at = passage == null || passage.isEmpty ? -1 : p.text.indexOf(passage);
    if (at < 0) {
      // A page of one passage is that passage, whatever its text, even when the opened copy was cut shorter.
      if (passage != null && passage.isNotEmpty && p.addresses.length == 1) {
        return SelectableText.rich(TextSpan(text: p.text, style: style.copyWith(backgroundColor: _kPassageMark)), key: key);
      }
      return SelectableText(p.text, key: key, style: style);
    }
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: p.text.substring(0, at)),
          TextSpan(text: passage, style: const TextStyle(backgroundColor: _kPassageMark)),
          TextSpan(text: p.text.substring(at + passage!.length)),
        ],
      ),
      key: key,
    );
  }
}
