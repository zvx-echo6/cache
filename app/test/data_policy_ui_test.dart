import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/opds.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'video_fake.dart';

void main() {
  group('a download on mobile data is blocked until the person says "Download anyway"', () {
    testWidgets('map areas: updating a downloaded area is blocked too, with the same way out', (tester) async {
      final r = await SettingsRig.create(tester, connection: ConnectionKind.wifi);
      final def = r.maps.catalogueLayers.firstWhere((l) => l.id == 'hillshade');
      final area = await tester.runAsync(() => r.engine.download(def.id, const GeoBounds(south: 42.5, west: -113.8, north: 42.6, east: -113.66), label: 'Home'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      expect(area!.phase, AreaPhase.done);
      r.probe.kind = ConnectionKind.mobile;
      await expectLater(r.engine.update(area.id), throwsA(isA<MobileDataBlocked>()));
      await r.engine.update(area.id, anyway: true);
      r.settings.setMobileForDownloads(true);
      await r.engine.update(area.id);
      await tester.pump(const Duration(milliseconds: 100));
      await r.dispose(tester);
    });

    testWidgets('videos: the task is held with a Download anyway, and a Wi-Fi connection or the switch lets it through', (tester) async {
      final r = await SettingsRig.create(tester, connection: ConnectionKind.mobile);
      final v = r.video;
      final i = await tester.runAsync(() => v.addInstance('tube.example.org'));
      final d = await tester.runAsync(() => v.details(i!.id, VideoFakeNative.uuid));
      final task = (await tester.runAsync(() => v.download(d!, d.options[1])))!;
      expect(task.phase, DownloadPhase.failed);
      expect(task.blockedByMobile, isTrue);
      expect(task.error, contains('mobile data downloads are off'));
      expect(task.job, isNull, reason: 'nothing was started');
      await tester.runAsync(() => v.retry(task, anyway: true));
      expect(task.phase, DownloadPhase.running);
      expect(task.blockedByMobile, isFalse);
      expect(task.job, isNotNull);
      await tester.runAsync(v.pollOnce);
      await tester.runAsync(v.pollOnce);
      expect(task.phase, DownloadPhase.done);
      // On Wi-Fi nothing is held.
      r.probe.kind = ConnectionKind.wifi;
      final again = (await tester.runAsync(() => v.download(d!, d.options[0])))!;
      expect(again.blockedByMobile, isFalse);
      expect(again.phase, DownloadPhase.running);
      await r.dispose(tester);
    });

    testWidgets('Library: a download waiting for Wi-Fi says so, offers Download now, and starts by itself on Wi-Fi', (tester) async {
      final r = await SettingsRig.create(tester, connection: ConnectionKind.mobile);
      final entry = _entry();
      await tester.runAsync(() => r.browse.download(entry));
      expect(r.browse.transfers[entry.id]!.phase, TransferPhase.blockedByMobileData);
      await r.show(tester, BrowseScreen(browse: r.browse, active: true));
      expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
      expect(find.byKey(const ValueKey('download-now')), findsOneWidget);
      // Wi-Fi comes: it starts without being asked.
      r.probe.change(ConnectionKind.wifi);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(r.browse.transfers[entry.id]?.phase, isNot(TransferPhase.blockedByMobileData));
      await r.dispose(tester);
    });
  });
}

CatalogEntry _entry() => CatalogEntry(
  id: 'e-1',
  title: 'Wikivoyage - Europe',
  summary: '',
  language: 'eng',
  name: 'wikivoyage_en_europe',
  flavour: 'nopic',
  category: 'wikivoyage',
  tags: const [],
  updated: '2026-09-14',
  size: 1000,
  articleCount: 1,
  downloadUrl: Uri.parse('http://127.0.0.1:9/zim/x.zim'),
  iconUrl: null,
);
