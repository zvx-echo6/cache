// Temporary CI diagnostic (removed before merge): what the download pop-up reads as the storage of a test's temp folder.
import 'dart:io';

import 'package:cache/settings/space.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('space of the temp folder', () {
    final d = Directory.systemTemp.createTempSync('probe');
    final s = Space.of(d.path);
    // ignore: avoid_print
    print('PROBE free=${s.free} reserve=${s.reserve} usable=${s.usable} short3GB=${s.shortBy(3 << 30)} short3.6GB=${s.shortBy((3 << 30) + 605 * 1000 * 1000)}');
    d.deleteSync();
  });
}
