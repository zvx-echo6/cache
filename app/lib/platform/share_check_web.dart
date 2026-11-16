import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// A browser: navigator.share, which most Linux desktop browsers lack.
bool systemShareAvailable() => (web.window.navigator as JSObject).has('share');
