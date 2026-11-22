import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../browse/web/reader_frame.dart' show openInNewTab;
import '../../platform.dart' as plat;
import '../../theme.dart';

/// How a sign-in with a site's external auth plugin ended (PeerTube's documented flow: the plugin's auth page ends on the
/// site's `/login` page with `externalAuthToken` and `username`, or with `externalAuthError=true`).
sealed class ExternalSignIn {
  const ExternalSignIn();
}

/// The one-time token (valid 5 minutes, used once) and the user name to trade for the tokens.
class ExternalSignInDone extends ExternalSignIn {
  const ExternalSignInDone(this.username, this.token);

  final String username;
  final String token;
}

/// The site could not sign the person in with that method.
class ExternalSignInFailed extends ExternalSignIn {
  const ExternalSignInFailed();
}

/// What [url] says when it is the site's `/login` page ([returnPrefix]) at the end of an external sign-in; null for any
/// other page (the sign-in goes on).
ExternalSignIn? externalSignInResult(Uri url, String returnPrefix) {
  if (returnPrefix.isEmpty) return null;
  final prefix = Uri.parse(returnPrefix);
  if (url.host.toLowerCase() != prefix.host.toLowerCase() || url.port != prefix.port || url.path != prefix.path) return null;
  final q = url.queryParameters;
  final token = q['externalAuthToken'];
  final user = q['username'];
  if (token != null && token.isNotEmpty && user != null && user.isNotEmpty) return ExternalSignInDone(user, token);
  if (q['externalAuthError'] != null) return const ExternalSignInFailed();
  return null;
}

/// Test hook: answers in place of the in-app browser.
Future<ExternalSignIn?> Function(VideoExternalAuth auth)? externalSignInForTests;

/// Opens the method's auth page in an in-app browser (the web view the reader uses) and waits for the site's /login page:
/// the result, or null when the person closed it.
Future<ExternalSignIn?> openExternalSignIn(BuildContext context, VideoExternalAuth auth, String returnPrefix) =>
    externalSignInForTests?.call(auth) ??
    (plat.isWeb
        ? showDialog<ExternalSignIn>(context: context, builder: (_) => ExternalSignInPasteDialog(auth: auth, returnPrefix: returnPrefix, open: openInNewTab))
        : Navigator.of(context).push<ExternalSignIn>(
            MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ExternalSignInPage(auth: auth, returnPrefix: returnPrefix)),
          ));

/// A browser cannot read the address a page in another tab ends on, so the sign-in opens in a new tab and the person pastes back
/// the address of the site's /login page it ends on (the same address the phone's in-app browser watches for): [externalSignInResult]
/// reads it. Pops with the [ExternalSignIn], or null on Cancel.
class ExternalSignInPasteDialog extends StatefulWidget {
  const ExternalSignInPasteDialog({super.key, required this.auth, required this.returnPrefix, required this.open});

  final VideoExternalAuth auth;
  final String returnPrefix;

  /// Opens an address in a new tab.
  final void Function(String url) open;

  @override
  State<ExternalSignInPasteDialog> createState() => _ExternalSignInPasteDialogState();
}

class _ExternalSignInPasteDialogState extends State<ExternalSignInPasteDialog> {
  final TextEditingController _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _finish() {
    final u = Uri.tryParse(_text.text.trim());
    final r = u == null ? null : externalSignInResult(u, widget.returnPrefix);
    if (r == null) {
      setState(() => _problem = "That is not the address the site ends on. After you sign in, copy the whole address of the page you land on.");
      return;
    }
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sign in with ${widget.auth.displayName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Open the sign-in page and sign in there.\n2. When you land on the site\'s login page, copy its address from the address bar.\n3. Paste it here.'),
            const SizedBox(height: 8),
            OutlinedButton(key: const ValueKey('external-open'), onPressed: () => widget.open(widget.auth.url), child: const Text('Open the sign-in page')),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('external-paste'),
              controller: _text,
              decoration: InputDecoration(labelText: 'Address you landed on', errorText: _problem, errorMaxLines: 3),
              onSubmitted: (_) => _finish(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('external-done'), onPressed: _finish, child: const Text('Sign in')),
      ],
    );
  }
}

class _ExternalSignInPage extends StatefulWidget {
  const _ExternalSignInPage({required this.auth, required this.returnPrefix});

  final VideoExternalAuth auth;
  final String returnPrefix;

  @override
  State<_ExternalSignInPage> createState() => _ExternalSignInPageState();
}

class _ExternalSignInPageState extends State<_ExternalSignInPage> {
  double _progress = 0;
  bool _done = false;

  /// The site's /login page: the sign-in has ended; this page closes with how.
  bool _check(Uri? url) {
    if (url == null || _done) return _done;
    final r = externalSignInResult(url, widget.returnPrefix);
    if (r == null) return false;
    _done = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(r);
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: Text('Sign in with ${widget.auth.displayName}', maxLines: 1, overflow: TextOverflow.ellipsis),
        bottom: _progress < 1
            ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 2, color: k.accent))
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.auth.url)),
        initialSettings: InAppWebViewSettings(useShouldOverrideUrlLoading: true, incognito: true),
        shouldOverrideUrlLoading: (controller, action) async =>
            _check(action.request.url?.uriValue) ? NavigationActionPolicy.CANCEL : NavigationActionPolicy.ALLOW,
        onLoadStart: (controller, url) => _check(url?.uriValue),
        onProgressChanged: (controller, p) {
          if (mounted) setState(() => _progress = p / 100);
        },
      ),
    );
  }
}
