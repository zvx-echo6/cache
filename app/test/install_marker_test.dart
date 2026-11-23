import 'dart:convert';
import 'dart:io';

import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/install_marker.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// The device-only store, faked: a value that never travels with the folder.
class FakeMarkerStore implements InstallMarkerStore {
  FakeMarkerStore([this.value]);

  String? value;
  final List<String> excluded = [];
  bool excludeFails = false;

  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async => value = id;
  @override
  Future<void> excludeFromBackup(String path) async {
    if (excludeFails) throw StateError('no');
    excluded.add(path);
  }
}

void main() {
  late Directory tmp;
  late Directory sync;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('install_marker_test');
    sync = Directory('${tmp.path}/sync');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File idFile() => File('${sync.path}/install-id');
  void oldFolder(String id) {
    sync.createSync(recursive: true);
    File('${sync.path}/identity.key').writeAsStringSync('old-key');
    File('${sync.path}/sync.json').writeAsStringSync('{"peers":["x"]}');
    if (id.isNotEmpty) idFile().writeAsStringSync(id);
  }

  test('both there and equal: nothing changes', () async {
    oldFolder('X');
    final store = FakeMarkerStore('X');
    final r = await checkInstallMarker(syncDir: sync, store: store);
    expect(r.state, MarkerState.normal);
    expect(File('${sync.path}/identity.key').readAsStringSync(), 'old-key');
    expect(store.value, 'X');
    expect(tmp.listSync().length, 1);
  });

  test('folder has id X, marker missing: the folder is moved aside, never deleted, and a new id is made', () async {
    oldFolder('X');
    final store = FakeMarkerStore();
    final r = await checkInstallMarker(syncDir: sync, store: store, now: () => DateTime.utc(2026, 11, 23, 1, 2, 3), makeId: () => 'NEW');
    expect(r.state, MarkerState.restored);
    expect(r.movedTo, '${tmp.path}/sync.restored-20261123T010203Z');
    expect(File('${r.movedTo}/identity.key').readAsStringSync(), 'old-key', reason: 'kept, not deleted');
    expect(File('${sync.path}/identity.key').existsSync(), isFalse, reason: 'the engine finds no key: it makes a new one');
    expect(File('${sync.path}/sync.json').existsSync(), isFalse, reason: 'no linked devices');
    expect(idFile().readAsStringSync(), 'NEW');
    expect(store.value, 'NEW');
  });

  test('folder has id X, marker is a different id: same as missing', () async {
    oldFolder('X');
    final store = FakeMarkerStore('Y');
    final r = await checkInstallMarker(syncDir: sync, store: store, makeId: () => 'NEW');
    expect(r.state, MarkerState.restored);
    expect(File('${sync.path}/identity.key').existsSync(), isFalse);
    expect(store.value, 'NEW');
    expect(idFile().readAsStringSync(), 'NEW');
    // and the next start is normal
    expect((await checkInstallMarker(syncDir: sync, store: store)).state, MarkerState.normal);
  });

  test('no id in the folder and no marker (an existing phone, first start of this build): keeps the key, writes both', () async {
    oldFolder('');
    final store = FakeMarkerStore();
    final r = await checkInstallMarker(syncDir: sync, store: store, makeId: () => 'NEW');
    expect(r.state, MarkerState.written);
    expect(File('${sync.path}/identity.key').readAsStringSync(), 'old-key');
    expect(File('${sync.path}/sync.json').existsSync(), isTrue);
    expect(idFile().readAsStringSync(), 'NEW');
    expect(store.value, 'NEW');
    expect(tmp.listSync().length, 1);
  });

  test('marker present, folder missing (a normal first set-up): the folder gets the marker, nothing is moved', () async {
    final store = FakeMarkerStore('M');
    final r = await checkInstallMarker(syncDir: sync, store: store);
    expect(r.state, MarkerState.written);
    expect(idFile().readAsStringSync(), 'M');
    expect(store.value, 'M');
    expect(tmp.listSync().length, 1);
  });

  test('marker present, folder there but with no id (a stop between the two writes): keeps the key', () async {
    oldFolder('');
    final store = FakeMarkerStore('M');
    final r = await checkInstallMarker(syncDir: sync, store: store);
    expect(r.state, MarkerState.written);
    expect(File('${sync.path}/identity.key').readAsStringSync(), 'old-key');
    expect(idFile().readAsStringSync(), 'M');
  });

  test('a first start with neither: the new id is real and unique each time', () async {
    final a = FakeMarkerStore();
    await checkInstallMarker(syncDir: sync, store: a);
    expect(a.value, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(idFile().readAsStringSync(), a.value);
  });

  test('the backup flag is set at every start, and a flag that fails does not stop the start', () async {
    final store = FakeMarkerStore();
    await prepareSyncFolder(syncDir: sync, store: store);
    await prepareSyncFolder(syncDir: sync, store: store);
    expect(store.excluded, [sync.path, sync.path]);
    store.excludeFails = true;
    expect((await prepareSyncFolder(syncDir: sync, store: store)).state, MarkerState.normal);
  });

  group('in the sharing start', () {
    testWidgets('a restored folder is moved aside before the engine opens, and the new-device message is told once', (tester) async {
      final r = await SettingsRig.create(tester);
      final dir = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${dir.path}/identity.key').writeAsStringSync('old-key');
      File('${dir.path}/install-id').writeAsStringSync('X');
      File('${r.dir.path}/sharing.json').writeAsStringSync('{"enabled":true}');
      final store = FakeMarkerStore();
      var keyAtOpen = 'not opened';
      SharingState open() => SharingState(
            policy: r.policy,
            supportDir: () async => r.dir,
            kinds: const [],
            installMarker: store,
            opener: (_) async {
              keyAtOpen = File('${dir.path}/identity.key').existsSync() ? 'old key present' : 'no old key';
              return r.sync;
            },
          );

      final s = open();
      await tester.runAsync(s.init);
      expect(keyAtOpen, 'no old key', reason: 'the engine must never open the old folder');
      expect(s.running, isTrue);
      expect(s.newDevice, isTrue);
      expect(Directory(r.dir.path).listSync().whereType<Directory>().any((d) => d.path.contains('sync.restored-')), isTrue);
      expect(jsonDecode(File('${r.dir.path}/sharing.json').readAsStringSync())['new_device'], isTrue);
      expect(store.excluded, [dir.path]);

      // The page tells it, and leaving the page marks it told.
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
      await tester.pump();
      expect(find.text('This is a new device: link it to your other devices again'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(s.newDevice, isFalse);
      expect(jsonDecode(File('${r.dir.path}/sharing.json').readAsStringSync()).containsKey('new_device'), isFalse);
      s.dispose();

      // The next start is normal: no message, nothing moved again.
      final again = open();
      await tester.runAsync(again.init);
      expect(again.newDevice, isFalse);
      expect(Directory(r.dir.path).listSync().whereType<Directory>().where((d) => d.path.contains('sync.restored-')).length, 1);
      again.dispose();
      await r.dispose(tester);
    });

    testWidgets('a folder that cannot be moved stops the start: the engine is not opened', (tester) async {
      final r = await SettingsRig.create(tester);
      final dir = Directory('${r.dir.path}/sync')..createSync(recursive: true);
      File('${dir.path}/install-id').writeAsStringSync('X');
      File('${r.dir.path}/sharing.json').writeAsStringSync('{"enabled":true}');
      var opened = false;
      final s = SharingState(
        policy: r.policy,
        supportDir: () async => r.dir,
        kinds: const [],
        installMarker: _Throwing(),
        opener: (_) async {
          opened = true;
          return r.sync;
        },
      );
      await tester.runAsync(s.init);
      expect(opened, isFalse);
      expect(s.running, isFalse);
      expect(s.error, startsWith('Sharing could not start'));
      s.dispose();
      await r.dispose(tester);
    });
  });
}

class _Throwing extends FakeMarkerStore {
  @override
  Future<String?> read() async => throw StateError('keychain locked');
}
