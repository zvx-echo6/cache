import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'reader_frame_base.dart';

int _frames = 0;

/// The browser's frame for a ZIM page. The page is other people's content, so the frame is sandboxed with scripts and pop-ups
/// only: no `allow-same-origin`, which leaves the page with no origin of its own and no way to use this app's session. The server
/// sends the same sandbox in a header, so a page opened outside this frame gets it as well.
///
/// The server adds a small script to every HTML page; it tells this frame where the page is and what it is called (`cacheZim`
/// messages), takes "back" and "forward", and hands over a click on a link that leaves the ZIM.
Widget buildZimFrame({
  Key? key,
  required String initialUrl,
  required void Function(ZimFrameHandle) onCreated,
  required void Function(String path, String title) onPage,
  required void Function(String url) onExternal,
}) =>
    _ZimFrameView(key: key, initialUrl: initialUrl, onCreated: onCreated, onPage: onPage, onExternal: onExternal);

/// Opens [url] in a new tab, with no link back to this app. Only web addresses and mail links.
void openInNewTab(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !(u.scheme == 'https' || u.scheme == 'http' || u.scheme == 'mailto')) return;
  web.window.open(url, '_blank', 'noopener,noreferrer');
}

class _Handle implements ZimFrameHandle {
  _Handle(this.frame);

  final web.HTMLIFrameElement frame;

  void _tell(String kind) => frame.contentWindow?.postMessage({'cacheZim': kind}.jsify(), '*'.toJS);

  @override
  void load(String url) => frame.src = url;

  @override
  void back() => _tell('back');

  @override
  void forward() => _tell('forward');
}

class _ZimFrameView extends StatefulWidget {
  const _ZimFrameView({super.key, required this.initialUrl, required this.onCreated, required this.onPage, required this.onExternal});

  final String initialUrl;
  final void Function(ZimFrameHandle) onCreated;
  final void Function(String path, String title) onPage;
  final void Function(String url) onExternal;

  @override
  State<_ZimFrameView> createState() => _ZimFrameViewState();
}

class _ZimFrameViewState extends State<_ZimFrameView> {
  late final String _type = 'cache-zim-frame-${_frames++}';
  late final web.HTMLIFrameElement _frame;
  late final JSFunction _listener;

  @override
  void initState() {
    super.initState();
    _frame = (web.document.createElement('iframe') as web.HTMLIFrameElement)
      ..setAttribute('sandbox', 'allow-scripts allow-popups')
      ..setAttribute('referrerpolicy', 'no-referrer')
      ..src = widget.initialUrl;
    _frame.style
      ..border = '0'
      ..width = '100%'
      ..height = '100%'
      ..background = 'white';
    ui_web.platformViewRegistry.registerViewFactory(_type, (int _) => _frame);
    _listener = ((web.MessageEvent e) {
      // Only what this frame says; its page has no origin, so the source is the one thing that can be checked.
      if (!identical(e.source, _frame.contentWindow)) return;
      final d = e.data.dartify();
      if (d is! Map) return;
      switch (d['cacheZim']) {
        case 'page':
          widget.onPage((d['href'] ?? '').toString(), (d['title'] ?? '').toString());
        case 'external':
          widget.onExternal((d['url'] ?? '').toString());
      }
    }).toJS;
    web.window.addEventListener('message', _listener);
    widget.onCreated(_Handle(_frame));
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _type);
}
