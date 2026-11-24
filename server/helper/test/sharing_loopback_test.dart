import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/sync_core_io.dart';
import '../../../app/lib/sharing/settings_log.dart';
import '../bin/keystore.dart';
import '../bin/server_settings_sync.dart';
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

  test('a file written again after the other device deleted it beats the delete and reaches the wiped side', () async {
    expect(lib, isNotNull, reason: 'CACHE_CORE_LIB (and CACHE_REQUIRE_CORE=1) must name libcache_search.so');
    final tmp = Directory.systemTemp.createTempSync('sharing_loopback_rewrite');
    final hosts = <SharingHost>[];
    SyncCore? b;
    try {
      final data = Directory('${tmp.path}/data')..createSync();
      final support = Directory('${data.path}/app/support')..createSync(recursive: true);
      final docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
      final note = File('${data.path}/models/note.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('first version\n');
      final host = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(host);
      await host.setUp();
      expect(host.snapshot()['running'], true, reason: '${host.snapshot()['error']}');
      await host.setKind('models', true);
      final bDir = Directory('${tmp.path}/b/sync');
      final bModels = Directory('${tmp.path}/b/models')..createSync(recursive: true);
      b = await SyncCore.open({'dir': bDir.path, 'name': 'Phone', ..._noNetwork}, libraryPath: lib);
      await b.call('share_add', {'id': 'models', 'name': 'Models', 'path': bModels.path});
      final code = (await b.call('link_code'))['code'] as String;
      await host.invoke('sharing.link_start', {'code': code});
      await until(() => (host.snapshot()['link'] as Map)['state'] != 'linking', 'the link');
      final onB = File('${bModels.path}/note.md');
      Future<void> round() async {
        await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
        await b!.call('sync_now');
      }

      Future<void> roundsUntil(bool Function() ok, String what) async {
        final end = DateTime.now().add(const Duration(seconds: 90));
        while (!ok()) {
          if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
          await round();
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }

      await roundsUntil(() => onB.existsSync(), 'the note on the second device');
      // The note goes missing on the host (a wiped folder), and the delete reaches the second device.
      note.deleteSync();
      await roundsUntil(() => !onB.existsSync(), 'the delete on the second device');
      // The host writes it again (what Cache does when a file is missing and no delete marker exists): it reaches the wiped side.
      note.writeAsStringSync('written again\n');
      await roundsUntil(() => onB.existsSync() && onB.readAsStringSync() == 'written again\n', 'the note written again on the second device');
      await round();
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(note.existsSync(), isTrue, reason: 'and the delete does not come back to the host');
      expect(onB.readAsStringSync(), 'written again\n');
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

  test('the Bookshelves log: the server\'s own log stays whole and its own while a Match device syncs, the other device\'s log arrives beside it, and a restored older copy on the other side never replaces it', () async {
    expect(lib, isNotNull, reason: 'CACHE_CORE_LIB (and CACHE_REQUIRE_CORE=1) must name libcache_search.so');
    final tmp = Directory.systemTemp.createTempSync('sharing_loopback_log');
    final hosts = <SharingHost>[];
    SyncCore? b;
    try {
      final data = Directory('${tmp.path}/data')..createSync();
      final support = Directory('${data.path}/app/support')..createSync(recursive: true);
      final docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
      final host = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(host);
      await host.setUp();
      expect(host.snapshot()['running'], true, reason: '${host.snapshot()['error']}');
      final serverId = (host.snapshot()['status'] as Map)['id'] as String;
      final serverLog = File('${data.path}/bookshelves/log/$serverId.jsonl');
      final lines = <String>[for (var i = 0; i < 5; i++) '{"ev":"place","n":$i}'];
      serverLog.createSync(recursive: true);
      serverLog.writeAsStringSync('${lines.join('\n')}\n', flush: true);

      // The second device: a phone's Bookshelves folder with its own log, shared under the same id.
      final bBook = Directory('${tmp.path}/b/bookshelves')..createSync(recursive: true);
      b = await SyncCore.open({'dir': '${tmp.path}/b/sync', 'name': 'Phone', ..._noNetwork}, libraryPath: lib);
      final phoneId = (await b.call('status'))['id'] as String;
      final phoneLogText = '${[for (var i = 0; i < 3; i++) '{"ev":"title","n":$i}'].join('\n')}\n';
      File('${bBook.path}/log/$phoneId.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(phoneLogText, flush: true);
      await b.call('share_add', {'id': 'bookshelves', 'name': 'Bookshelves', 'path': bBook.path});

      final code = (await b.call('link_code'))['code'] as String;
      await host.invoke('sharing.link_start', {'code': code});
      await until(() => (host.snapshot()['link'] as Map)['state'] != 'linking', 'the link');
      expect(host.snapshot()['link'], containsPair('state', 'done'));
      await until(() => ((host.snapshot()['status'] as Map)['peers'] as List).isNotEmpty, 'the peer in the status');
      // A new link starts Off; the Bookshelves log goes to Match devices only.
      final peerOnServer = ((host.snapshot()['status'] as Map)['peers'] as List).map((p) => (p as Map)['id'] as String).single;
      await host.invoke('sharing.call', {'method': 'set_link', 'args': {'peer': peerOnServer, 'link': {'mode': 'match'}}});
      final peerOnPhone = (((await b.call('status'))['peers']) as List).map((p) => (p as Map)['id'] as String).single;
      await b.call('set_link', {'peer': peerOnPhone, 'link': {'mode': 'match'}});

      Future<void> syncBoth() async {
        await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
        await b!.call('sync_now');
      }

      final phoneCopyOfServer = File('${bBook.path}/log/$serverId.jsonl');
      final serverCopyOfPhone = File('${data.path}/bookshelves/log/$phoneId.jsonl');

      // The server appends to its own log (one whole line at a time, as the Rust writer does) while the engines keep syncing.
      final seen = <String>[];
      for (var i = 5; i < 45; i++) {
        final line = '{"ev":"place","n":$i}';
        lines.add(line);
        serverLog.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
        if (i % 5 == 0) await syncBoth();
        if (phoneCopyOfServer.existsSync()) seen.add(phoneCopyOfServer.readAsStringSync());
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final whole = '${lines.join('\n')}\n';
      final end = DateTime.now().add(const Duration(seconds: 120));
      while (!(phoneCopyOfServer.existsSync() && phoneCopyOfServer.readAsStringSync() == whole && serverCopyOfPhone.existsSync())) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for both logs on both devices');
        await syncBoth();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      // Everything the other device saw of the server's log was a whole-line start of it.
      for (final s in [...seen, phoneCopyOfServer.readAsStringSync()]) {
        expect(whole.startsWith(s), isTrue, reason: 'a partial or foreign copy was offered: $s');
        expect(s.isEmpty || s.endsWith('\n'), isTrue, reason: 'a half line reached the other device');
      }

      // The server's file: every line intact, in order, only the server's.
      expect(serverLog.readAsLinesSync(), lines);
      expect(serverCopyOfPhone.readAsStringSync(), phoneLogText, reason: 'the phone\'s log arrives as log/<its id>.jsonl');
      expect(File('${bBook.path}/log/$phoneId.jsonl').readAsStringSync(), phoneLogText);
      final names = Directory('${data.path}/bookshelves/log').listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, {'$serverId.jsonl', '$phoneId.jsonl'}, reason: 'no conflict copy, nothing else');

      // Open question 6: the other side holds a restored, older copy of the server's own log (a backup put back). The server's own
      // log is never replaced by it, and no conflict copy appears beside it.
      final older = '${lines.take(12).join('\n')}\n';
      phoneCopyOfServer.writeAsStringSync(older, flush: true);
      for (var i = 0; i < 6; i++) {
        await syncBoth();
        await Future<void>.delayed(const Duration(seconds: 4));
      }
      expect(serverLog.readAsStringSync(), whole, reason: 'the server\'s own log was replaced by the other device\'s older copy');
      expect(Directory('${data.path}/bookshelves/log').listSync().map((e) => e.uri.pathSegments.last).toSet(), {'$serverId.jsonl', '$phoneId.jsonl'});
    } finally {
      for (final h in hosts) {
        await h.stop();
      }
      await b?.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 6)), skip: skip);

  test('settings: a phone-like device\'s event lands in the server\'s file, and a browser-style write of a server file arrives as a line on the other side', () async {
    expect(lib, isNotNull, reason: 'CACHE_CORE_LIB (and CACHE_REQUIRE_CORE=1) must name libcache_search.so');
    final tmp = Directory.systemTemp.createTempSync('sharing_loopback_settings');
    final hosts = <SharingHost>[];
    ServerSettingsSync? sync;
    SyncCore? b;
    try {
      final data = Directory('${tmp.path}/data')..createSync();
      final support = Directory('${data.path}/app/support')..createSync(recursive: true);
      final docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
      final host = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(host);
      await host.setUp();
      expect(host.snapshot()['running'], true, reason: '${host.snapshot()['error']}');
      final serverId = (host.snapshot()['status'] as Map)['id'] as String;
      sync = ServerSettingsSync(
        support: support,
        running: () => host.running,
        myId: () => host.myId,
        peers: () => host.peers,
        askSince: () => host.askSince,
        every: const Duration(seconds: 2),
      );
      host.onShareChanged = (ids) => sync!.shareChanged(ids);
      await sync.start();

      final bSettings = Directory('${tmp.path}/b/settings-sync')..createSync(recursive: true);
      b = await SyncCore.open({'dir': '${tmp.path}/b/sync', 'name': 'Phone', ..._noNetwork}, libraryPath: lib);
      final phoneId = (await b.call('status'))['id'] as String;
      await b.call('share_add', {'id': 'settings', 'name': 'Settings', 'path': bSettings.path});
      final code = (await b.call('link_code'))['code'] as String;
      await host.invoke('sharing.link_start', {'code': code});
      await until(() => (host.snapshot()['link'] as Map)['state'] != 'linking', 'the link');
      await until(() => ((host.snapshot()['status'] as Map)['peers'] as List).isNotEmpty, 'the peer in the status');
      final peerOnServer = ((host.snapshot()['status'] as Map)['peers'] as List).map((p) => (p as Map)['id'] as String).single;
      await host.invoke('sharing.call', {'method': 'set_link', 'args': {'peer': peerOnServer, 'link': {'mode': 'match'}}});
      final peerOnPhone = (((await b.call('status'))['peers']) as List).map((p) => (p as Map)['id'] as String).single;
      await b.call('set_link', {'peer': peerOnPhone, 'link': {'mode': 'match'}});

      Future<void> syncBoth() async {
        await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
        await b!.call('sync_now');
      }

      // The phone-like side appends a settings event to its own log; it syncs; the server's file shows the value.
      await SettingsLog(dir: bSettings.path, device: phoneId)
          .append(SettingsEvent(at: DateTime.now().millisecondsSinceEpoch, dev: phoneId, key: 'appearance.theme', value: 'light'));
      final settingsFile = File('${support.path}/settings.json');
      final end = DateTime.now().add(const Duration(seconds: 120));
      while (!(settingsFile.existsSync() && settingsFile.readAsStringSync().contains('"light"'))) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for the setting in the server\'s file');
        await syncBoth();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(sync.applied, 1);

      // A browser writes a server file (fs.write), the host is told: a line in the server's own log arrives on the other side.
      File('${support.path}/layout.json').writeAsStringSync('{"pinned":["ask","library"]}');
      await sync.fileChanged('layout.json');
      final serverLogOnPhone = File('${bSettings.path}/log/$serverId.jsonl');
      final end2 = DateTime.now().add(const Duration(seconds: 120));
      while (!(serverLogOnPhone.existsSync() && serverLogOnPhone.readAsStringSync().contains('home.bar'))) {
        if (DateTime.now().isAfter(end2)) fail('timed out waiting for the server\'s line on the other side');
        await syncBoth();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final evs = [for (final l in serverLogOnPhone.readAsLinesSync()) SettingsEvent.fromLine(l)!];
      expect(evs.where((e) => e.key == 'home.bar').single.value, ['ask', 'library']);
      expect(evs.every((e) => e.dev == serverId), isTrue);
      expect(evs.where((e) => e.key == 'appearance.theme'), isEmpty, reason: 'what the host applied did not echo back');
    } finally {
      sync?.stop();
      for (final h in hosts) {
        await h.stop();
      }
      await b?.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 6)), skip: skip);

  test('keys: a key ticked on the server arrives on the other side, and a key from the other side lands in the server\'s keystore file', () async {
    expect(lib, isNotNull, reason: 'CACHE_CORE_LIB (and CACHE_REQUIRE_CORE=1) must name libcache_search.so');
    final tmp = Directory.systemTemp.createTempSync('sharing_loopback_keys');
    final hosts = <SharingHost>[];
    ServerSettingsSync? sync;
    SyncCore? b;
    try {
      final data = Directory('${tmp.path}/data')..createSync();
      final support = Directory('${data.path}/app/support')..createSync(recursive: true);
      final docs = Directory('${data.path}/app/docs')..createSync(recursive: true);
      final host = SharingHost(dataDir: data, supportDir: support, docsDir: docs, deviceName: 'Server', libraryPath: lib, engineConfig: _noNetwork);
      hosts.add(host);
      await host.setUp();
      expect(host.snapshot()['running'], true, reason: '${host.snapshot()['error']}');
      final keystoreFile = File('${data.path}/keystore.json');
      final store = KeyStore(keystoreFile);
      store.set('live.key.owm', 'SERVER-OWM-KEY');
      final logs = <String>[];
      sync = ServerSettingsSync(
        support: support,
        running: () => host.running,
        myId: () => host.myId,
        peers: () => host.peers,
        askSince: () => host.askSince,
        every: const Duration(seconds: 2),
        log: logs.add,
        keys: store,
        setSecrets: host.setSecrets,
        takeSecrets: host.takeSecrets,
      );
      host.onShareChanged = (ids) => sync!.shareChanged(ids);
      await sync.start();

      b = await SyncCore.open({'dir': '${tmp.path}/b/sync', 'name': 'Phone', ..._noNetwork}, libraryPath: lib);
      final code = (await b.call('link_code'))['code'] as String;
      await host.invoke('sharing.link_start', {'code': code});
      await until(() => (host.snapshot()['link'] as Map)['state'] != 'linking', 'the link');
      await until(() => ((host.snapshot()['status'] as Map)['peers'] as List).isNotEmpty, 'the peer in the status');
      final peerOnServer = ((host.snapshot()['status'] as Map)['peers'] as List).map((p) => (p as Map)['id'] as String).single;
      await host.invoke('sharing.call', {'method': 'set_link', 'args': {'peer': peerOnServer, 'link': {'mode': 'match'}}});
      final phoneStatus = await b.call('status');
      final peerOnPhone = (phoneStatus['peers'] as List).map((p) => (p as Map)['id'] as String).single;
      await b.call('set_link', {'peer': peerOnPhone, 'link': {'mode': 'match'}});

      Future<void> syncBoth() async {
        await host.invoke('sharing.call', {'method': 'sync_now', 'args': <String, Object?>{}});
        await b!.call('sync_now');
      }

      // server to phone: ticked on the server, the phone's take_secrets hands it over
      await sync.setKeyOn(peerOnServer, 'live.key.owm', true);
      Map<String, dynamic> taken = {};
      final end = DateTime.now().add(const Duration(seconds: 120));
      while (taken.isEmpty) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for the key on the other side');
        await syncBoth();
        final got = (await b.call('take_secrets'))['secrets'];
        if (got is Map && got.isNotEmpty) taken = got.cast<String, dynamic>();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect((taken[peerOnPhone] as Map)['live.key.owm'], 'SERVER-OWM-KEY');

      // phone to server: the phone gives a key and a name the server does not keep; the keystore file gets the first only
      await b.call('set_secrets', {'peer': peerOnPhone, 'secrets': {'search.kagi.key': 'PHONE-KAGI-KEY', 'app.pin': 'NOT-A-SYNCED-KEY'}});
      final end2 = DateTime.now().add(const Duration(seconds: 120));
      while (store.get('search.kagi.key') == null) {
        if (DateTime.now().isAfter(end2)) fail('timed out waiting for the key in the server\'s keystore');
        await syncBoth();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final onDisk = KeyStore(keystoreFile);
      expect(onDisk.get('search.kagi.key'), 'PHONE-KAGI-KEY');
      expect(onDisk.get('app.pin'), isNull);
      expect(logs.where((l) => l.contains('app.pin')), isNotEmpty);
      expect(logs.join('\n'), isNot(contains('PHONE-KAGI-KEY')));
      expect(logs.join('\n'), isNot(contains('SERVER-OWM-KEY')));
    } finally {
      sync?.stop();
      for (final h in hosts) {
        await h.stop();
      }
      await b?.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }, timeout: const Timeout(Duration(minutes: 6)), skip: skip);
}
