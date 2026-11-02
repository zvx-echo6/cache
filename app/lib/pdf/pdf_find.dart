import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pdf_text_match.dart';

/// Find in a PDF: the pages' text is searched one page at a time, the matches come in as they are found, the search can be
/// stopped at any time and a new one replaces it. A page with no text (a scanned picture) is skipped and counted.
class PdfFind extends ChangeNotifier {
  PdfFind({required this.pageCount, required this.pageText, this.pause = const Duration(milliseconds: 300)});

  final int pageCount;

  /// The text of page n (from 1); empty for a page with no text layer.
  final Future<String> Function(int page) pageText;

  /// The pause after typing before the search runs.
  final Duration pause;

  String _query = '';
  String get query => _query;

  final List<PdfTextSpan> matches = [];

  /// The current match (an index into [matches]), or -1.
  int current = -1;

  /// True while pages are still being searched.
  bool searching = false;

  /// Pages searched so far in the running or last search.
  int pagesDone = 0;

  /// Pages with no text met so far.
  int scannedSkipped = 0;

  /// Set for a moment when next or previous went round the end (the count flashes).
  bool wrapped = false;

  /// Called when the current match changes (the viewer scrolls it to the middle).
  void Function(PdfTextSpan match)? onCurrent;

  Timer? _debounce;
  Timer? _flash;
  int _generation = 0;

  /// The query as typed: the search runs after [pause].
  void type(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      clear();
      return;
    }
    _debounce = Timer(pause, () => run(q));
  }

  /// Runs a search for [q] now (a running one stops).
  Future<void> run(String q) async {
    _debounce?.cancel();
    final gen = ++_generation;
    _query = q.trim();
    matches.clear();
    current = -1;
    pagesDone = 0;
    scannedSkipped = 0;
    if (_query.isEmpty) {
      searching = false;
      notifyListeners();
      return;
    }
    final pattern = findPattern(_query);
    searching = true;
    notifyListeners();
    var lastNotice = DateTime.now();
    for (var p = 1; p <= pageCount; p++) {
      String text;
      try {
        text = await pageText(p);
      } catch (_) {
        text = '';
      }
      if (gen != _generation) return;
      if (text.trim().isEmpty) {
        scannedSkipped++;
      } else {
        for (final m in pattern.allMatches(text)) {
          if (m.end > m.start) matches.add(PdfTextSpan(p, m.start, m.end));
        }
      }
      pagesDone = p;
      if (current < 0 && matches.isNotEmpty) {
        current = 0;
        onCurrent?.call(matches.first);
        notifyListeners();
        lastNotice = DateTime.now();
      } else if (DateTime.now().difference(lastNotice) > const Duration(milliseconds: 120)) {
        notifyListeners();
        lastNotice = DateTime.now();
      }
      // Let the screen draw between pages: the view never freezes on a long file.
      await Future<void>.delayed(Duration.zero);
      if (gen != _generation) return;
    }
    searching = false;
    notifyListeners();
  }

  /// Stops the search and forgets it.
  void clear() {
    _debounce?.cancel();
    _generation++;
    _query = '';
    matches.clear();
    current = -1;
    searching = false;
    pagesDone = 0;
    scannedSkipped = 0;
    notifyListeners();
  }

  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int by) {
    if (matches.isEmpty) return;
    final n = current + by;
    final wrap = n < 0 || n >= matches.length;
    current = (n + matches.length) % matches.length;
    if (wrap) {
      wrapped = true;
      _flash?.cancel();
      _flash = Timer(const Duration(milliseconds: 700), () {
        wrapped = false;
        notifyListeners();
      });
    }
    onCurrent?.call(matches[current]);
    notifyListeners();
  }

  /// The matches on page [page], with whether each is the current one.
  Iterable<(PdfTextSpan, bool)> on(int page) sync* {
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.page == page) yield (m, i == current);
    }
  }

  /// The count line: "Searching...", "12 found so far", "3 of 17" or "No matches".
  String get countText {
    if (_query.isEmpty) return '';
    if (searching) return matches.isEmpty ? 'Searching...' : '${matches.length} found so far';
    if (matches.isEmpty) return 'No matches';
    return '${current + 1} of ${matches.length}';
  }

  /// What a screen reader says for the count.
  String get countLabel {
    if (!searching && matches.isNotEmpty) return 'Match ${current + 1} of ${matches.length}';
    return countText;
  }

  /// True when some pages were skipped for having no text, but not all (a mixed PDF).
  bool get skippedSome => scannedSkipped > 0 && scannedSkipped < pagesDone;

  @override
  void dispose() {
    _debounce?.cancel();
    _flash?.cancel();
    _generation++;
    super.dispose();
  }
}
