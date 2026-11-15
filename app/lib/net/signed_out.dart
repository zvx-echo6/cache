import 'package:flutter/material.dart';

import '../guide/place_link.dart';
import 'sign_in_reload_stub.dart' if (dart.library.js_interop) 'sign_in_reload_web.dart' as reload;

/// The server answered that this tab is not signed in any more (401): the browser's session ended. Every place that reads from
/// the server reports it here, and [SignedOutBanner] then shows one link back to the sign-in page, whatever the page said.
final ValueNotifier<bool> signedOut = ValueNotifier<bool>(false);

/// A server call answered 401.
void reportSignedOut() => signedOut.value = true;

/// Goes to the server's sign-in page: the browser loads the app's address again, and the server answers with its sign-in page
/// while the session is gone. Nothing on a phone. Replaced in tests.
void Function() signInAgain = reload.reloadToSignIn;

/// A line at the top of every screen while the tab is signed out: "Sign in again.", which goes there (everything that points
/// to something links to it).
class SignedOutBanner extends StatelessWidget {
  const SignedOutBanner({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: signedOut,
        builder: (context, out, _) {
          if (!out) return const SizedBox.shrink();
          final scheme = Theme.of(context).colorScheme;
          return Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LinkText('Sign in again.', key: const ValueKey('signed-out-banner'), onTap: () => signInAgain(), style: const TextStyle(fontSize: 14), color: scheme.onErrorContainer),
                ),
              ),
            ),
          );
        },
      );
}
