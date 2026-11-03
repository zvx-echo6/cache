import 'dart:async';

import 'package:cache/screens/download_confirm.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/update/update_ui.dart' show whatsNewAfterUpdate;

/// Runs before every test file in test/: the download pop-up reads a fixed storage (200 GB free, 20 GB kept), not the free space
/// of the machine running the tests, so whether it says "Download ...?" or "Not enough space" never depends on that machine. A
/// test that wants another storage passes its own to confirmDownload or sets downloadSpaceOf. The "What's new" sheet after an
/// update stays shut.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  downloadSpaceOf = (_) => const Space(free: 200 << 30, reserve: 20 << 30);
  // The once-after-update "What's new" sheet stays shut (it would open over Home whenever the version has lines).
  whatsNewAfterUpdate = false;
  await testMain();
}
