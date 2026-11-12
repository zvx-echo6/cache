// A device on the LEGACY build (tag v1.0.30): wired the way main.dart wires it. Run: flutter test --timeout none test/proof/device_chain.dart
// Environment: PROOF_DIR (this device's folder; its app data is PROOF_DIR/data), PROOF_PORT (its fixed sync port), PROOF_NAME.
import 'dart:io';

import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/sync/connections.dart';
import 'package:cache/search/core_config.dart' show notebookConfig;
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache_search/cache_search.dart' show SearchCore;
import 'package:flutter_test/flutter_test.dart';

import 'agent.dart';

void main() {
  final env = Platform.environment;
  test('device', timeout: Timeout.none, skip: env['PROOF_DIR'] == null ? 'PROOF_DIR not set' : false, () async {
    final root = Directory(env['PROOF_DIR']!)..createSync(recursive: true);
    final support = Directory('${root.path}/data')..createSync(recursive: true);
    final port = int.parse(env['PROOF_PORT']!);
    final shareDir = Directory('${support.path}/$kNotebookShareDir');

    final core = await SearchCore.open(const [], extra: {'notebook': notebookConfig(support)});
    final notebooks = NotebookState(backend: CoreNotebookBackend(() async => core), mediaDir: () async => Directory('${support.path}/notebook'));
    late final SharingState sharing;
    final connections = NotebookConnections(
      notebook: notebooks,
      dir: () async => Directory('${support.path}/notebook-sync'),
      shareFolder: () => shareDir,
      shareOn: () => sharing.running && sharing.shareOf('notebooks') != null,
      storePhoto: (id, bytes) async {
        final f = await notebooks.photoFile(id);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
      },
    );
    sharing = SharingState(
      policy: proofPolicy(),
      supportDir: () async => support,
      deviceName: env['PROOF_NAME'] ?? 'Device',
      kinds: [notebooksKind(shareDir)],
      opener: proofOpener(port),
    );
    // main.dart's order: what keeps notebook ids first, the journal replayed, the notebooks read, the upgrade captured, then sharing.
    notebooks.privateSharing = connections;
    await notebooks.start();
    await sharing.init();

    final agent = Agent(
      dir: root,
      nb: notebooks,
      sharing: sharing,
      syncFolder: connections.syncAll,
      conversion: () => 'n/a',
      gate: () => false,
      shareDir: shareDir,
      closeAll: () async {
        sharing.dispose();
        await core.close();
      },
    );
    await agent.loop();
  });
}
