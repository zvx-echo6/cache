import 'package:flutter/material.dart';

import '../layout/adaptive.dart' show ReadingWidth, paneClose;
import '../search/search_access.dart';
import '../theme.dart';

/// Reads the saved text of a built-library result through the same core as search.
class LibraryPassageScreen extends StatefulWidget {
  const LibraryPassageScreen({super.key, required this.sources, required this.address});
  final SearchAccess sources;
  final String address;

  @override
  State<LibraryPassageScreen> createState() => _LibraryPassageScreenState();
}

class _LibraryPassageScreenState extends State<LibraryPassageScreen> {
  late Future<ReadPage> _page;

  @override
  void initState() {
    super.initState();
    _page = _read();
  }

  Future<ReadPage> _read() => Future<ReadPage>.sync(() => widget.sources.read(widget.address, maxChars: 6000));

  @override
  void didUpdateWidget(covariant LibraryPassageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.address != widget.address || oldWidget.sources != widget.sources) _page = _read();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ReadPage>(
    future: _page,
    builder: (context, snapshot) {
      final ready = snapshot.connectionState == ConnectionState.done;
      final page = ready && !snapshot.hasError ? snapshot.data : null;
      final title = page?.title.trim().isNotEmpty == true ? page!.title : 'Library passage';
      final close = Navigator.of(context).canPop() ? () => Navigator.of(context).pop() : paneClose(context);
      final colors = context.t;
      return Scaffold(
        appBar: AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: close == null ? null : IconButton(tooltip: 'Back to Library', onPressed: close, icon: const Icon(Icons.arrow_back)),
        ),
        body: !ready
            ? const Center(child: CircularProgressIndicator())
            : page == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This passage could not be opened.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('retry-library-passage'),
                      onPressed: () => setState(() {
                        _page = _read();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ReadingWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The page as printed: a number, or a label that is text ("iv", "A-3").
                      if (page.pageLabel ?? page.page?.toString() case final label?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text('Page $label', style: TextStyle(fontSize: 13, color: colors.secondary)),
                        ),
                      SelectableText(
                        page.text,
                        key: const ValueKey('library-passage-text'),
                        style: TextStyle(fontSize: 18, height: 1.5, color: colors.text),
                      ),
                      if (page.truncated)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text('Showing part of this text.', style: TextStyle(fontSize: 13, color: colors.secondary)),
                        ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
