import 'dart:convert';
import 'dart:io';

import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:cache/version.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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

  test('the defaults: pop-ups on, quiet 10 PM to 6 AM, ring through on, updates on mobile data on, downloads off, web search off', () async {
    final s = await open();
    expect(s.alertPopups, isTrue);
    expect(s.quiet.on, isTrue);
    expect(s.quiet.label, '10 PM to 6 AM');
    expect(s.ringThroughExtreme, isTrue);
    expect(s.mobileForUpdates, isTrue);
    expect(s.mobileForDownloads, isFalse);
    expect(s.webSearchOn, isFalse);
  });

  test('every choice is saved and read back', () async {
    final s = await open();
    s.setAlertPopups(false);
    s.setQuiet(const QuietHours(on: true, from: 21 * 60 + 30, to: 7 * 60));
    s.setRingThroughExtreme(false);
    s.setMobileForUpdates(false);
    s.setMobileForDownloads(true);
    s.setWebSearchOn(true);
    final again = await open();
    expect(again.alertPopups, isFalse);
    expect(again.quiet.from, 21 * 60 + 30);
    expect(again.quiet.to, 7 * 60);
    expect(again.quiet.label, '9:30 PM to 7 AM');
    expect(again.ringThroughExtreme, isFalse);
    expect(again.mobileForUpdates, isFalse);
    expect(again.mobileForDownloads, isTrue);
    expect(again.webSearchOn, isTrue);
    again.setQuiet(again.quiet.copyWith(on: false));
    expect((await open()).quiet.on, isFalse);
  });

  test('a damaged file gives the defaults', () async {
    File('${dir.path}/preferences.json').writeAsStringSync('{not json');
    final s = await open();
    expect(s.mobileForDownloads, isFalse);
    expect(s.alertPopups, isTrue);
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
    expect(s.deliveryFor(extreme: false, now: noon), AlertDelivery.normal);
    expect(s.deliveryFor(extreme: false, now: night), AlertDelivery.silent);
    expect(s.deliveryFor(extreme: true, now: night), AlertDelivery.normal, reason: 'extreme alerts ring through');
    s.setRingThroughExtreme(false);
    expect(s.deliveryFor(extreme: true, now: night), AlertDelivery.silent);
    s.setAlertPopups(false);
    expect(s.deliveryFor(extreme: true, now: noon), AlertDelivery.none);
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

    test('updates follow their own switch', () async {
      final s = await open();
      final p = DataPolicy(settings: s, probe: FakeProbe(ConnectionKind.mobile));
      await p.checkUpdate();
      s.setMobileForUpdates(false);
      await expectLater(p.checkUpdate(), throwsA(isA<MobileDataBlocked>().having((e) => e.updates, 'updates', isTrue)));
      await p.checkUpdate(anyway: true);
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
    final u = StorageUsage(
      library: () => [root, null],
      maps: () => [Directory('${root.path}/sub')],
      models: () => [],
      videos: () => [Directory('${root.path}/sub/deeper')],
      freeIn: () => dir,
      freeSpace: (_) => 12345,
    );
    await u.measure();
    expect(u.libraryBytes, 4000);
    expect(u.mapsBytes, 3000);
    expect(u.modelsBytes, 0);
    expect(u.videosBytes, 500);
    expect(u.usedBytes, 7500);
    expect(u.freeBytes, 12345);
  });

  test('the version in the app is the version in pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim().split('+').first, kAppVersion);
    expect(kAppLicenceId, 'GPL-3.0-or-later');
  });

  test('preferences.json holds no key', () async {
    final s = await open();
    s.setWebSearchOn(true);
    final text = File('${dir.path}/preferences.json').readAsStringSync();
    expect((jsonDecode(text) as Map).keys, isNot(contains('key')));
  });
}
