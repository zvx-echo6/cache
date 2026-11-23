import 'package:flutter/widgets.dart';

import '../platform.dart' as plat;
// The camera code is left out of the web build (a browser does not scan; link_scan_zxing_web.dart is the empty stand-in).
import 'link_scan_zxing.dart' if (dart.library.js_interop) 'link_scan_zxing_web.dart';
import 'link_url.dart';

/// Why the camera could not be used.
enum ScanProblem {
  /// The person refused the camera (or it is turned off for Cache in the phone's settings).
  denied,

  /// No camera, or it could not be opened.
  unavailable,
}

/// The camera that reads a QR code: a widget that shows it and reports what it reads. The scan screen owns everything around it
/// (the guide, the instruction, Cancel, what is said about a wrong code), so a test can stand in a fake with no camera.
abstract class LinkScanner {
  /// The live camera view, full size. [onText] gets the text of each QR code read (the same code may arrive again and again while
  /// it stays in view). [onProblem] is called when the camera cannot be used. The camera permission is asked when this is built,
  /// which is when the scan screen opens and not before. The view carries its own torch control when the phone has one.
  Widget view({required void Function(String text) onText, required void Function(ScanProblem problem) onProblem});

  /// Opens the system settings page of Cache (where the camera can be switched on again).
  Future<void> openSettings();
}

/// The scanner for this platform, or null where Cache does not scan (Linux, Windows, macOS and the web: type or paste the code).
LinkScanner? linkScannerFor({required bool android, required bool ios}) => (android || ios) ? ZxingLinkScanner() : null;

/// [linkScannerFor] for the platform this runs on.
LinkScanner? defaultLinkScanner() => linkScannerFor(android: plat.isAndroid, ios: plat.isIOS);

final _code = RegExp(r'^CACHE\d*-[A-Z0-9-]+$', caseSensitive: false);

/// The link code in what a QR code said: a `cachelink://link/<code>` link, or a bare code (`CACHE-…` or `CACHE1-…`). Null when
/// it is neither. Whether the code can be linked is left to the same checks a typed code goes through.
String? scannedLinkCode(String text) {
  final String code;
  try {
    code = linkCodeFrom(text);
  } on BadLinkCode {
    return null;
  }
  return _code.hasMatch(code) ? code : null;
}
