// Free space: screens show free now, pre-checks use the allowance (free now plus half of the purgeable space on iPhone) less the
// reserve, the sync engine starts with the same reserve Storage shows. (A full disk stopping a download is in browse/zim_download_test.dart.)

import 'dart:io';

import 'package:cache/discover/ui/kit.dart';
import 'package:cache/settings/space.dart';
import 'package:cache/settings/storage_usage.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

const _gb = 1 << 30;

void main() {
  group('the pre-check allowance', () {
    test('Space.of keeps free now for the screens and the allowance for the checks', () {
      // iPhone: 10 GB free now, 30 GB with everything iOS could purge; the native rule gives 10 + (30 - 10) / 2 = 20 GB.
      final s = Space.of('x', freeSpace: (_) => 10 * _gb, allowedSpace: (_) => 20 * _gb, totalSpace: (_) => 128 * _gb);
      expect(s.free, 10 * _gb, reason: 'what is shown');
      expect(s.allowed, 20 * _gb);
      expect(s.reserve, reserveFor(128 * _gb));
      expect(s.usable, 20 * _gb - reserveFor(128 * _gb), reason: 'the reserve comes off the allowance');
      expect(s.shortBy(5 * _gb), 0);
      expect(s.shortBy(10 * _gb), 10 * _gb - s.usable!, reason: 'short by what the allowance less the reserve cannot hold');
    });

    test('with no allowance given the allowance is free now (Android, Linux)', () {
      final s = Space.of('x', freeSpace: (_) => 30 * _gb, totalSpace: (_) => 128 * _gb);
      expect(s.allowed, 30 * _gb);
      expect(const Space(free: 30 * _gb, reserve: 20 * _gb).usable, 10 * _gb);
      expect(const Space(free: 30 * _gb, allowed: 40 * _gb, reserve: 20 * _gb).usable, 20 * _gb);
      expect(const Space(free: null, reserve: 5 * _gb).usable, isNull);
    });
  });

  group('screens show free now', () {
    testWidgets('the space line shows free now and checks the size against what may be used', (tester) async {
      Widget line(int bytes) => MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: Scaffold(body: SpaceLine(label: (s) => 'Adds $s', bytes: bytes, free: 10 * _gb, usable: 4 * _gb)),
      );
      await tester.pumpWidget(line(3 * _gb));
      expect(find.text('10.0 GB free'), findsOneWidget, reason: 'free now, not the allowance');
      await tester.pumpWidget(line(6 * _gb));
      expect(find.text('Needs 2.0 GB more'), findsOneWidget, reason: '6 GB against the 4 GB that may be used');
    });

    test('Storage reads free now', () {
      final u = StorageUsage(
        kinds: const [],
        freeIn: () => Directory.systemTemp,
        freeSpace: (_) => 12345,
        totalSpace: (_) => 64 * _gb,
      );
      u.readFree();
      expect(u.freeBytes, 12345);
      expect(u.reserveBytes, reserveFor(64 * _gb));
    });
  });

  testWidgets('sharing starts the engine with the reserve Storage shows', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('reserve'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    final configs = <Map<String, Object?>>[];
    final sync = FakeSync();
    final sharing = SharingState(
      policy: testPolicy(wifi: true),
      supportDir: () async => dir!,
      kinds: const [],
      opener: (c) async {
        configs.add(c);
        return sync;
      },
      reserveBytes: (d) {
        expect(d, dir!.path);
        return reserveFor(64 * _gb);
      },
    );
    await tester.runAsync(sharing.setUp);
    expect(configs.single['reserve_bytes'], reserveFor(64 * _gb));
    expect(configs.single['reserve_bytes'], isNot(1 << 30), reason: 'not the engine default of 1 GiB');
    sharing.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
