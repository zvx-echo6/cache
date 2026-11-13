import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/sync_core_io.dart';
import '../bin/sharing_host.dart';

/// Two real sync engines on this machine, linked through the sharing host: no relay, no Mainline DHT, no mDNS and no lookup
/// service (as packages/cache_search/native/cache_sync/tests/two_devices.rs), so the test needs no network.
///
/// Needs libcache_search.so: CACHE_CORE_LIB is its full path (the Linux build job sets it, with CACHE_REQUIRE_CORE=1 so that a missing
/// library fails the job instead of skipping). Without it the test is skipped, as `dart test` on a machine that has not built the core.
const _noNetwork = <String, Object?>{'relay': false, 'dht': false, 'mdns': false, 'lookup': false, 'interval_secs': 5};

Future<void> until(bool Function() ok, String what, {int secs = 90}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  final lib = Platform.environment['CACHE_CORE_LIB'];
  final required = Platform.environment['CACHE_REQUIRE_CORE'] == '1';
  final skip = (lib == null || lib.isEmpty) && !required ? 'CACHE_CORE_LIB is not set' : null;

  test('the host links with a second engine and the two keep a shared kind the same; a download in progress is never offered', () async {
    expect(lib, isNotNull, reason: 'CACHE_CORE_LIB (and CACHE_REQUIRE_CORE=1) must name libcache_search.so');
    final tmp = Directory.systemTemp.createTempSync('sharing_loopback');
    final hosts = <SharingHost>[];
    SyncCore? b;
    try {
      final data = Directory('${tmp.path}/data')..createSync();
      final support = Directory('${data.path}/app/support')..createSync(recursive: true);
      final docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
      File('${data.path}/models/whole.gguf')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.generate(200000, (i) => i * 7 % 251));
      File('${data.path}/models/half.gguf.part').writeAsStringSync('a download in progress');
      File('${data.path}/models/.hidden').writeAsStringSync('never shared');

      final host = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(host);
      await host.setUp();
      expect(host.snapshot()['running'], true, reason: '${host.snapshot()['error']}');
      await host.setKind('models', true);

      // The second device: a bare engine, sharing the same kind under the same id into its own folder.
      final bDir = Directory('${tmp.path}/b/sync');
      final bModels = Directory('${tmp.path}/b/models')..createSync(recursive: true);
      b = await SyncCore.open({'dir': bDir.path, 'name': 'Phone', ..._noNetwork}, libraryPath: lib);
      await b.call('share_add', {'id': 'models', 'name': 'Models', 'path': bModels.path});

      // Linked through the host: the second device shows its code, the host's link_start takes it and the snapshot reports it.
      final code = (await b.call('link_code'))['code'] as String;
      final first = await host.invoke('sharing.link_start', {'code': code}) as Map;
      expect(first['state'], 'linking');
      await until(() => (host.snapshot()['link'] as Map)['state'] != 'linking', 'the link');
      expect(host.snapshot()['link'], containsPair('state', 'done'));
      expect((host.snapshot()['link'] as Map)['name'], 'Phone');
      await until(() => ((host.snapshot()['status'] as Map)['peers'] as List).isNotEmpty, 'the peer in the status');
      final peers = (host.snapshot()['status'] as Map)['peers'] as List;
      expect((peers.single as Map)['name'], 'Phone');

      await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
      await b.call('sync_now');
      await until(() => File('${bModels.path}/whole.gguf').existsSync() && File('${bModels.path}/whole.gguf').lengthSync() == 200000, 'the model on the second device');
      expect(File('${bModels.path}/whole.gguf').readAsBytesSync(), File('${data.path}/models/whole.gguf').readAsBytesSync());
      // Let another round pass: what must not travel has not.
      await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(File('${bModels.path}/half.gguf.part').existsSync(), isFalse, reason: 'a download in progress is excluded');
      expect(File('${bModels.path}/.hidden').existsSync(), isFalse);

      // The host's own settings log share and the always-on indexes share are set up, and the keys cannot be reached from a browser.
      final shares = ((host.snapshot()['status'] as Map)['shares'] as List).map((s) => (s as Map)['id']).toSet();
      expect(shares, containsAll(['models', 'indexes', 'settings', 'bookshelves']));
      await expectLater(host.invoke('sharing.call', {'method': 'take_secrets', 'args': <String, Object?>{}}), throwsA(anything));

      // A restart of the host (the helper restarted): sharing starts again by itself and the link is still there.
      await host.stop();
      final again = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(again);
      await again.init();
      expect(again.snapshot()['running'], true, reason: '${again.snapshot()['error']}');
      expect(((again.snapshot()['status'] as Map)['peers'] as List), hasLength(1));
      expect(((again.snapshot()['status'] as Map)['shares'] as List).map((s) => (s as Map)['id']), contains('models'));
    } finally {
      for (final h in hosts) {
        await h.stop();
      }
      await b?.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 4)), skip: skip);
}
