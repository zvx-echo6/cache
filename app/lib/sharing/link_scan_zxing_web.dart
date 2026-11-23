import 'package:flutter/widgets.dart';

import 'link_scan.dart';

/// The web build has no camera scanning (the button is hidden there), so this stands in for link_scan_zxing.dart and pulls
/// none of its code in.
class ZxingLinkScanner implements LinkScanner {
  @override
  Widget view({required void Function(String text) onText, required void Function(ScanProblem problem) onProblem}) =>
      throw UnsupportedError('The web build does not scan');

  @override
  Future<void> openSettings() async {}
}
