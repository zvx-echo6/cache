import 'dart:async';

import 'package:flutter/material.dart';

import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../theme.dart';
import 'entry_editor.dart';
import 'notebook_screen.dart';
import 'quick_add_sheet.dart';

/// Search across every notebook (or one, [notebookId]): results grouped by notebook, each with its snippet (the matched words in
/// bold) and date. The same keyword search the core keeps for Notebooks.
class NotebookSearchScreen extends StatefulWidget {
  const NotebookSearchScreen({super.key, required this.deps, this.notebookId});

  final NotebookDeps deps;
  final String? notebookId;

  @override
  State<NotebookSearchScreen> createState() => _NotebookSearchScreenState();
}

class _NotebookSearchScreenState extends State<NotebookSearchScreen> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  List<NbHit> _hits = const [];
  String _asked = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(q));
  }

  Future<void> _run(String q) async {
    try {
      final hits = await widget.deps.notebook.search(q, notebookId: widget.notebookId);
      if (mounted) {
        setState(() {
          _hits = hits;
          _asked = q;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _hits = const []);
    }
  }

  void _open(NbHit h) {
    final nb = widget.deps.notebook;
    final book = nb.notebook(h.entry.notebookId);
    if (book == null) return;
    if (book.isLog) {
      showQuickAdd(context, notebook: nb, log: book, places: widget.deps.places, entry: h.entry, now: widget.deps.now);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EntryEditor(notebook: nb, book: book, places: widget.deps.places, entry: h.entry, now: widget.deps.now),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final now = widget.deps.now();
    final groups = <String, List<NbHit>>{};
    for (final h in _hits) {
      groups.putIfAbsent(h.notebook, () => []).add(h);
    }
    final name = widget.notebookId == null ? null : widget.deps.notebook.notebook(widget.notebookId!)?.name;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const ValueKey('search-field'),
          controller: _q,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: name == null ? 'Search notebooks' : 'Search $name', border: InputBorder.none),
          onChanged: _changed,
          onSubmitted: _run,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (_asked.trim().isNotEmpty && _hits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text('Nothing found for "$_asked".', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: k.secondary)),
            ),
          for (final g in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
              child: Text(g.key.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: k.secondary)),
            ),
            for (final h in g.value)
              ListTile(
                key: ValueKey('hit-${h.entry.id}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(h.entry.title?.trim().isNotEmpty == true ? h.entry.title! : dayTimeText(h.entry.when, now: now)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(snippetSpan(h.snippet, TextStyle(color: k.secondary), TextStyle(color: k.text, fontWeight: FontWeight.w700)), maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(dayText(h.entry.when, now: now), style: TextStyle(fontSize: 13, color: k.secondary)),
                  ],
                ),
                onTap: () => _open(h),
              ),
          ],
        ],
      ),
    );
  }
}

/// The core's snippet with the matched words (between U+0002 and U+0003) in [hit].
TextSpan snippetSpan(String s, TextStyle normal, TextStyle hit) {
  final spans = <TextSpan>[];
  var bold = false;
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString(), style: bold ? hit : normal));
    buf.clear();
  }

  for (final ch in s.split('')) {
    if (ch == '\u0002' || ch == '\u0003') {
      flush();
      bold = ch == '\u0002';
    } else {
      buf.write(ch == '\n' ? ' ' : ch);
    }
  }
  flush();
  return TextSpan(children: spans, style: normal);
}
