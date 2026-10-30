import 'dart:convert';
import 'dart:io';

import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/damaged_files.dart';
import 'package:cache/settings/data_kinds.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:cache/version.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('settings-model'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppSettings> open() async {
    final s = AppSettings(settingsDirOverride: dir);
    await s.init();
    return s;
  }

  test('the defaults: serious alerts pop up, quiet 10 PM to 6 AM, updates always on mobile data, downloads off, web search off', () async {
    final s = await open();
    expect(s.popUpFor, PopUpFor.serious);
    expect(s.quiet.on, isTrue);
    expect(s.quiet.label, '10 PM to 6 AM');
    expect(s.mobileForUpdates, isTrue);
    expect(s.mobileForDownloads, isFalse);
    expect(s.webSearchOn, isFalse);
  });

  test('every choice is saved and read back', () async {
    final s = await open();
    s.setPopUpFor(PopUpFor.all);
    s.setToldNoPopUps();
    s.setQuiet(const QuietHours(on: true, from: 21 * 60 + 30, to: 7 * 60));
    s.setMobileForDownloads(true);
    s.setWebSearchOn(true);
    final again = await open();
    expect(again.popUpFor, PopUpFor.all);
    expect(again.toldNoPopUps, isTrue);
    expect(again.quiet.from, 21 * 60 + 30);
    expect(again.quiet.to, 7 * 60);
    expect(again.quiet.label, '9:30 PM to 7 AM');
    expect(again.mobileForDownloads, isTrue);
    expect(again.webSearchOn, isTrue);
    again.setQuiet(again.quiet.copyWith(on: false));
    expect((await open()).quiet.on, isFalse);
  });

  test('a damaged file gives the defaults', () async {
    File('${dir.path}/preferences.json').writeAsStringSync('{not json');
    final s = await open();
    expect(s.mobileForDownloads, isFalse);
    expect(s.popUpFor, PopUpFor.serious);
  });

  test('the old pop-up switch reads as the one choice: off is None, on is Serious only', () async {
    File('${dir.path}/preferences.json').writeAsStringSync('{"alertPopups": false, "ringThroughExtreme": true}');
    expect((await open()).popUpFor, PopUpFor.none);
    File('${dir.path}/preferences.json').writeAsStringSync('{"alertPopups": true}');
    expect((await open()).popUpFor, PopUpFor.serious);
  });

  test('quiet hours cross midnight', () {
    const q = QuietHours();
    DateTime at(int h, int m) => DateTime(2026, 10, 26, h, m);
    expect(q.contains(at(22, 0)), isTrue);
    expect(q.contains(at(23, 59)), isTrue);
    expect(q.contains(at(0, 0)), isTrue);
    expect(q.contains(at(5, 59)), isTrue);
    expect(q.contains(at(6, 0)), isFalse);
    expect(q.contains(at(12, 0)), isFalse);
    expect(q.contains(at(21, 59)), isFalse);
    const day = QuietHours(from: 13 * 60, to: 15 * 60);
    expect(day.contains(at(14, 0)), isTrue);
    expect(day.contains(at(15, 0)), isFalse);
    expect(const QuietHours(on: false).contains(at(23, 0)), isFalse);
    expect(const QuietHours(from: 60, to: 60).contains(at(1, 0)), isFalse, reason: 'equal times are an empty window');
  });

  test('what an alert does when it arrives (read by the alert notification code)', () async {
    final s = await open();
    final night = DateTime(2026, 10, 26, 23, 30);
    final noon = DateTime(2026, 10, 26, 12);
    // Serious only (the default): only serious alerts pop up, and they ring in quiet hours too.
    expect(s.deliveryFor(serious: true, now: noon), AlertDelivery.normal);
    expect(s.deliveryFor(serious: true, now: night), AlertDelivery.normal, reason: 'serious still ring');
    expect(s.deliveryFor(serious: false, now: noon), AlertDelivery.none);
    // All alerts: the rest pop up too, silently in quiet hours.
    s.setPopUpFor(PopUpFor.all);
    expect(s.deliveryFor(serious: false, now: noon), AlertDelivery.normal);
    expect(s.deliveryFor(serious: false, now: night), AlertDelivery.silent);
    expect(s.deliveryFor(serious: true, now: night), AlertDelivery.normal);
    // None: nothing pops up.
    s.setPopUpFor(PopUpFor.none);
    expect(s.deliveryFor(serious: true, now: noon), AlertDelivery.none);
  });

  test('times are said the way people say them', () {
    expect(formatMinutes(0), '12 AM');
    expect(formatMinutes(12 * 60), '12 PM');
    expect(formatMinutes(6 * 60 + 5), '6:05 AM');
    expect(formatMinutes(22 * 60), '10 PM');
  });

  group('the mobile data rule', () {
    test('downloads are blocked on mobile data unless the switch is on, or the person says anyway', () async {
      final s = await open();
      final probe = FakeProbe(ConnectionKind.mobile);
      final p = DataPolicy(settings: s, probe: probe);
      expect(await p.blocksDownload(), isTrue);
      await expectLater(p.checkDownload(), throwsA(isA<MobileDataBlocked>()));
      await p.checkDownload(anyway: true);
      s.setMobileForDownloads(true);
      await p.checkDownload();
      s.setMobileForDownloads(false);
      probe.kind = ConnectionKind.wifi;
      await p.checkDownload();
      probe.kind = ConnectionKind.none;
      await p.checkDownload();
      probe.kind = ConnectionKind.other;
      await p.checkDownload();
    });

    test('the connection kinds from the system list', () {
      expect(ConnectivityProbe.kindOf([ConnectivityResult.wifi, ConnectivityResult.mobile]), ConnectionKind.wifi);
      expect(ConnectivityProbe.kindOf([ConnectivityResult.mobile]), ConnectionKind.mobile);
      expect(ConnectivityProbe.kindOf([ConnectivityResult.none]), ConnectionKind.none);
      expect(ConnectivityProbe.kindOf([ConnectivityResult.vpn]), ConnectionKind.other);
    });
  });

  test('sizes come from the files on disk', () async {
    final root = Directory('${dir.path}/tree')..createSync();
    File('${root.path}/a.bin').writeAsBytesSync(List.filled(1000, 1));
    Directory('${root.path}/sub/deeper').createSync(recursive: true);
    File('${root.path}/sub/b.bin').writeAsBytesSync(List.filled(2500, 1));
    File('${root.path}/sub/deeper/c.bin').writeAsBytesSync(List.filled(500, 1));
    expect(await directorySize(root), 4000);
    expect(await directorySize(Directory('${dir.path}/nothing')), 0);
    final leftovers = Directory('${dir.path}/partial')..createSync();
    File('${leftovers.path}/x.part').writeAsBytesSync(List.filled(300, 1));
    final u = StorageUsage(
      kinds: [
        DataKind(id: 'library', label: 'Library', icon: Icons.book, shared: () => {'library': root}, local: () => [null]),
        DataKind(id: 'regions', label: 'Regions', icon: Icons.map, shared: () => {'maps': Directory('${root.path}/sub')}),
        DataKind(id: 'models', label: 'Models', icon: Icons.memory),
        DataKind(id: 'videos', label: 'Videos', icon: Icons.movie, local: () => [Directory('${root.path}/sub/deeper')]),
      ],
      freeIn: () => dir,
      leftovers: () => [leftovers],
      freeSpace: (_) => 12345,
      totalSpace: (_) => 64 << 30,
    );
    await u.measure();
    expect(u.bytesOf('library'), 4000);
    expect(u.bytesOf('regions'), 3000);
    expect(u.bytesOf('models'), 0);
    expect(u.bytesOf('videos'), 500);
    expect(u.usedBytes, 7500);
    expect(u.freeBytes, 12345);
    expect(u.reserveBytes, (64 << 30) ~/ 10, reason: '10% of a 64 GB phone');
    // Clean up empties the leftover folders and nothing else.
    expect(u.cleanupBytes, 300);
    expect(await u.cleanUp(), 300);
    expect(leftovers.existsSync(), isTrue);
    expect(leftovers.listSync(), isEmpty);
    expect(await directorySize(root), 4000);
  });

  test('Clean up removes downloads that do not match their manifest (size or SHA-256), never a file without one', () async {
    final d = Directory('${dir.path}/packs')..createSync();
    File write(String name, List<int> bytes) => File('${d.path}/$name')..writeAsBytesSync(bytes);
    final good = write('good.sqlite', utf8.encode('pack'));
    final short = write('short.sqlite', utf8.encode('pac'));
    final wrong = write('wrong.sqlite', utf8.encode('pakc'));
    final mine = write('mine.sqlite', utf8.encode('saved by the person'));
    final sum = sha256Hex(utf8.encode('pack'));
    final manifests = [
      FileManifest(good.path, bytes: 4, sha256: sum),
      FileManifest(short.path, bytes: 4, sha256: sum),
      FileManifest(wrong.path, bytes: 4, sha256: sum),
      FileManifest('${d.path}/missing.sqlite', bytes: 4, sha256: sum),
    ];
    final u = StorageUsage(kinds: const [], freeIn: () => dir, manifests: () => manifests, freeSpace: (_) => 1, totalSpace: (_) => 1);
    await u.measure();
    // the size is known at once, the checksum soon after
    for (var i = 0; i < 100 && u.damagedFiles.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(u.damagedFiles.map((m) => m.path), [short.path, wrong.path]);
    expect(u.cleanupBytes, 7);
    expect(await u.cleanUp(), 7);
    expect([good.existsSync(), short.existsSync(), wrong.existsSync(), mine.existsSync()], [true, false, false, true]);
    expect(await DamagedFiles().find(manifests), isEmpty);
  });

  test('the space kept for the phone: 10% of storage, at least 5 GB, at most 20 GB', () {
    const gb = 1 << 30;
    expect(reserveFor(32 * gb), 5 * gb);
    expect(reserveFor(128 * gb), (128 * gb) ~/ 10);
    expect(reserveFor(512 * gb), 20 * gb);
    expect(reserveFor(null), 20 * gb, reason: 'unknown storage keeps the most');
    const s = Space(free: 30 * gb, reserve: 20 * gb);
    expect(s.usable, 10 * gb);
    expect(s.shortBy(4 * gb), 0);
    expect(s.shortBy(38 * gb), 28 * gb);
    expect(const Space(free: null, reserve: 5 * gb).shortBy(1 << 40), 0, reason: 'unknown free space does not block');
  });

  test('the version in the app is the version in pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim().split('+').first, kAppVersion);
    expect(kAppLicenceId, 'AGPL-3.0-or-later');
  });

  test('preferences.json holds no key', () async {
    final s = await open();
    s.setWebSearchOn(true);
    final text = File('${dir.path}/preferences.json').readAsStringSync();
    expect((jsonDecode(text) as Map).keys, isNot(contains('key')));
  });
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
