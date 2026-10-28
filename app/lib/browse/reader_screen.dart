import 'dart:async';

import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../layout/layout_state.dart';
import '../layout/modules_screen.dart' show addToHome;
import '../screens/search_model_line.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import 'zim_urls.dart';
import 'reader_resources.dart';

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
  });

  /// Where "Add to Home" puts a shortcut to the page being read; the menu item is hidden when null.
  final LayoutState? layout;

  final SourcesState sources;
  final ZimFile zim;

  /// A `zim:<uuid>/<path>` address to open; the ZIM's main page when null.
  final String? address;

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
  late final ZimPageServer _server = ZimPageServer(widget.sources.zimGet);
  final TextEditingController _query = TextEditingController();
  final TextEditingController _find = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  Timer? _debounce;

  Uri? _start;
  String? _startError;
  String _pageTitle = '';
  String? _currentAddress;
  bool _canBack = false;
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
      final address = widget.address ?? await widget.sources.zimMainPage(id);
      final url = readerUrl(address, customScheme: _customScheme);
      if (url == null) throw StateError('Not a ZIM address');
      if (mounted) setState(() => _start = url);
    } on CacheSearchException catch (e) {
      if (mounted) setState(() => _startError = e.message);
    } catch (e) {
      if (mounted) setState(() => _startError = '$e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _find.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _syncNav() async {
    final c = _web;
    if (c == null) return;
    final b = await c.canGoBack();
    final f = await c.canGoForward();
    if (mounted) {
      setState(() {
        _canBack = b;
        _canForward = f;
      });
    }
  }

  void _open(String address) {
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

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final title = widget.sources.titleOf(widget.zim);
    return PopScope(
      canPop: !_canBack && !_searching && !_finding,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_searching) {
          setState(() => _searching = false);
        } else if (_finding) {
          _toggleFind();
        } else if (_canBack) {
          await _web?.goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
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
              IconButton(
                tooltip: 'Find in page',
                icon: Icon(
                  _finding ? Icons.find_in_page : Icons.find_in_page_outlined,
                ),
                onPressed: _toggleFind,
              ),
              if (widget.layout != null)
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
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _canBack ? () => _web?.goBack() : null,
              ),
              IconButton(
                tooltip: 'Forward',
                icon: const Icon(Icons.arrow_forward),
                onPressed: _canForward ? () => _web?.goForward() : null,
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
    final start = _start;
    if (start == null) return const Center(child: CircularProgressIndicator());
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri.uri(start)),
      initialSettings: readerSettings(customScheme: _customScheme),
      findInteractionController: _findController,
      onWebViewCreated: (c) => _web = c,
      onLoadResourceWithCustomScheme: (controller, request) =>
          serveCustomZimResource(_server, request.url.uriValue),
      shouldInterceptRequest: (controller, request) async {
        final r = await _server.serve(request.url.uriValue);
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
      onLoadStop: (c, u) => _syncNav(),
      onUpdateVisitedHistory: (c, u, r) {
        final uri = u?.uriValue;
        if (uri != null) _currentAddress = addressOfUrl(uri) ?? _currentAddress;
        _syncNav();
      },
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
            if (_zimId != null && widget.sources.missingModel(ids: [_zimId!]) case final missing?)
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
