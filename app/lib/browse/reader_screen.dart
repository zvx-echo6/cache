import 'dart:async';
import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../layout/adaptive.dart' show ReadingWidth, paneClose, paneShowButton;
import '../platform.dart' as plat;
import '../layout/layout_state.dart';
import '../layout/modules_screen.dart' show addToHome;
import '../pdf/open_pdf.dart';
import '../pdf/pdf_address.dart';
import '../pdf/pdf_reader_screen.dart';
import '../pdf/pdf_source.dart';
import '../screens/search_model_line.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import 'epub_address.dart';
import 'zim_urls.dart';
import 'reader_resources.dart';
import 'web/reader_frame.dart';
import 'web/zim_token.dart';

/// What the system back does in the reader, in order: close the search, close find in page, go a page back while there is
/// history, then leave the reader.
enum ReaderBack { closeSearch, closeFind, pageBack, exit }

/// A page that sends the reader on at once instead of showing something: a meta refresh, or a short page whose script only sets
/// the location (a ZIM's landing page, such as a video channel's). Read from the HTML (a machine format).
bool isLandingPage(String html) {
  if (RegExp(r'<meta[^>]+http-equiv\s*=\s*["' "'" r']?refresh', caseSensitive: false).hasMatch(html)) return true;
  if (html.length > 4096) return false;
  final sets = RegExp(r'(location(\.href)?\s*=[^=])|location\.(replace|assign)\s*\(').hasMatch(html);
  if (!sets) return false;
  final text = html
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.length < 200;
}

/// The steps back from [current] in [history] (the pages' addresses) to the nearest page that is not in [landing], or null when
/// every earlier page is a landing page: Back from the first real page leaves the reader.
///
/// [firstReal] is the entry the reader settled on after opening (a page that rewrites its address as it starts, such as a video
/// channel's app, adds entries before it): nothing before it is a step either.
int? readerBackSteps(List<String> history, int current, Set<String> landing, {int firstReal = 0}) {
  for (var i = current - 1; i >= firstReal; i--) {
    if (!landing.contains(history[i])) return i - current;
  }
  return null;
}

ReaderBack readerBackStep({required bool searching, required bool finding, required bool hasHistory}) {
  if (searching) return ReaderBack.closeSearch;
  if (finding) return ReaderBack.closeFind;
  if (hasHistory) return ReaderBack.pageBack;
  return ReaderBack.exit;
}

/// Opens a ZIM like a web site: the page is a WebView whose requests are all answered from the ZIM file
/// (no network), with a main page, back and forward, find in the page, title search and full-text search
/// limited to this ZIM.
class ZimReaderScreen extends StatefulWidget {
  const ZimReaderScreen({
    super.key,
    required this.sources,
    required this.zim,
    this.address,
    this.layout,
    this.itemMenu,
    this.debugHasHistory = false,
    this.debugWeb,
    this.zimTokens,
    this.frameBuilder,
    this.quote,
  });

  /// Tests only: behave as in a browser (or not), whatever the platform is.
  final bool? debugWeb;

  /// A browser only: where the token for the page addresses comes from (the app's own when null).
  final ZimTokens? zimTokens;

  /// A browser only: builds the frame that shows the page (the real one when null). Tests give their own.
  final ZimFrameBuilder? frameBuilder;

  /// Tests and renders only: start as if the page had history (there is no web view in a test).
  final bool debugHasHistory;

  /// The Library's menu for this item (Check for update, Change icon, Add to Home, Delete), behind "..."; given the way to add the page
  /// on screen to Home. Without it "..." offers Add to Home alone.
  final Future<void> Function(BuildContext context, VoidCallback? addPage)? itemMenu;

  /// Where "Add to Home" puts a shortcut to the page being read; the menu item is hidden when null.
  final LayoutState? layout;

  final SourcesState sources;
  final ZimFile zim;

  /// A `zim:<uuid>/<path>` address to open; the ZIM's main page when null. A PDF entry (a path ending in .pdf, or an address
  /// with `#page=N`) opens in the PDF reader, at that page.
  final String? address;

  /// The cited passage (a citation's quote): on that page of a PDF entry, or in the EPUB chapter opened (its first words are
  /// found and marked), highlighted when found.
  final String? quote;

  @override
  State<ZimReaderScreen> createState() => _ZimReaderScreenState();
}

class _ZimReaderScreenState extends State<ZimReaderScreen> {
  bool get _customScheme => defaultTargetPlatform == TargetPlatform.iOS;

  InAppWebViewController? _web;
  late final FindInteractionController _findController =
      FindInteractionController(
        onFindResultReceived: (c, active, total, done) {
          if (mounted) {
            setState(() {
              _matchActive = total == 0 ? 0 : active + 1;
              _matchTotal = total;
            });
          }
        },
      );
  /// Every page is served through here: a landing page (one that sends the reader on at once) is noted, so it is never a step of
  /// the page history (going back to it would send the reader forward again, and Back could never leave).
  late final ZimPageServer _server = ZimPageServer((address) async {
    final z = await widget.sources.zimGet(address);
    if (z.mime.split(';').first.trim() == 'text/html' && isLandingPage(utf8.decode(z.bytes, allowMalformed: true))) {
      _landing.add(_historyKey(address));
    }
    return z;
  });

  /// The addresses of the landing pages served (without their #fragment).
  final Set<String> _landing = {};

  /// Steps back to the nearest real page (null: none, Back leaves the reader).
  int? _backSteps;

  /// The history entry the reader settled on after it opened (the first real page), and whether it has settled: 1.5 s after the
  /// first page finished loading, or at the first touch on the page.
  int _firstReal = 0;
  bool _settled = false;
  Timer? _settle;

  void _settleNow() {
    _settle?.cancel();
    if (_settled) return;
    _settled = true;
    _syncNav();
  }

  static String _historyKey(String address) => address.split('#').first;

  String _keyOfUrl(WebUri? u) {
    final uri = u?.uriValue;
    if (uri == null) return '';
    return _historyKey(addressOfUrl(uri) ?? uri.toString());
  }

  /// A page back, over any landing page (none there: nothing to do).
  Future<void> _pageBack() async {
    if (_isWeb) {
      _frameHistory.requested('back');
      _frame?.back();
      return;
    }
    final steps = _backSteps;
    if (steps == null) return;
    await _web?.goBackOrForward(steps: steps);
  }
  final TextEditingController _query = TextEditingController();
  final TextEditingController _find = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  Timer? _debounce;

  Uri? _start;
  String? _startError;

  // ---- in a browser: the page is a sandboxed frame served by the device (web/reader_frame_web.dart); the app bar, the back and
  // forward buttons, the title search and the main page are this same screen. inappwebview is never touched.
  ZimFrameHandle? _frame;
  final FrameHistory _frameHistory = FrameHistory();
  bool get _isWeb => widget.debugWeb ?? plat.isWeb;
  ZimTokens get _tokens => widget.zimTokens ?? ZimTokens.shared;

  /// The page's renderer died (Android ends it when memory runs low): the WebView is gone and Reload makes a new one.
  bool _pageGone = false;
  int _webGeneration = 0;
  String _pageTitle = '';
  String? _currentAddress;
  late bool _canBack = widget.debugHasHistory;
  bool _canForward = false;
  double _progress = 0;

  bool _searching = false;
  List<Suggestion> _suggestions = const [];
  List<SearchHit>? _hits;
  bool _searchBusy = false;
  String? _searchError;

  bool _finding = false;
  int _matchActive = 0;
  int _matchTotal = 0;

  String? get _zimId => widget.sources.idOf(widget.zim);

  @override
  void initState() {
    super.initState();
    _resolveStart();
  }

  Future<void> _resolveStart() async {
    final id = _zimId;
    if (id == null) {
      setState(() => _startError = 'This ZIM could not be opened.');
      return;
    }
    try {
      var address = widget.address ?? await widget.sources.zimMainPage(id);
      // An EPUB entry opens at its first chapter (a web view would only download it).
      if (isEpubEntryAddress(address)) address = await epubFirstChapter(address, widget.sources.zimGet) ?? address;
      if (_isWeb) {
        final token = await _tokens.get();
        final framed = zimFrameUrl(token, address);
        if (framed == null) throw StateError('Not a ZIM address');
        _currentAddress = address;
        if (mounted) setState(() => _start = Uri.parse(framed));
        return;
      }
      final url = readerUrl(address, customScheme: _customScheme);
      if (url == null) throw StateError('Not a ZIM address');
      if (mounted) setState(() => _start = url);
    } on CacheSearchException catch (e) {
      if (mounted) setState(() => _startError = e.message);
    } on ZimTokenException catch (e) {
      if (mounted) setState(() => _startError = e.message);
    } catch (e) {
      if (mounted) setState(() => _startError = '$e');
    }
  }

  /// The frame settled on a page: its address and title.
  void _onFramePage(String framePath, String title) {
    final address = addressOfFramePath(framePath);
    if (address == null || !mounted) return;
    _frameHistory.reported(address);
    setState(() {
      _currentAddress = address;
      if (title.isNotEmpty) _pageTitle = title;
      _canBack = _frameHistory.canBack;
      _canForward = _frameHistory.canForward;
    });
  }

  /// Opens [address] in the frame (a browser).
  Future<void> _openInFrame(String address) async {
    try {
      final token = await _tokens.get();
      final framed = zimFrameUrl(token, address);
      if (framed != null) _frame?.load(framed);
    } on ZimTokenException catch (e) {
      if (mounted) setState(() => _startError = e.message);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _settle?.cancel();
    _query.dispose();
    _find.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _syncNav() async {
    final c = _web;
    if (c == null) return;
    final f = await c.canGoForward();
    bool b;
    try {
      final h = await c.getCopyBackForwardList();
      final items = h?.list ?? const <WebHistoryItem>[];
      final cur = h?.currentIndex ?? -1;
      if (!_settled && cur >= 0) _firstReal = cur;
      _backSteps = cur < 0 ? null : readerBackSteps([for (final i in items) _keyOfUrl(i.url)], cur, _landing, firstReal: _firstReal);
      b = _backSteps != null;
    } catch (_) {
      b = await c.canGoBack();
      _backSteps = b ? -1 : null;
    }
    if (mounted) {
      setState(() {
        _canBack = b;
        _canForward = f;
      });
    }
  }

  void _pageStopped() {
    _web = null;
    if (mounted) {
      setState(() {
        _pageGone = true;
        _progress = 0;
        _canBack = false;
        _canForward = false;
      });
    }
  }

  /// A new WebView at the page that was on screen.
  void _reload() {
    if (_isWeb) {
      setState(() => _webGeneration++);
      return;
    }
    setState(() {
      _start = reloadUrl(_currentAddress, _start, customScheme: _customScheme);
      _pageGone = false;
      _webGeneration++;
      // A new WebView has a new history: it settles again on the page it opens.
      _settle?.cancel();
      _settle = null;
      _settled = false;
      _firstReal = 0;
    });
  }

  void _open(String address) {
    if (_isWeb) {
      if (!isZimAddress(address)) return;
      setState(() {
        _searching = false;
        _hits = null;
        _query.clear();
      });
      unawaited(_openInFrame(address));
      return;
    }
    if (isPdfAddress(address)) {
      setState(() => _searching = false);
      _openPdfEntry(address);
      return;
    }
    if (isEpubEntryAddress(address)) {
      setState(() => _searching = false);
      unawaited(_openEpub(address));
      return;
    }
    final u = readerUrl(address, customScheme: _customScheme);
    if (u == null) return;
    setState(() {
      _searching = false;
      _hits = null;
      _query.clear();
    });
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(u)));
  }

  void _onQueryChanged(String v) {
    _debounce?.cancel();
    final id = _zimId;
    setState(() {
      _hits = null;
      _searchError = null;
      if (v.trim().isEmpty || id == null) _suggestions = const [];
    });
    if (v.trim().isEmpty || id == null) return;
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      try {
        final s = await widget.sources.suggest(v.trim(), k: 12, zimIds: [id]);
        if (mounted && _query.text.trim() == v.trim()) {
          setState(() => _suggestions = s);
        }
      } catch (_) {
        if (mounted) setState(() => _suggestions = const []);
      }
    });
  }

  Future<void> _fullText() async {
    final q = _query.text.trim();
    final id = _zimId;
    if (q.isEmpty || id == null) return;
    setState(() {
      _searchBusy = true;
      _searchError = null;
      _hits = null;
    });
    try {
      final r = await widget.sources.searchIn(q, zimIds: [id], k: 25);
      if (mounted) setState(() => _hits = r.results);
    } catch (e) {
      if (mounted) {
        setState(
          () => _searchError = e is CacheSearchException && e.code == 'busy'
              ? 'This ZIM is still being indexed. Text search works when that is done.'
              : (e is StateError ? e.message : '$e'),
        );
      }
    } finally {
      if (mounted) setState(() => _searchBusy = false);
    }
  }

  void _toggleFind() {
    setState(() {
      _finding = !_finding;
      _searching = false;
    });
    if (!_finding) {
      _findController.clearMatches();
      _find.clear();
      _matchActive = 0;
      _matchTotal = 0;
    }
  }

  /// A Home shortcut to the page on screen.
  void _addToHome() {
    final address = _currentAddress ?? widget.address;
    final layout = widget.layout;
    if (address == null || layout == null) return;
    final lib = widget.sources.titleOf(widget.zim);
    addToHome(
      context,
      layout,
      Shortcut.page(
        address: address,
        title: _pageTitle.isEmpty ? lib : _pageTitle,
        library: lib,
      ),
    );
  }

  Future<void> _goHome() async {
    final id = _zimId;
    if (id == null) return;
    try {
      _open(await widget.sources.zimMainPage(id));
    } catch (_) {}
  }

  /// The PDF reader, when the address opened is a PDF entry.
  late final PdfZimSource? _pdf = widget.address != null && isPdfAddress(widget.address!) ? zimPdfSource(widget.sources, widget.address!) : null;

  /// A link on a page to a PDF entry of the ZIM: the PDF reader over the whole window (the page stays underneath).
  /// An EPUB entry: its first chapter in this reader.
  Future<void> _openEpub(String address) async {
    final chapter = await epubFirstChapter(address, widget.sources.zimGet);
    if (!mounted) return;
    if (chapter == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('This book could not be opened.')));
      return;
    }
    final u = readerUrl(chapter, customScheme: _customScheme);
    if (u != null) await _web?.loadUrl(urlRequest: URLRequest(url: WebUri.uri(u)));
  }

  /// The quote's first words marked once, on the first page loaded (an EPUB citation).
  bool _quoteMarked = false;

  void _markQuote() {
    final q = widget.quote;
    if (_quoteMarked || q == null || q.trim().isEmpty || widget.address == null || !isEpubInnerAddress(widget.address!)) return;
    _quoteMarked = true;
    final probe = quoteProbe(q);
    if (probe.isEmpty) return;
    setState(() {
      _finding = true;
      _find.text = probe;
    });
    _findController.findAll(find: probe);
  }

  void _openPdfEntry(String address) {
    if (!mounted) return;
    openZimPdf(context, widget.sources, address);
  }

  Widget _withShow(Widget? show, Widget arrow) => show == null ? arrow : Row(mainAxisSize: MainAxisSize.min, children: [arrow, show]);

  @override
  Widget build(BuildContext context) {
    final pdf = _pdf;
    if (pdf != null) return PdfReaderScreen(source: pdf, initialPage: pdfPageOfAddress(widget.address!), quote: widget.quote);
    final k = context.t;
    final title = widget.sources.titleOf(widget.zim);
    final nav = Navigator.of(context);
    // In a browser the reader is the pane's own page on a desktop window: the same arrow closes it and shows the list again.
    final VoidCallback? close = nav.canPop() ? nav.pop : (_isWeb ? paneClose(context) : null);
    final show = nav.canPop() ? null : paneShowButton(context);
    // The system back (Android): closes search or find, then a page back while there is history, then leaves the reader
    // (readerBackStep). The top-left arrow always leaves; the bottom bar's arrows are the page history.
    return PopScope(
      canPop: readerBackStep(searching: _searching, finding: _finding, hasHistory: _canBack) == ReaderBack.exit,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        switch (readerBackStep(searching: _searching, finding: _finding, hasHistory: _canBack)) {
          case ReaderBack.closeSearch:
            setState(() => _searching = false);
          case ReaderBack.closeFind:
            _toggleFind();
          case ReaderBack.pageBack:
            await _pageBack();
          case ReaderBack.exit:
            break;
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          // Leaves the reader for where it was opened from (Library, a citation, a search result), whatever the page history.
          // Beside a list on a tablet the reader is the pane's own page: there is nothing to leave to.
          // A screen reader says "Close <library>", and can press it (the label's node carries the tap).
          leadingWidth: close != null && show != null ? 104 : null,
          leading: close != null
              ? _withShow(show, Semantics(
                  label: 'Close $title',
                  button: true,
                  onTap: close,
                  excludeSemantics: true,
                  child: IconButton(
                    key: const ValueKey('reader-close'),
                    tooltip: 'Close $title',
                    icon: const BackButtonIcon(),
                    onPressed: close,
                  ),
                ))
              : paneShowButton(context),
          title: _searching
              ? TextField(
                  controller: _query,
                  focusNode: _queryFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search $title',
                    border: InputBorder.none,
                  ),
                  style: TextStyle(fontSize: 18, color: k.text),
                  onChanged: _onQueryChanged,
                  onSubmitted: (_) => _fullText(),
                )
              : Text(
                  _pageTitle.isEmpty ? title : _pageTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18),
                ),
          actions: [
            if (_searching)
              IconButton(
                tooltip: 'Close search',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _searching = false),
              )
            else ...[
              IconButton(
                tooltip: 'Search this ZIM',
                icon: const Icon(Icons.search),
                onPressed: () => setState(() {
                  _searching = true;
                  _finding = false;
                }),
              ),
              // The browser's own find (Ctrl+F) reaches into the frame; the page has no origin, so the app cannot search it.
              if (!_isWeb)
                IconButton(
                  tooltip: 'Find in page',
                  icon: Icon(
                    _finding ? Icons.find_in_page : Icons.find_in_page_outlined,
                  ),
                  onPressed: _toggleFind,
                ),
              if (widget.itemMenu != null)
                IconButton(
                  key: const ValueKey('item-menu'),
                  tooltip: 'More',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => widget.itemMenu!(context, widget.layout == null ? null : _addToHome),
                )
              else if (widget.layout != null)
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) {
                    if (v == 'home') _addToHome();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'home',
                      height: 52,
                      child: Text('Add to Home'),
                    ),
                  ],
                ),
            ],
          ],
          bottom: _progress > 0 && _progress < 1
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 2,
                  ),
                )
              : null,
        ),
        body: Column(
          children: [
            if (_finding) _findBar(k),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(offstage: _searching, child: _page(k)),
                  if (_searching) Positioned.fill(child: _searchPanel(k)),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: BottomAppBar(
          height: 56,
          padding: EdgeInsets.zero,
          color: k.surface,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                key: const ValueKey('reader-page-back'),
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _canBack ? _pageBack : null,
              ),
              IconButton(
                key: const ValueKey('reader-page-forward'),
                tooltip: 'Forward',
                icon: const Icon(Icons.arrow_forward),
                onPressed: _canForward
                    ? () {
                        if (_isWeb) {
                          _frameHistory.requested('forward');
                          _frame?.forward();
                        } else {
                          _web?.goForward();
                        }
                      }
                    : null,
              ),
              IconButton(
                tooltip: 'Main page',
                icon: const Icon(Icons.home_outlined),
                onPressed: _goHome,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(CacheTokens k) {
    if (_startError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _startError!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, color: k.emergency),
          ),
        ),
      );
    }
    if (_pageGone) return ReaderPageGone(onReload: _reload);
    final start = _start;
    if (start == null) return const Center(child: CircularProgressIndicator());
    if (_isWeb) {
      // The ZIM's own page in a frame: the whole width it is given (no reading-width cap), as the owner decided.
      return (widget.frameBuilder ?? buildZimFrame)(
        key: ValueKey('reader-frame-$_webGeneration'),
        initialUrl: start.toString(),
        onCreated: (h) => _frame = h,
        onPage: _onFramePage,
        onExternal: openInNewTab,
      );
    }
    // A desktop window keeps the article to a reading width (in the page's 16 px text).
    return ReadingWidth(
      style: const TextStyle(fontSize: 16),
      child: Listener(
      // A touch on the page: it has settled (anything it adds to the history from now on is the person's own).
      onPointerDown: (_) => _settleNow(),
      child: InAppWebView(
      key: ValueKey('reader-web-$_webGeneration'),
      initialUrlRequest: URLRequest(url: WebUri.uri(start)),
      initialSettings: readerSettings(customScheme: _customScheme),
      findInteractionController: _findController,
      onWebViewCreated: (c) => _web = c,
      onLoadResourceWithCustomScheme: (controller, request) =>
          serveCustomZimResource(_server, request.url.uriValue),
      shouldInterceptRequest: (controller, request) async {
        var r = await _server.serve(request.url.uriValue);
        // A PDF entry the page opened (a link whose path does not end in .pdf): the PDF reader shows it; the page stays.
        if (r.status == 200 && request.isForMainFrame == true && r.mime.split(';').first.trim() == 'application/pdf') {
          final a = addressOfUrl(request.url.uriValue);
          if (a != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openPdfEntry(a));
          return WebResourceResponse(contentType: 'text/plain', statusCode: 204, reasonPhrase: 'No Content', data: Uint8List(0));
        }
        // An EPUB entry the page opened: its first chapter instead (a web view would download it).
        if (r.status == 200 && request.isForMainFrame == true && r.mime.split(';').first.trim() == 'application/epub+zip') {
          final a = addressOfUrl(request.url.uriValue);
          if (a != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openEpub(a));
          return WebResourceResponse(contentType: 'text/plain', statusCode: 204, reasonPhrase: 'No Content', data: Uint8List(0));
        }
        if (r.status == 200 && r.mime.split(';').first.trim() == 'text/html') {
          r = ServedEntry(200, r.mime, utf8.encode(withoutPicturePlaceholders(utf8.decode(r.bytes, allowMalformed: true))));
        }
        final text =
            r.mime.startsWith('text/') ||
            r.mime.contains('xml') ||
            r.mime.contains('json') ||
            r.mime.contains('javascript');
        return WebResourceResponse(
          contentType: r.mime.split(';').first,
          contentEncoding: text ? 'utf-8' : null,
          statusCode: r.status,
          reasonPhrase: r.status == 200
              ? 'OK'
              : (r.status == 404 ? 'Not Found' : 'Error'),
          headers: const {'Access-Control-Allow-Origin': '*'},
          data: r.bytes is Uint8List
              ? r.bytes as Uint8List
              : Uint8List.fromList(r.bytes),
        );
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final u = action.request.url?.uriValue;
        if (u != null && isReaderUrl(u, customScheme: _customScheme)) {
          // A link to a PDF entry opens the PDF reader (a web view cannot show a PDF); `#page=N` opens it at that page.
          final a = addressOfUrl(u);
          if (a != null && isPdfAddress(a)) {
            _openPdfEntry(u.hasFragment ? '$a#${u.fragment}' : a);
            return NavigationActionPolicy.CANCEL;
          }
          // A link to an EPUB entry opens its first chapter here.
          if (a != null && isEpubEntryAddress(a)) {
            unawaited(_openEpub(a));
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        }
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text(
                  'That link is on the web. It is not available offline.',
                ),
              ),
            );
        }
        return NavigationActionPolicy.CANCEL;
      },
      onProgressChanged: (c, p) {
        if (mounted) setState(() => _progress = p / 100);
      },
      onTitleChanged: (c, t) {
        if (mounted && t != null && !t.contains(zimHost)) {
          setState(() => _pageTitle = t);
        }
      },
      onRenderProcessGone: (c, detail) => _pageStopped(),
      onLoadStop: (c, u) {
        _syncNav();
        _markQuote();
        _settle ??= Timer(const Duration(milliseconds: 1500), _settleNow);
      },
      onUpdateVisitedHistory: (c, u, r) {
        final uri = u?.uriValue;
        if (uri != null) _currentAddress = addressOfUrl(uri) ?? _currentAddress;
        _syncNav();
      },
    ),
    ),
    );
  }

  Widget _findBar(CacheTokens k) {
    return Material(
      color: k.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _find,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Find in page',
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  if (v.isEmpty) {
                    _findController.clearMatches();
                    setState(() {
                      _matchActive = 0;
                      _matchTotal = 0;
                    });
                  } else {
                    _findController.findAll(find: v);
                  }
                },
                onSubmitted: (_) => _findController.findNext(forward: true),
              ),
            ),
            Text(
              _find.text.isEmpty ? '' : '$_matchActive / $_matchTotal',
              style: TextStyle(color: k.secondary),
            ),
            IconButton(
              tooltip: 'Previous',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: () => _findController.findNext(forward: false),
            ),
            IconButton(
              tooltip: 'Next',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => _findController.findNext(forward: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchPanel(CacheTokens k) {
    final q = _query.text.trim();
    return Material(
      color: k.background,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (q.isNotEmpty)
            ListTile(
              leading: Icon(Icons.manage_search, color: k.accent),
              title: Text(
                'Search the text for “$q”',
                style: TextStyle(color: k.text),
              ),
              onTap: _fullText,
            ),
          if (_searchBusy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _searchError!,
                style: TextStyle(fontSize: 15, color: k.warning),
              ),
            ),
          if (_hits != null) ...[
            if (_hits!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Nothing found.',
                  style: TextStyle(fontSize: 16, color: k.secondary),
                ),
              ),
            for (final h in _hits!)
              ListTile(
                title: Text(
                  h.title,
                  style: TextStyle(fontWeight: FontWeight.w600, color: k.text),
                ),
                subtitle: h.snippet.isEmpty
                    ? null
                    : Text(
                        h.snippet,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: k.secondary),
                      ),
                onTap: () => _open(h.address),
              ),
            // A library with vectors was searched by keywords only: its model is not on this phone.
            if (widget.sources.missingModel(ids: [?_zimId]) case final missing?)
              SearchModelLine(model: missing),
          ] else
            for (final s in _suggestions)
              ListTile(
                leading: Icon(Icons.article_outlined, color: k.secondary),
                title: Text(s.title, style: TextStyle(color: k.text)),
                onTap: () => _open(s.address),
              ),
        ],
      ),
    );
  }
}

/// Where Reload opens a new page: the page that was on screen, else where the reader started.
Uri? reloadUrl(String? currentAddress, Uri? start, {required bool customScheme}) =>
    (currentAddress == null ? null : readerUrl(currentAddress, customScheme: customScheme)) ?? start;

/// Shown in place of the page when its renderer has stopped.
class ReaderPageGone extends StatelessWidget {
  const ReaderPageGone({super.key, required this.onReload});

  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This page stopped. The device may be low on memory.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, color: k.text),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('reader-reload'),
              onPressed: onReload,
              child: const Text('Reload'),
            ),
          ],
        ),
      ),
    );
  }
}
