import 'package:web/web.dart' as web;

/// Loads the app's address again: the server answers with its sign-in page while the session is gone.
void reloadToSignIn() => web.window.location.assign('/');
