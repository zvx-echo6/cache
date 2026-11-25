import 'dart:convert';
import 'dart:io';

import 'package:cache/sharing/identity_keep.dart';
import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'install_marker_test.dart' show FakeMarkerStore;
import 'support/settings_rig.dart';

/// The second copy of the device's key, faked: like the install marker's device half, it never travels with the folder.
class FakeKeepStore implements IdentityKeepStore {
  FakeKeepStore([this.value]);

  String? value;
  bool readFails = false;
  int writes = 0;

  @override
  Future<String?> read() async {
    if (readFails) throw StateError('keychain locked');
    return value;
  }

  @override
  Future<void> write(String v) async {
    writes++;
    value = v;
  }
}

List<int> keyOf(int seed) => List.generate(32, (i) => (seed * 31 + i) % 256);

Map<String, dynamic> kept(FakeKeepStore s) => jsonDecode(s.value!) as Map<String, dynamic>;

void main() {
  late Directory tmp;
  late Directory sync;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('identity_keep_test');
    sync = Directory('${tmp.path}/sync');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File main() => File('${sync.path}/$kKeyFile');
  void writeMain(List<int> b) {
    sync.createSync(recursive: true);
    main().writeAsBytesSync(b);
  }

  test('main missing, the copy valid with this install id: main is restored, so the device keeps its id', () async {
    final store = FakeKeepStore(encodeKept('X', keyOf(1)));
    final r = await keepIdentity(syncDir: sync, installId: 'X', store: store);
    expect(r, KeepState.restored);
    expect(main().readAsBytesSync(), keyOf(1));
    expect(File('${sync.path}/identity.tmp').existsSync(), isFalse);
  });

  test('main the wrong length, the copy valid with this install id: main is restored', () async {
    writeMain(List.filled(31, 7));
    final store = FakeKeepStore(encodeKept('X', keyOf(1)));
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.restored);
    expect(main().readAsBytesSync(), keyOf(1));
  });

  test('a copy with another install id is not used: the engine makes a new key, which the copy then takes', () async {
    final store = FakeKeepStore(encodeKept('OTHER', keyOf(1)));
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.missing);
    expect(main().existsSync(), isFalse, reason: 'nothing restored');
    writeMain(keyOf(2)); // the engine's new key
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.written);
    expect(kept(store), {'install_id': 'X', 'key': base64Encode(keyOf(2))});
  });

  test('both gone: a new key, and both are written', () async {
    final store = FakeKeepStore();
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.missing);
    writeMain(keyOf(3));
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.written);
    expect(kept(store), {'install_id': 'X', 'key': base64Encode(keyOf(3))});
  });

  test('main fine, the copy missing: the copy is written; the same again changes nothing', () async {
    writeMain(keyOf(4));
    final store = FakeKeepStore();
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.written);
    expect(kept(store), {'install_id': 'X', 'key': base64Encode(keyOf(4))});
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.kept);
    expect(store.writes, 1);
  });

  test('main fine, the copy different (another key or install id): main wins and the copy follows it', () async {
    writeMain(keyOf(4));
    final store = FakeKeepStore(encodeKept('X', keyOf(9)));
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.written);
    expect(main().readAsBytesSync(), keyOf(4));
    expect(kept(store)['key'], base64Encode(keyOf(4)));
    store.value = encodeKept('OLD', keyOf(4));
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.written);
    expect(kept(store)['install_id'], 'X');
  });

  test('a copy that is not readable text or not 32 bytes is not used', () async {
    for (final bad in ['nonsense', jsonEncode({'install_id': 'X', 'key': base64Encode(List.filled(12, 1))}), jsonEncode({'install_id': 'X'})]) {
      final store = FakeKeepStore(bad);
      expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.missing, reason: bad);
      expect(main().existsSync(), isFalse);
    }
  });

  test('main missing and the copy cannot be read: unknown, so no new key may be made', () async {
    final store = FakeKeepStore(encodeKept('X', keyOf(1)))..readFails = true;
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.unknown);
    expect(main().existsSync(), isFalse);
  });

  test('no install id known: nothing is restored and no new key may be made', () async {
    final store = FakeKeepStore(encodeKept('X', keyOf(1)));
    expect(await keepIdentity(syncDir: sync, installId: null, store: store), KeepState.unknown);
    expect(main().existsSync(), isFalse);
  });

  test('main there but unreadable: left byte-identical, the copy untouched (the engine then fails loudly)', () async {
    writeMain(keyOf(5));
    final store = FakeKeepStore(encodeKept('X', keyOf(1)));
    await Process.run('chmod', ['000', main().path]);
    final rootReads = (() {
      try {
        main().readAsBytesSync();
        return true;
      } catch (_) {
        return false;
      }
    })();
    if (rootReads) {
      await Process.run('chmod', ['600', main().path]);
      markTestSkipped('running as root: a mode-000 file is still readable');
      return;
    }
    expect(await keepIdentity(syncDir: sync, installId: 'X', store: store), KeepState.unreadable);
    await Process.run('chmod', ['600', main().path]);
    expect(main().readAsBytesSync(), keyOf(5));
    expect(kept(store)['key'], base64Encode(keyOf(1)));
    expect(store.writes, 0);
  });

  group('in the sharing start', () {
    /// A sharing start on the phone path: the marker, the copy, and an engine that (as cache_sync does) makes a key in an empty
    /// folder unless told not to, or fails as cache_sync does on a key it cannot read.
    Future<({SharingState s, Map<String, Object?>? config, List<int>? keyAtOpen})> start(
      WidgetTester tester,
      SettingsRig r, {
      required FakeMarkerStore marker,
      required FakeKeepStore keep,
      List<int>? engineKey,
      Object? engineError,
    }) async {
      File('${r.dir.path}/sharing.json').writeAsStringSync('{"enabled":true}');
      Map<String, Object?>? config;
      List<int>? keyAtOpen;
      final s = SharingState(
        policy: r.policy,
        supportDir: () async => r.dir,
        kinds: const [],
        installMarker: marker,
        identityKeep: keep,
        opener: (c) async {
          config = c;
          final f = File('${c['dir']}/$kKeyFile');
          keyAtOpen = f.existsSync() ? f.readAsBytesSync() : null;
          if (engineError != null) throw engineError;
          if (keyAtOpen == null || keyAtOpen!.length != 32) {
            if (c['make_identity'] == false) throw StateError("Can't read this device's identity");
            f.writeAsBytesSync(engineKey ?? keyOf(42));
          }
          return r.sync;
        },
      );
      await tester.runAsync(s.init);
      return (s: s, config: config, keyAtOpen: keyAtOpen);
    }

    testWidgets('main missing, copy valid with the matching install id: restored before the engine opens, same device', (tester) async {
      final r = await SettingsRig.create(tester);
      final sync = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${sync.path}/install-id').writeAsStringSync('X');
      final keep = FakeKeepStore(encodeKept('X', keyOf(1)));
      final x = await start(tester, r, marker: FakeMarkerStore('X'), keep: keep);
      expect(x.keyAtOpen, keyOf(1), reason: 'the engine opened on the kept key');
      expect(x.s.running, isTrue);
      expect(x.s.newDevice, isFalse);
      expect(x.config!.containsKey('make_identity'), isFalse);
      x.s.dispose();
      await r.dispose(tester);
    });

    testWidgets('both gone: the engine makes a new key and the copy takes it after the open', (tester) async {
      final r = await SettingsRig.create(tester);
      final keep = FakeKeepStore();
      final marker = FakeMarkerStore();
      final x = await start(tester, r, marker: marker, keep: keep, engineKey: keyOf(7));
      expect(x.keyAtOpen, isNull);
      expect(x.s.running, isTrue);
      expect(kept(keep), {'install_id': marker.value, 'key': base64Encode(keyOf(7))});
      x.s.dispose();
      await r.dispose(tester);
    });

    testWidgets('a restored folder from another phone: moved aside, a new identity, and the copy is not used', (tester) async {
      final r = await SettingsRig.create(tester);
      final sync = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${sync.path}/install-id').writeAsStringSync('X');
      File('${sync.path}/$kKeyFile').writeAsBytesSync(keyOf(1));
      // Even a copy holding that very folder's id and key (it cannot travel, but if it were there) is not used.
      final keep = FakeKeepStore(encodeKept('X', keyOf(1)));
      final marker = FakeMarkerStore();
      final x = await start(tester, r, marker: marker, keep: keep, engineKey: keyOf(8));
      expect(x.s.newDevice, isTrue);
      expect(x.keyAtOpen, isNull, reason: 'the old key is never opened or brought back');
      expect(marker.value, isNot('X'));
      expect(File('${sync.path}/$kKeyFile').readAsBytesSync(), keyOf(8));
      expect(kept(keep), {'install_id': marker.value, 'key': base64Encode(keyOf(8))});
      x.s.dispose();
      await r.dispose(tester);
    });

    testWidgets('main missing and the copy cannot be read: the engine is told not to make a new identity, and the start fails',
        (tester) async {
      final r = await SettingsRig.create(tester);
      final sync = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${sync.path}/install-id').writeAsStringSync('X');
      final keep = FakeKeepStore(encodeKept('X', keyOf(1)))..readFails = true;
      final x = await start(tester, r, marker: FakeMarkerStore('X'), keep: keep);
      expect(x.config!['make_identity'], false);
      expect(x.s.running, isFalse);
      expect(x.s.error, contains("Can't read this device's identity"));
      expect(File('${sync.path}/$kKeyFile').existsSync(), isFalse);
      x.s.dispose();
      await r.dispose(tester);
    });

    testWidgets("an engine that can't read the key: the start fails with that status, the key and the copy untouched", (tester) async {
      final r = await SettingsRig.create(tester);
      final sync = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${sync.path}/install-id').writeAsStringSync('X');
      File('${sync.path}/$kKeyFile').writeAsBytesSync(keyOf(5));
      final keep = FakeKeepStore(encodeKept('X', keyOf(5)));
      final x = await start(tester, r, marker: FakeMarkerStore('X'), keep: keep,
          engineError: const CacheSearchException('internal', "Can't read this device's identity: Permission denied (os error 13)"));
      expect(x.s.running, isFalse);
      expect(x.s.error, contains("Can't read this device's identity"));
      expect(File('${sync.path}/$kKeyFile').readAsBytesSync(), keyOf(5));
      expect(kept(keep)['key'], base64Encode(keyOf(5)));
      x.s.dispose();
      await r.dispose(tester);
    });

    // A reinstall on the same phone, as the install marker treats it today (install_marker_test.dart: "marker present, folder
    // missing" keeps the marker's id). What survives an uninstall differs:
    // - iPhone: Keychain items with ...ThisDeviceOnly survive an uninstall, so the marker and the copy are both still there while
    //   the app's folders are new. The old identity comes back.
    // - Android: the no-backup folder is cleared with the app, so the marker and the copy are gone. A new identity.
    testWidgets('reinstall, iPhone (marker and copy survive, folders gone): the old identity comes back', (tester) async {
      final r = await SettingsRig.create(tester);
      final marker = FakeMarkerStore('X');
      final keep = FakeKeepStore(encodeKept('X', keyOf(1)));
      final x = await start(tester, r, marker: marker, keep: keep);
      expect(x.keyAtOpen, keyOf(1));
      expect(marker.value, 'X');
      expect(x.s.newDevice, isFalse);
      x.s.dispose();
      await r.dispose(tester);
    });

    testWidgets('reinstall, Android (marker, copy and folders all gone): a new identity', (tester) async {
      final r = await SettingsRig.create(tester);
      final keep = FakeKeepStore();
      final x = await start(tester, r, marker: FakeMarkerStore(), keep: keep, engineKey: keyOf(9));
      expect(x.keyAtOpen, isNull);
      expect(kept(keep)['key'], base64Encode(keyOf(9)));
      x.s.dispose();
      await r.dispose(tester);
    });
  });
}
