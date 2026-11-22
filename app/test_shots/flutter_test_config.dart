import 'dart:async';

import 'package:cache/update/update_ui.dart' show whatsNewAfterUpdate;

/// Runs before every test file in test_shots/: the once-after-update "What's new" sheet stays shut (it would open over Home
/// whenever the version has lines), as in test/flutter_test_config.dart.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  whatsNewAfterUpdate = false;
  await testMain();
}
