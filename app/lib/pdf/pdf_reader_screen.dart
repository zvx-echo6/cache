import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../layout/adaptive.dart' show isShort, kDesktopMinWidth;
import '../screens/download_confirm.dart' show openStorageForSpace;
import '../settings/hub.dart' show openInSystemBrowser;
import '../theme.dart';
import '../video/format.dart';
import 'index/pdf_pages.dart' show cleanPdfTitle, readPdfMeta;
import 'pdf_find.dart';
import 'pdf_settings.dart';
import 'pdf_source.dart';
import 'pdf_text_match.dart';

export 'pdf_settings.dart';

/// The widest fit width on a desktop window (1280 and up): a page wider than this reads badly, so it is centred on the surround.
const double kPdfMaxFitWidth = 840;

/// The window width from which the reader lays out as on a desktop (the app's desktop width class).
const double kPdfDesktopWidth = kDesktopMinWidth;

/// The widest the find row gets on a desktop.
const double kPdfFindRowMaxWidth = 480;

/// Pinch zoom goes from the fit to four times fit width.
const double kPdfMaxZoomTimesFit = 4;

/// A page is never drawn larger than this many device pixels along its longer side: past it zoom stops ("Zoom limited").
const double kPdfMaxPagePixels = 16384;

/// The states of the reader before the pages show, for the review renders and tests (the real ones come from opening).
enum PdfDebugPhase { opening, slow, copying, noSpace, locked, wrongPassword, damaged, gone }

enum _Phase { preparing, copying, opening, open, locked, damaged, gone, noSpace }

enum _Fit { width, page }

/// The built-in PDF reader: pages in one continuous scroll, the page number in the top bar (tap to go to a page), find in the
/// PDF, previous page, fit and next page in the bottom bar, pinch zoom. Opens at [initialPage] (from 1), and with a [quote]
/// (the cited passage's text) highlights it on that page.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
    super.key,
    required this.source,
    this.initialPage,
    this.quote,
    this.debugPhase,
    this.debugFileBytes,
    this.debugZoomLimited = false,
    this.debugFindStallAfter,
    this.debugPlaceholders = false,
    this.debugBrowser = false,
    this.debugReadTitle,
  });

  final PdfSource source;

  /// The page to open at (from 1); the first page when null.
  final int? initialPage;

  /// The cited passage, as the search index holds its text (at most 300 words); null when only a page is known.
  final String? quote;

  /// Renders and tests: show this state instead of opening.
  final PdfDebugPhase? debugPhase;

  /// Renders and tests: the file size the slow-opening line names.
  final int? debugFileBytes;

  /// Renders and tests: zoom is capped on this device (the label shows).
  final bool debugZoomLimited;

  /// Renders and tests: find stops reading pages after this page (to show a search still running).
  final int? debugFindStallAfter;

  /// Renders and tests: every page but the current one is drawn as not yet read (a large file while scrolling).
  final bool debugPlaceholders;

  /// Renders and tests: word the slow-opening line as in a browser.
  final bool debugBrowser;

  /// Tests: hold metadata reading to verify that closing cannot dispose its document.
  final Future<String?> Function(PdfDocument document)? debugReadTitle;

  @override
  State<PdfReaderScreen> createState() => PdfReaderScreenState();
}

/// The reader's state; public so tests can read where the view is ([debugVisibleRect], [debugPageRect], [debugCitedTop]).
class PdfReaderScreenState extends State<PdfReaderScreen> {
  _Phase _phase = _Phase.preparing;
  String? _path;
  PdfTempCopy? _copy;
  double? _copyProgress;
  int? _needBytes;
  int? _fileBytes;
  bool _cancelled = false;
  PdfDocument? _doc;
  bool _readingTitle = false;
  PdfDocumentRef? _ref;

  /// The PDF's own title (its metadata Title, cleaned as the search index cleans it), once read: the reader shows the title its
  /// search results and citations show. Null: the source's (the file name).
  String? _ownTitle;
  final PdfViewerController _controller = PdfViewerController();

  bool _showOpening = false;
  bool _slow = false;
  Timer? _openingTimer;
  Timer? _slowTimer;

  final TextEditingController _password = TextEditingController();
  bool _wrongPassword = false;

  int _page = 1;
  int _pageCount = 0;
  bool _ready = false;
  bool _barsShown = true;
  _Fit _fit = _Fit.width;
  String? _fitLabel;
  Timer? _fitLabelTimer;
  bool _zoomLimited = false;
  bool _showZoomLimited = false;
  Timer? _zoomLabelTimer;
  double _maxZoom = 8;

  /// The page the screen reader was last told (a page change is announced when scrolling stops, not on every frame).
  int _announcedPage = 1;
  Timer? _announce;

  // Find.
  bool _finding = false;
  PdfFind? _find;
  final TextEditingController _findText = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  // The text of the pages: the plain text of every page searched (for find), and the full text layer (character boxes, for
  // highlights) of the few pages last drawn.
  final Map<int, String> _plain = {};
  final LinkedHashMap<int, PdfPageText> _layers = LinkedHashMap();
  final Map<int, Future<PdfPageText?>> _loading = {};
  static const int _keepLayers = 16;

  /// Pages known to have no text, and whether the whole PDF has none (a scanned PDF).
  final Set<int> _textless = {};
  bool _scanned = false;
  bool _scannedDismissed = false;

  // Opening at a page with a cited passage.
  List<PdfTextSpan> _cited = const [];
  String? _strip;
  bool _stripFindOther = false;

  @override
  void initState() {
    super.initState();
    if (widget.debugPhase != null) {
      _applyDebug(widget.debugPhase!);
      return;
    }
    unawaited(_start());
  }

  void _applyDebug(PdfDebugPhase p) {
    _fileBytes = widget.debugFileBytes;
    switch (p) {
      case PdfDebugPhase.opening:
        _phase = _Phase.opening;
        _showOpening = true;
      case PdfDebugPhase.slow:
        _phase = _Phase.opening;
        _showOpening = true;
        _slow = true;
      case PdfDebugPhase.copying:
        _phase = _Phase.copying;
        _copyProgress = 0.4;
      case PdfDebugPhase.noSpace:
        _phase = _Phase.noSpace;
        _needBytes = widget.debugFileBytes ?? 340 << 20;
      case PdfDebugPhase.locked:
        _phase = _Phase.locked;
      case PdfDebugPhase.wrongPassword:
        _phase = _Phase.locked;
        _wrongPassword = true;
        _password.text = 'password';
      case PdfDebugPhase.damaged:
        _phase = _Phase.damaged;
      case PdfDebugPhase.gone:
        _phase = _Phase.gone;
    }
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.preparing;
      _cancelled = false;
    });
    _armOpeningTimers();
    try {
      final (path, copy) = await preparePdf(
        widget.source,
        cancelled: () => _cancelled || !mounted,
        onCopying: (p) {
          if (mounted) {
            setState(() {
              _phase = _Phase.copying;
              _copyProgress = p;
            });
          }
        },
      );
      if (!mounted) {
        await copy?.dispose();
        return;
      }
      _path = path;
      _copy = copy;
      try {
        _fileBytes = await File(path).length();
      } catch (_) {}
      await _open();
    } on PdfNoSpace catch (e) {
      _setPhase(_Phase.noSpace, () => _needBytes = e.bytes);
    } on PdfGone {
      _setPhase(_Phase.gone);
    } on PdfCancelled {
      // The reader is closing.
    } catch (_) {
      _setPhase(_Phase.damaged);
    }
  }

  void _armOpeningTimers() {
    _openingTimer?.cancel();
    _slowTimer?.cancel();
    _showOpening = false;
    _slow = false;
    _openingTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showOpening = true);
    });
    _slowTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  void _setPhase(_Phase p, [VoidCallback? also]) {
    _openingTimer?.cancel();
    _slowTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _phase = p;
      also?.call();
    });
  }

  Future<void> _open({String? password}) async {
    final path = _path;
    if (path == null) return;
    setState(() => _phase = _Phase.opening);
    try {
      if (!await File(path).exists()) throw const PdfGone();
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openFile(
        path,
        passwordProvider: password == null ? null : createSimplePasswordProvider(password),
        firstAttemptByEmptyPassword: password == null,
        useProgressiveLoading: true,
      );
      if (!mounted) {
        await doc.dispose();
        return;
      }
      // Keep ownership local until the metadata worker has finished. Publishing
      // the viewer first lets its reference dispose the raw handle during this read.
      _readingTitle = true;
      String? ownTitle;
      try {
        ownTitle = await (widget.debugReadTitle?.call(doc) ?? _readOwnTitle(doc));
      } catch (_) {
        // Metadata is optional; a readable PDF still opens without a title.
      } finally {
        _readingTitle = false;
      }
      if (!mounted) {
        await doc.dispose();
        await _copy?.dispose();
        return;
      }
      _doc = doc;
      _ownTitle = ownTitle;
      _pageCount = doc.pages.length;
      _ref = PdfDocumentRefDirect(doc);
      final start = widget.initialPage ?? 1;
      _page = start >= 1 && start <= _pageCount ? start : 1;
      _announcedPage = _page;
      final stall = widget.debugFindStallAfter;
      _find = PdfFind(pageCount: _pageCount, pageText: stall == null ? _plainText : (p) => p > stall ? Completer<String>().future : _plainText(p))
        ..onCurrent = _goToMatch;
      _setPhase(_Phase.open, () => _wrongPassword = false);
      unawaited(_afterOpen(start));
    } on PdfPasswordException {
      _setPhase(_Phase.locked, () => _wrongPassword = password != null);
    } on PdfGone {
      _setPhase(_Phase.gone);
    } catch (_) {
      _setPhase(_Phase.damaged);
    }
  }

  /// Once the PDF is open: whether it has text, and the cited passage.
  Future<void> _afterOpen(int asked) async {
    final probe = math.min(_pageCount, 8);
    var withText = 0;
    for (var p = 1; p <= probe; p++) {
      if ((await _plainText(p)).trim().isNotEmpty) withText++;
      if (!mounted) return;
    }
    final scanned = probe > 0 && withText == 0;
    if (asked < 1 || asked > _pageCount) {
      if (widget.initialPage != null) _say('This PDF has $_pageCount pages. Cited page $asked is not here.');
    } else if (widget.quote != null && widget.quote!.trim().isNotEmpty) {
      await _placeQuote(asked, widget.quote!);
    }
    if (mounted) setState(() => _scanned = scanned);
  }

  Future<void> _placeQuote(int page, String quote) async {
    final layer = await _layer(page);
    if (!mounted) return;
    if (layer == null || layer.fullText.trim().isEmpty) {
      _say('Page $page. Scanned page, nothing to highlight.');
      return;
    }
    final next = page < _pageCount ? await _layer(page + 1) : null;
    final spans = findQuote(
      quote,
      pageNumber: page,
      page: pdfWords(layer.fullText),
      next: next == null ? null : pdfWords(next.fullText),
    );
    if (!mounted) return;
    if (spans == null || spans.isEmpty) {
      _say('Page $page. The exact passage was not found on this page.', findOther: true);
      return;
    }
    setState(() {
      _cited = spans;
      _strip = 'Cited passage';
      _stripFindOther = false;
    });
    _controller.invalidate();
    _goToSpan(spans.first);
  }

  void _say(String text, {bool findOther = false}) {
    if (!mounted) return;
    setState(() {
      _strip = text;
      _stripFindOther = findOther;
    });
  }

  void _clearCited() {
    if (_strip == null && _cited.isEmpty) return;
    setState(() {
      _strip = null;
      _cited = const [];
      _stripFindOther = false;
    });
    if (_ready) _controller.invalidate();
  }

  // ---- page text

  Future<String> _plainText(int page) async {
    final known = _plain[page];
    if (known != null) return known;
    final t = await _layer(page);
    final text = t?.fullText ?? '';
    _plain[page] = text;
    if (text.trim().isEmpty) _textless.add(page);
    return text;
  }

  Future<PdfPageText?> _layer(int page) {
    final have = _layers.remove(page);
    if (have != null) {
      _layers[page] = have;
      return Future.value(have);
    }
    return _loading[page] ??= () async {
      try {
        final doc = _doc;
        if (doc == null || page < 1 || page > doc.pages.length) return null;
        final p = await doc.pages[page - 1].waitForLoaded(timeout: const Duration(seconds: 30));
        if (p == null) return null;
        final t = await p.loadStructuredText();
        _layers[page] = t;
        while (_layers.length > _keepLayers) {
          _layers.remove(_layers.keys.first);
        }
        _plain[page] ??= t.fullText;
        return t;
      } catch (_) {
        return null;
      } finally {
        unawaited(Future<void>.microtask(() => _loading.remove(page)));
      }
    }();
  }

  // ---- moving

  /// The gap kept above a page's top, or above a cited passage, when the reader moves to it (logical pixels).
  static const double _topGap = 24;

  /// Scrolls so that document position [y] sits [gap] below the top of the view, at the zoom the person has; across, the view
  /// stays where it is unless [x] is given.
  void _placeAtTop(double y, {double gap = 0, double? x, bool animate = true}) {
    final z = _controller.currentZoom;
    final cy = y - gap / z + _controller.viewSize.height / 2 / z;
    unawaited(_controller.goTo(_controller.calcMatrixFor(Offset(x ?? _controller.centerPosition.dx, cy), zoom: z), duration: animate ? const Duration(milliseconds: 220) : Duration.zero));
  }

  /// Page [page] with its top at the top of the view (the previous page out of sight).
  void _goToPage(int page, {bool animate = true}) {
    if (!_ready) return;
    final n = page.clamp(1, _pageCount);
    _placeAtTop(_controller.layout.pageLayouts[n - 1].top, animate: animate);
  }

  @visibleForTesting
  Rect? get debugVisibleRect => _ready ? _controller.visibleRect : null;

  @visibleForTesting
  Rect? debugPageRect(int page) => _ready ? _controller.layout.pageLayouts[page - 1] : null;

  /// The top of the first cited line, in document coordinates.
  @visibleForTesting
  double? get debugCitedTop => _citedTop;
  double? _citedTop;

  void _goToSpan(PdfTextSpan s) {
    if (!_ready) {
      _pendingSpan = s;
      return;
    }
    final layer = _layers[s.page];
    if (layer == null) {
      _goToPage(s.page, animate: false);
      return;
    }
    // The match to the middle of the view, at the zoom the person has.
    final page = _doc!.pages[s.page - 1];
    final r = PdfPageTextRange(pageText: layer, start: s.start, end: s.end).bounds.toRectInDocument(page: page, pageRect: _controller.layout.pageLayouts[s.page - 1]);
    final visible = _controller.visibleRect;
    final x = r.left >= visible.left && r.right <= visible.right ? null : r.center.dx;
    if (_cited.isNotEmpty && identical(s, _cited.first)) {
      // A cited passage opens near the top of the view, a small gap above it, the strip above that.
      _citedTop = r.top;
      _placeAtTop(r.top, gap: _topGap, x: x, animate: false);
      return;
    }
    // A find match to the middle of the view.
    final z = _controller.currentZoom;
    unawaited(_controller.goTo(_controller.calcMatrixFor(Offset(x ?? _controller.centerPosition.dx, r.center.dy), zoom: z), duration: const Duration(milliseconds: 200)));
  }

  PdfTextSpan? _pendingSpan;

  void _goToMatch(PdfTextSpan m) {
    unawaited(_layer(m.page).then((_) {
      if (mounted) {
        _goToSpan(m);
        _controller.invalidate();
      }
    }));
  }

  // ---- zoom and fit

  bool get _desktop => MediaQuery.sizeOf(context).width >= kPdfDesktopWidth;

  double _fitWidthZoom(int page) {
    final r = _controller.layout.pageLayouts[page - 1];
    final margin = _controller.params.margin;
    final w = _desktop ? math.min(_controller.viewSize.width, kPdfMaxFitWidth) : _controller.viewSize.width;
    return (w - margin * 2) / r.width;
  }

  Matrix4 _fitWidthMatrix(int page) {
    final r = _controller.layout.pageLayouts[page - 1];
    final z = _fitWidthZoom(page);
    final y = (_controller.viewSize.height / 2 - _controller.params.margin) / z;
    return _controller.calcMatrixFor(r.topCenter.translate(0, y), zoom: z);
  }

  void _setFit(_Fit f, {bool label = true}) {
    if (!_ready) return;
    final m = f == _Fit.width ? _fitWidthMatrix(_page) : _controller.calcMatrixForFit(pageNumber: _page);
    if (m != null) unawaited(_controller.goTo(m, duration: const Duration(milliseconds: 200)));
    setState(() {
      _fit = f;
      if (label) _fitLabel = f == _Fit.width ? 'Fit width' : 'Fit page';
    });
    _fitLabelTimer?.cancel();
    _fitLabelTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _fitLabel = null);
    });
  }

  void _toggleZoom() {
    if (!_ready) return;
    final fw = _fitWidthZoom(_page);
    final zoomed = _controller.currentZoom > fw * 1.5;
    if (zoomed) {
      _setFit(_Fit.width, label: false);
    } else {
      unawaited(_controller.setZoom(_controller.centerPosition, math.min(fw * 2, _maxZoom)));
    }
  }

  /// The zoom range: from the fit to four times fit width, less on a huge page (the longer side stays under
  /// [kPdfMaxPagePixels] device pixels).
  void _computeZoomRange() {
    if (!_ready) return;
    final fw = _fitWidthZoom(_page);
    final want = fw * kPdfMaxZoomTimesFit;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    var longest = 1.0;
    for (final p in _doc!.pages) {
      longest = math.max(longest, math.max(p.width, p.height));
    }
    final cap = kPdfMaxPagePixels / (longest * dpr);
    final maxZoom = math.min(want, cap);
    if ((maxZoom - _maxZoom).abs() > 1e-6 || _zoomLimited != (cap < want)) {
      setState(() {
        _maxZoom = maxZoom;
        _zoomLimited = cap < want;
      });
    }
  }

  void _interactionEnded() {
    if (_zoomLimited && _controller.currentZoom >= _maxZoom * 0.98) {
      setState(() => _showZoomLimited = true);
      _zoomLabelTimer?.cancel();
      _zoomLabelTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showZoomLimited = false);
      });
    }
    _announceSoon();
  }

  void _announceSoon() {
    _announce?.cancel();
    _announce = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _announcedPage != _page) setState(() => _announcedPage = _page);
    });
  }

  // ---- find

  void _openFind({String? text}) {
    setState(() => _finding = true);
    if (text != null) {
      _findText.text = text;
      unawaited(_find?.run(text));
    }
    if (!_scanned) _findFocus.requestFocus();
  }

  void _closeFind() {
    _find?.clear();
    _findText.clear();
    _findFocus.unfocus();
    setState(() => _finding = false);
    if (_ready) _controller.invalidate();
  }

  // ---- links

  void _onLink(PdfLink link) {
    final url = link.url;
    if (url != null) {
      unawaited(_askToOpen(url));
      return;
    }
    final dest = link.dest;
    if (dest != null) unawaited(_controller.goToDest(dest));
  }

  Future<void> _askToOpen(Uri url) async {
    final ok = await askToOpenPdfLink(context);
    if (ok == true) {
      try {
        await openInSystemBrowser(url.toString());
      } catch (_) {}
    }
  }

  // ---- painting over the pages

  void _paintPage(ui.Canvas canvas, Rect rect, PdfPage page) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (!page.isLoaded || (widget.debugPlaceholders && page.pageNumber != _page)) {
      // Not read yet (a large file): a grey page with its number.
      canvas.drawRect(rect, Paint()..color = const Color(0xFFBDBDBD));
      final tp = TextPainter(
        text: TextSpan(text: '${page.pageNumber}', style: TextStyle(fontSize: rect.width / 10, color: const Color(0xFF757575), fontFamily: 'Roboto')),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
    }
    if (dark && pdfDarkPages.value) {
      // Dark pages: the page's colours turned over (white paper becomes black, black text white).
      canvas.drawRect(rect, Paint()
        ..color = Colors.white
        ..blendMode = BlendMode.difference);
    } else if (dark) {
      // In a dark theme the pages are dimmed to about 85% so white paper does not glare.
      canvas.drawRect(rect, Paint()..color = const Color(0x26000000));
    }
    final n = page.pageNumber;
    final finds = _finding ? _find?.on(n).toList() ?? const [] : const <(PdfTextSpan, bool)>[];
    final cited = [for (final s in _cited) if (s.page == n) s];
    if (finds.isEmpty && cited.isEmpty) return;
    final layer = _layers[n];
    if (layer == null) {
      unawaited(_layer(n).then((t) {
        if (t != null && mounted && _ready) _controller.invalidate();
      }));
      return;
    }
    final wash = Paint()..color = const Color(0x66FFD54F);
    final current = Paint()..color = const Color(0x66FF9800);
    final ring = Paint()
      ..color = const Color(0xFFF57C00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    void mark(PdfTextSpan s, bool isCurrent) {
      if (s.start < 0 || s.end > layer.fullText.length || s.end <= s.start) return;
      for (final r in _lineRects(PdfPageTextRange(pageText: layer, start: s.start, end: s.end), page, rect)) {
        canvas.drawRect(r, isCurrent ? current : wash);
        if (isCurrent) canvas.drawRect(r, ring);
      }
    }

    for (final (s, isCurrent) in finds) {
      if (!isCurrent) mark(s, false);
    }
    for (final (s, isCurrent) in finds) {
      if (isCurrent) mark(s, true);
    }
    for (final s in cited) {
      mark(s, true);
    }
  }

  /// The boxes of [range] joined into one box per line.
  static List<Rect> _lineRects(PdfPageTextRange range, PdfPage page, Rect pageRect) {
    final rs = [for (final f in range.enumerateFragmentBoundingRects()) f.bounds.toRectInDocument(page: page, pageRect: pageRect)];
    final out = <Rect>[];
    for (final r in rs) {
      final i = out.indexWhere((l) => math.min(l.bottom, r.bottom) - math.max(l.top, r.top) > 0.5 * math.min(l.height, r.height));
      if (i >= 0) {
        out[i] = out[i].expandToInclude(r);
      } else {
        out.add(r);
      }
    }
    return [for (final r in out) r.inflate(1)];
  }

  @override
  void dispose() {
    _openingTimer?.cancel();
    _slowTimer?.cancel();
    _fitLabelTimer?.cancel();
    _zoomLabelTimer?.cancel();
    _announce?.cancel();
    _cancelled = true;
    _find?.dispose();
    _findText.dispose();
    _findFocus.dispose();
    _password.dispose();
    pdfDarkPages.removeListener(_repaint);
    // The viewer's document reference closes the document when the viewer goes; a document that never reached the viewer is
    // closed here.
    if (_ref == null) unawaited(_doc?.dispose());
    if (!_readingTitle) unawaited(_copy?.dispose());
    super.dispose();
  }

  void _repaint() {
    if (_ready) _controller.invalidate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    pdfDarkPages.removeListener(_repaint);
    pdfDarkPages.addListener(_repaint);
  }

  // ---- building

  Future<String?> _readOwnTitle(PdfDocument doc) async {
    try {
      // PDFium stays on its own worker; the caller retains the document until
      // this queued read completes, even if the reader is closed in the meantime.
      final handle = await doc.useNativeDocumentHandle((h) => h);
      final t = cleanPdfTitle((await readPdfMeta(handle, 0)).title);
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final nav = Navigator.of(context);
    final open = _phase == _Phase.open;
    final title = _ownTitle ?? widget.source.title;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _openFind(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => _openFind(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_finding) _closeFind();
        },
      },
      child: PopScope(
        // The system back closes find first; the top-left arrow always leaves.
        canPop: !_finding,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _finding) _closeFind();
        },
        child: Scaffold(
          backgroundColor: k.background,
          appBar: _barsShown || !open ? _topBar(context, k, nav, title) : null,
          body: Column(
            children: [
              if (open && _finding && _barsShown) _findRow(k),
              if (open && _barsShown) ?_stripFor(k),
              Expanded(child: _body(k)),
            ],
          ),
          // A short window (a phone held sideways) has the page buttons in the top bar instead, so the page keeps the height.
          bottomNavigationBar: open && _barsShown && !isShort(context) ? _bottomBar(k) : null,
        ),
      ),
    );
  }

  PreferredSizeWidget _topBar(BuildContext context, CacheTokens k, NavigatorState nav, String title) {
    return AppBar(
      automaticallyImplyLeading: false,
      // Leaves the reader for where it was opened from (Library, a notebook entry, Storage, a search result, a citation).
      leading: nav.canPop()
          ? Semantics(
              label: 'Close $title',
              button: true,
              onTap: () => nav.pop(),
              excludeSemantics: true,
              child: IconButton(
                key: const ValueKey('pdf-close'),
                tooltip: 'Close $title',
                icon: const BackButtonIcon(),
                onPressed: () => nav.pop(),
              ),
            )
          : null,
      titleSpacing: nav.canPop() ? 0 : null,
      title: Row(
        children: [
          // The title gives way first; the page count never shortens.
          Expanded(
            child: Text(title, key: const ValueKey('pdf-title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (_phase == _Phase.open && _pageCount > 0) ...[
            const SizedBox(width: 8),
            _pageCountButton(k),
          ],
        ],
      ),
      actions: [
        if (_phase == _Phase.open && isShort(context)) ..._pageButtons(),
        IconButton(
          key: const ValueKey('pdf-find'),
          tooltip: 'Find in this PDF',
          icon: Icon(_finding ? Icons.find_in_page : Icons.find_in_page_outlined),
          onPressed: _phase == _Phase.open ? () => _finding ? _closeFind() : _openFind() : null,
        ),
      ],
    );
  }

  Widget _pageCountButton(CacheTokens k) {
    return Semantics(
      button: true,
      label: 'Go to page. Page $_announcedPage of $_pageCount',
      liveRegion: true,
      excludeSemantics: true,
      onTap: _goToSheet,
      child: InkWell(
        key: const ValueKey('pdf-page-count'),
        borderRadius: BorderRadius.circular(8),
        onTap: _goToSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text('$_page of $_pageCount', maxLines: 1, softWrap: false, style: TextStyle(fontSize: 16, color: k.text)),
        ),
      ),
    );
  }

  Widget _bottomBar(CacheTokens k) => BottomAppBar(
    height: 56,
    padding: EdgeInsets.zero,
    color: k.surface,
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: _pageButtons()),
  );

  /// Previous page, Fit page or width, Next page: the bottom bar's buttons (the top bar's on a short window).
  List<Widget> _pageButtons() {
    final atStart = _page <= 1;
    final atEnd = _page >= _pageCount;
    final toPage = _fit == _Fit.width;
    return [
          IconButton(
            key: const ValueKey('pdf-prev'),
            tooltip: 'Previous page',
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: atStart || !_ready ? null : () => _goToPage(_page - 1),
          ),
          IconButton(
            key: const ValueKey('pdf-fit'),
            tooltip: toPage ? 'Fit page' : 'Fit width',
            icon: Icon(toPage ? Icons.fit_screen_outlined : Icons.width_full_outlined),
            onPressed: _ready ? () => _setFit(toPage ? _Fit.page : _Fit.width) : null,
          ),
          IconButton(
            key: const ValueKey('pdf-next'),
            tooltip: 'Next page',
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: atEnd || !_ready ? null : () => _goToPage(_page + 1),
          ),
    ];
  }

  Widget? _stripFor(CacheTokens k) {
    final text = _strip ?? (_scanned && !_scannedDismissed ? "This PDF is scanned pictures. Search can't read it." : null);
    if (text == null) return null;
    final isScanned = _strip == null;
    return Material(
      key: const ValueKey('pdf-strip'),
      color: k.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        child: Row(
          children: [
            Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: k.text))),
            if (_stripFindOther)
              TextButton(
                key: const ValueKey('pdf-find-other'),
                onPressed: () {
                  final q = widget.quote;
                  _clearCited();
                  if (q != null) _openFind(text: quoteOpening(q));
                },
                child: const Text('Find on other pages'),
              ),
            IconButton(
              key: const ValueKey('pdf-strip-close'),
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 20),
              onPressed: isScanned ? () => setState(() => _scannedDismissed = true) : _clearCited,
            ),
          ],
        ),
      ),
    );
  }

  Widget _findRow(CacheTokens k) {
    final f = _find;
    final row = Material(
      key: const ValueKey('pdf-find-row'),
      color: k.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
        child: ListenableBuilder(
          listenable: f ?? Listenable.merge(const []),
          builder: (context, _) {
            final count = f?.countText ?? '';
            final extra = f != null && f.skippedSome && !f.searching ? 'Scanned pages skipped' : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => f?.previous(),
                        },
                        child: TextField(
                          key: const ValueKey('pdf-find-field'),
                          controller: _findText,
                          focusNode: _findFocus,
                          enabled: !_scanned,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: _scanned ? 'No searchable text in this PDF.' : 'Find in this PDF',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            filled: false,
                          ),
                          onChanged: (v) {
                            f?.type(v);
                            if (_ready) _controller.invalidate();
                          },
                          onSubmitted: (_) {
                            f?.next();
                            _findFocus.requestFocus();
                          },
                        ),
                      ),
                    ),
                    if (count.isNotEmpty)
                      Semantics(
                        label: f!.countLabel,
                        liveRegion: true,
                        excludeSemantics: true,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 150),
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                            color: f.wrapped ? k.accent : k.secondary,
                            fontWeight: f.wrapped ? FontWeight.w700 : FontWeight.w400,
                          ),
                          child: Text(count, key: const ValueKey('pdf-find-count')),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Previous match',
                      icon: const Icon(Icons.keyboard_arrow_up),
                      onPressed: f == null || f.matches.isEmpty ? null : f.previous,
                    ),
                    IconButton(
                      tooltip: 'Next match',
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: f == null || f.matches.isEmpty ? null : f.next,
                    ),
                    IconButton(
                      key: const ValueKey('pdf-find-close'),
                      tooltip: 'Close find',
                      icon: const Icon(Icons.close),
                      onPressed: _closeFind,
                    ),
                  ],
                ),
                if (extra != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(extra, style: TextStyle(fontSize: 13, color: k.secondary)),
                    ),
                  ),
                if (f != null && f.searching && f.matches.isNotEmpty)
                  LinearProgressIndicator(minHeight: 2, value: f.pageCount == 0 ? null : f.pagesDone / f.pageCount),
              ],
            );
          },
        ),
      ),
    );
    if (!_desktop) return row;
    return Align(alignment: Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kPdfFindRowMaxWidth), child: row));
  }

  Widget _body(CacheTokens k) {
    switch (_phase) {
      case _Phase.preparing:
      case _Phase.opening:
        return _openingView(k);
      case _Phase.copying:
        return _message(
          k,
          'Getting the PDF ready...',
          progress: true,
          actions: [OutlinedButton(key: const ValueKey('pdf-cancel'), onPressed: _cancel, child: const Text('Cancel'))],
        );
      case _Phase.noSpace:
        return _message(
          k,
          'Not enough space to open this PDF on this device. It needs ${formatBytes(_needBytes ?? 0)}.',
          actions: [if (openStorageForSpace != null) FilledButton(onPressed: () => openStorageForSpace!(context), child: const Text('Open Storage'))],
        );
      case _Phase.locked:
        return _lockedView(k);
      case _Phase.damaged:
        return _message(
          k,
          "This PDF can't be opened. The file may be damaged.",
          actions: [
            FilledButton(key: const ValueKey('pdf-retry'), onPressed: _start, child: const Text('Try again')),
            if (widget.source.from == PdfFrom.storage && openStorageForSpace != null)
              OutlinedButton(onPressed: () => openStorageForSpace!(context), child: const Text('Show in Storage')),
          ],
        );
      case _Phase.gone:
        final library = widget.source.from == PdfFrom.library;
        final go = library ? PdfReaderLinks.openLibrary : openStorageForSpace;
        return _message(
          k,
          'This file is no longer on this device.',
          actions: [if (go != null) FilledButton(onPressed: () => go(context), child: Text(library ? 'Open Library' : 'Open Storage'))],
        );
      case _Phase.open:
        return _viewer(k);
    }
  }

  void _cancel() {
    _cancelled = true;
    Navigator.of(context).maybePop();
  }

  Widget _openingView(CacheTokens k) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_showOpening) ...[
              const SizedBox(height: 16),
              Text(
                _slow
                    ? (kIsWeb || widget.debugBrowser ? 'Still opening. Big files can be slow in a browser.' : 'Still opening.${_fileBytes == null ? '' : ' This file is ${formatBytes(_fileBytes!)}.'}')
                    : 'Opening...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: k.text),
              ),
            ],
            if (_slow) ...[
              const SizedBox(height: 16),
              OutlinedButton(key: const ValueKey('pdf-cancel'), onPressed: _cancel, child: const Text('Cancel')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _message(CacheTokens k, String text, {bool progress = false, List<Widget> actions = const []}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, key: const ValueKey('pdf-message'), textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.text)),
              if (progress) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _copyProgress),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _lockedView(CacheTokens k) {
    void submit() {
      final pw = _password.text;
      if (pw.isEmpty) return;
      unawaited(_open(password: pw));
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('This PDF is locked. Enter its password.', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: k.text)),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('pdf-password'),
                controller: _password,
                obscureText: true,
                autofocus: widget.debugPhase == null,
                textInputAction: TextInputAction.go,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  errorText: _wrongPassword ? 'That password is not right.' : null,
                ),
                onChanged: (_) {
                  if (_wrongPassword) setState(() => _wrongPassword = false);
                },
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(key: const ValueKey('pdf-password-open'), onPressed: submit, child: const Text('Open')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _viewer(CacheTokens k) {
    final ref = _ref!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final viewer = PdfViewer(
      ref,
      controller: _controller,
      params: PdfViewerParams(
        margin: 6,
        backgroundColor: dark ? Color.lerp(k.background, Colors.black, 0.35)! : Color.lerp(k.background, Colors.black, 0.08)!,
        pageDropShadow: null,
        textSelectionParams: const PdfTextSelectionParams(enabled: false),
        maxImageBytesCachedOnMemory: 64 << 20,
        horizontalCacheExtent: 0.5,
        verticalCacheExtent: 0.5,
        sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
          maxScale: _maxZoom,
          calculateInitialZoom: _initialZoom,
        ),
        calculateInitialPageNumber: (doc, c) => _page,
        calculateCurrentPageNumber: (visible, rects, c) {
          // The page nearest the middle of the view.
          final mid = visible.center.dy;
          var best = 0;
          var bestD = double.infinity;
          for (var i = 0; i < rects.length; i++) {
            final r = rects[i];
            final d = mid < r.top ? r.top - mid : (mid > r.bottom ? mid - r.bottom : 0.0);
            if (d < bestD) {
              bestD = d;
              best = i;
              if (d == 0) break;
            }
          }
          return best + 1;
        },
        onPageChanged: (n) {
          if (n != null && n != _page && mounted) {
            setState(() => _page = n);
            _announceSoon();
          }
        },
        onViewerReady: (doc, c) {
          if (!mounted) return;
          setState(() => _ready = true);
          _computeZoomRange();
          final s = _pendingSpan;
          _pendingSpan = null;
          // After the first zoom and page are set.
          // After the first zoom and page are set: the cited passage near the top, or the page's top at the top.
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            if (!mounted) return;
            if (s != null) {
              _goToSpan(s);
            } else if (_cited.isEmpty) {
              _goToPage(_page, animate: false);
            }
          });
        },
        onViewSizeChanged: (size, old, c) {
          if (mounted) _computeZoomRange();
        },
        onInteractionEnd: (_) => _interactionEnded(),
        onGeneralTap: (context, c, d) {
          switch (d.type) {
            case PdfViewerGeneralTapType.tap:
              // A tap clears a cited passage first, then shows or hides the bars.
              if (_cited.isNotEmpty || (_strip != null && !_stripFindOther)) {
                _clearCited();
              } else {
                setState(() => _barsShown = !_barsShown);
              }
              return true;
            case PdfViewerGeneralTapType.doubleTap:
              _toggleZoom();
              return true;
            default:
              return false;
          }
        },
        linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLink, linkColor: Colors.transparent),
        pagePaintCallbacks: [_paintPage],
        pageOverlaysBuilder: (context, rect, page) => [
          // Each page is one item for a screen reader: "Page 12 of 340", then its text in reading order.
          Positioned.fill(
            child: Semantics(
              container: true,
              label: _textless.contains(page.pageNumber)
                  ? 'Page ${page.pageNumber} of $_pageCount. Picture, no text.'
                  : 'Page ${page.pageNumber} of $_pageCount',
              value: _plain[page.pageNumber],
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: viewer),
        if (!_barsShown)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 0,
            right: 0,
            child: Center(child: _pill(k, '$_page of $_pageCount', key: const ValueKey('pdf-pill'))),
          ),
        if (_fitLabel != null)
          Positioned(left: 0, right: 0, bottom: 16, child: Center(child: _pill(k, _fitLabel!, key: const ValueKey('pdf-fit-label')))),
        if (_showZoomLimited || widget.debugZoomLimited)
          Positioned(left: 0, right: 0, bottom: _fitLabel != null ? 56 : 16, child: Center(child: _pill(k, 'Zoom limited on this device.', key: const ValueKey('pdf-zoom-limited')))),
      ],
    );
  }

  Widget _pill(CacheTokens k, String text, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: k.surface.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(16)),
      child: Text(text, style: TextStyle(fontSize: 14, color: k.text)),
    );
  }

  /// The zoom the reader opens at: a page wider than tall fitted whole, any other at fit width (narrower on a desktop window).
  double? _initialZoom(PdfDocument doc, PdfViewerController c, double fitZoom, double coverZoom) {
    final rects = c.layout.pageLayouts;
    if (rects.isEmpty) return null;
    final r = rects[(_page - 1).clamp(0, rects.length - 1)];
    if (r.width > r.height) {
      _fit = _Fit.page;
      return fitZoom;
    }
    _fit = _Fit.width;
    final w = MediaQuery.sizeOf(context).width >= kPdfDesktopWidth ? math.min(c.viewSize.width, kPdfMaxFitWidth) : c.viewSize.width;
    return (w - c.params.margin * 2) / r.width;
  }

  // ---- Go to page

  Future<void> _goToSheet() async {
    if (_pageCount < 1) return;
    final n = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => PdfGoToPageSheet(page: _page, pageCount: _pageCount),
    );
    if (n != null && mounted) _goToPage(n, animate: false);
  }
}

/// A web link in a PDF: "Open this link in your browser? It needs a connection." Open or Cancel.
Future<bool?> askToOpenPdfLink(BuildContext context) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('Open this link in your browser? It needs a connection.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Open')),
        ],
      ),
    );

/// The "Go to page" sheet: a number field (number keypad), "of 340", a slider, and Go. A number outside the PDF shows
/// "Pages 1 to 340" in red and Go is off.
class PdfGoToPageSheet extends StatefulWidget {
  const PdfGoToPageSheet({super.key, required this.page, required this.pageCount, this.initialText});

  final int page;
  final int pageCount;

  /// Renders and tests: what the field starts with.
  final String? initialText;

  @override
  State<PdfGoToPageSheet> createState() => _PdfGoToPageSheetState();
}

class _PdfGoToPageSheetState extends State<PdfGoToPageSheet> {
  late final TextEditingController _field = TextEditingController(text: widget.initialText ?? '${widget.page}');

  int? get _value {
    final n = int.tryParse(_field.text.trim());
    return n != null && n >= 1 && n <= widget.pageCount ? n : null;
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final v = _value;
    final bad = v == null && _field.text.isNotEmpty;
    final slider = (v ?? widget.page).toDouble();
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Go to page', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                child: TextField(
                  key: const ValueKey('pdf-goto-field'),
                  controller: _field,
                  autofocus: widget.initialText == null,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    enabledBorder: bad ? OutlineInputBorder(borderSide: BorderSide(color: k.emergency, width: 2)) : null,
                    focusedBorder: bad ? OutlineInputBorder(borderSide: BorderSide(color: k.emergency, width: 2)) : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (_value != null) Navigator.of(context).pop(_value);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text('of ${widget.pageCount}', style: TextStyle(fontSize: 17, color: k.text)),
              ),
            ],
          ),
          if (bad)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Pages 1 to ${widget.pageCount}', key: const ValueKey('pdf-goto-range'), style: TextStyle(fontSize: 14, color: k.emergency)),
            ),
          if (widget.pageCount > 1)
            Slider(
              key: const ValueKey('pdf-goto-slider'),
              min: 1,
              max: widget.pageCount.toDouble(),
              value: slider.clamp(1, widget.pageCount.toDouble()),
              label: '${slider.round()}',
              onChanged: (x) => setState(() => _field.text = '${x.round()}'),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('pdf-goto-go'),
              onPressed: v == null ? null : () => Navigator.of(context).pop(v),
              child: const Text('Go'),
            ),
          ),
        ],
      ),
    );
  }
}
