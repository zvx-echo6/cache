import 'dart:io';

import 'package:cache/app_fs_io.dart';
import 'package:cache/app_fs_base.dart';
import 'package:cache/platform/backup_scope.dart';
import 'package:cache/sharing/settings_files.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeFlagger implements BackupFlagger {
  final List<String> flagged = [];
  bool fails = false;

  @override
  Future<bool> flagIfPresent(String path) async {
    if (fails) throw StateError('no');
    flagged.add(path);
    return true;
  }
}

/// The `path` of every `<include>` in each section of an Android backup XML file (no XML package: the files are plain).
Map<String, List<String>> includesBySection(String xml) {
  final out = <String, List<String>>{};
  final inc = RegExp(r'<include\s+domain="([^"]+)"\s+path="([^"]+)"\s*/>');
  final sections = RegExp(r'<(cloud-backup|device-transfer|full-backup-content)>(.*?)</\1>', dotAll: true);
  for (final s in sections.allMatches(xml)) {
    out[s.group(1)!] = [
      for (final m in inc.allMatches(s.group(2)!)) ...[
        if (m.group(1) == 'file') m.group(2)! else throw StateError('domain ${m.group(1)}'),
      ]
    ];
    expect(RegExp(r'<exclude').hasMatch(s.group(2)!), isFalse, reason: 'include-only');
  }
  return out;
}

void main() {
  const xmlDir = 'android/app/src/main/res/xml';

  group('allow-list', () {
    test('the own-sources folder is the computed one', () {
      expect(kOwnSourcesFolder, 'live-catalogues/473764f0fe8c');
      expect(kBackupAllowList, ['settings.json', 'layout.json', 'preferences.json', 'maps.json', kOwnSourcesFolder]);
    });

    test('equals the includes in data_extraction_rules.xml (both sections)', () {
      final s = includesBySection(File('$xmlDir/data_extraction_rules.xml').readAsStringSync());
      expect(s.keys.toSet(), {'cloud-backup', 'device-transfer'});
      for (final e in s.entries) {
        expect(e.value, kBackupAllowList, reason: e.key);
      }
    });

    test('equals the includes in full_backup_content.xml', () {
      final s = includesBySection(File('$xmlDir/full_backup_content.xml').readAsStringSync());
      expect(s['full-backup-content'], kBackupAllowList);
    });
  });

  group('the iPhone sweep decision', () {
    test('allow-listed files are left alone; everything else is flagged', () {
      final r = backupExclusions([
        'settings.json', 'layout.json', 'preferences.json', 'maps.json', 'sharing.json',
        'sync', 'sync-restored', 'notebook', 'conversations.db', 'conversations.db-wal', 'conversations.db-shm',
        'user.sqlite', 'brand-new-thing', 'live-catalogues',
      ], ['473764f0fe8c', 'aaaaaaaaaaaa']);
      expect(r, [
        'sharing.json', 'sync', 'sync-restored', 'notebook', 'conversations.db', 'conversations.db-wal', 'conversations.db-shm',
        'user.sqlite', 'brand-new-thing', 'live-catalogues/aaaaaaaaaaaa',
      ]);
      expect(r, isNot(contains('live-catalogues')));
      expect(r, isNot(contains(kOwnSourcesFolder)));
    });

    test('sweep flags what is there, creates nothing, and keeps going past a failure', () async {
      final tmp = Directory.systemTemp.createTempSync('backup_scope_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final support = Directory('${tmp.path}/support')..createSync();
      final docs = Directory('${tmp.path}/docs')..createSync();
      File('${support.path}/settings.json').writeAsStringSync('{}');
      File('${support.path}/user.sqlite').writeAsStringSync('x');
      Directory('${support.path}/sync').createSync();
      Directory('${support.path}/$kOwnSourcesFolder').createSync(recursive: true);
      Directory('${support.path}/live-catalogues/bbbbbbbbbbbb').createSync();
      File('${docs.path}/model.gguf').writeAsStringSync('x');
      final before = tmp.listSync(recursive: true).length;
      final f = FakeFlagger();
      await sweepBackupFlags(support: support, docs: docs, flagger: f);
      expect(f.flagged.toSet(), {
        '${support.path}/user.sqlite',
        '${support.path}/sync',
        '${support.path}/live-catalogues/bbbbbbbbbbbb',
        '${docs.path}/model.gguf',
      });
      expect(tmp.listSync(recursive: true).length, before);
      f.fails = true;
      await sweepBackupFlags(support: support, docs: docs, flagger: f); // logged, not thrown
    });
  });

  group('the write hook', () {
    late Directory tmp;
    late Directory support;
    late Directory docs;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('backup_hook_test');
      support = Directory('${tmp.path}/support')..createSync();
      docs = Directory('${tmp.path}/docs')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    IoAppFs fs(FakeFlagger f, {required bool ios}) =>
        IoAppFs(supportOverride: support, docsOverride: docs, flagger: f, onIOS: ios);

    test('iPhone: a non-allow-listed atomic write is flagged; an allow-listed one is not', () async {
      final f = FakeFlagger();
      final a = fs(f, ios: true);
      Directory('${support.path}/$kOwnSourcesFolder').createSync(recursive: true);
      Directory('${support.path}/live-catalogues/cccccccccccc').createSync(recursive: true);
      await a.writeStringAtomic(AppRoot.support, 'sharing.json', '{}');
      await a.writeBytesAtomic(AppRoot.support, 'user.sqlite', [1]);
      await a.writeStringAtomic(AppRoot.support, 'settings.json', '{}');
      await a.writeStringAtomic(AppRoot.support, '$kOwnSourcesFolder/catalogue.json', '{}');
      await a.writeStringAtomic(AppRoot.support, 'live-catalogues/cccccccccccc/catalogue.json', '{}');
      a.writeStringAtomicSync(AppRoot.support, 'notebook.json', '{}');
      await Future<void>.delayed(Duration.zero);
      await a.writeStringAtomic(AppRoot.docs, 'x.bin', '{}');
      expect(f.flagged.map((p) => p.substring(tmp.path.length + 1)).toList(), [
        'support/sharing.json',
        'support/user.sqlite',
        'support/live-catalogues/cccccccccccc/catalogue.json',
        'support/notebook.json',
        'docs/x.bin',
      ]);
    });

    test('Android: never flags', () async {
      final f = FakeFlagger();
      await fs(f, ios: false).writeStringAtomic(AppRoot.support, 'sharing.json', '{}');
      expect(f.flagged, isEmpty);
    });

    test('a throwing flag does not fail the write', () async {
      final f = FakeFlagger()..fails = true;
      final a = fs(f, ios: true);
      await a.writeStringAtomic(AppRoot.support, 'sharing.json', 'ok');
      a.writeStringAtomicSync(AppRoot.support, 'sharing2.json', 'ok2');
      await Future<void>.delayed(Duration.zero);
      expect(File('${support.path}/sharing.json').readAsStringSync(), 'ok');
      expect(File('${support.path}/sharing2.json').readAsStringSync(), 'ok2');
    });
  });
}
