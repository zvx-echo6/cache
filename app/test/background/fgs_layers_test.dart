// The foreground service also carries region map downloads (layer jobs) when the person leaves Cache: the coordinator arms for a
// running layer job as it does for a PDF add, tells Android the progress words, and the notification's Pause pauses the layer jobs.
// The service stays up while EITHER a PDF add or a layer job runs (the Kotlin side has its own tests: FgsAddTest.kt).

import 'dart:io';

import 'package:cache/background/fgs_add.dart';
import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/platform/battery.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_test/flutter_test.dart';

import '../add_pdf/add_pdf_fixtures.dart';

const _charging = BatteryReading(percent: 80, charging: true, thermal: Thermal.nominal);

class _Platform extends FgsPlatform {
  final List<bool> pdfArmed = [];
  final List<bool> layersArmed = [];
  final List<Map<String, Object?>> progress = [];

  @override
  Future<void> arm(bool on) async => pdfArmed.add(on);

  @override
  Future<void> armLayers(bool on) async => layersArmed.add(on);

  @override
  Future<void> layerProgress(Map<String, Object?> p) async => progress.add(p);

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<bool> requestNotifications() async => true;
}

void main() {
  group('the words for region downloads', () {
    test('one region: its name and the percent', () {
      final w = fgsLayerWords([const FgsLayerJob(id: 'a', label: 'Austria', done: 21, total: 50)]);
      expect(w.title, 'Downloading Austria');
      expect(w.text, '42%');
      expect(w.bar, closeTo(0.42, 1e-9));
    });

    test('several: how many, and the share of all their tiles together', () {
      final w = fgsLayerWords([
        const FgsLayerJob(id: 'a', label: 'Austria', done: 10, total: 100),
        const FgsLayerJob(id: 'b', label: 'Idaho', done: 30, total: 100),
      ]);
      expect(w.title, 'Downloading 2 regions');
      expect(w.text, '20%');
      expect(w.bar, closeTo(0.2, 1e-9));
    });

    test('the total is not known yet: no percent, the bar is indeterminate (null), the bytes are said when known', () {
      final w = fgsLayerWords([const FgsLayerJob(id: 'a', label: 'Austria', done: 0, total: 0)]);
      expect(w.title, 'Downloading Austria');
      expect(w.text, isNull);
      expect(w.bar, isNull);
      final b = fgsLayerWords([const FgsLayerJob(id: 'a', label: 'Austria', done: 0, total: 0, bytes: 5 * 1024 * 1024)]);
      expect(b.text, '5.0 MB');
    });

    test('never over 100%', () {
      expect(fgsLayerWords([const FgsLayerJob(id: 'a', label: 'X', done: 9, total: 5)]).text, '100%');
    });

    test('it goes over the channel as plain data', () {
      expect(fgsLayerWords([const FgsLayerJob(id: 'a', label: 'Austria', done: 1, total: 4)]).toJson(), {'title': 'Downloading Austria', 'text': '25%', 'bar': 0.25, 'count': 1});
    });
  });

  group('the coordinator and region downloads', () {
    late Directory tmp;
    late _Platform platform;
    var layers = <FgsLayerJob>[];
    var pdfs = <AddPdfJob>[];
    var paused = 0;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fgs_layers');
      platform = _Platform();
      layers = [];
      pdfs = [];
      paused = 0;
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    FgsAddCoordinator make({bool android = true}) => FgsAddCoordinator(
      platform: platform,
      jobs: () => pdfs,
      layerJobs: () => layers,
      onLayerPause: () async => paused++,
      battery: () async => _charging,
      askedFile: () => File('${tmp.path}/asked'),
      android: android,
      sdk: 30,
    );

    test('a running layer job arms the service, and says its progress', () async {
      final c = make();
      layers = [const FgsLayerJob(id: 'a', label: 'Austria', done: 10, total: 100)];
      await c.update();
      expect(platform.layersArmed, [true]);
      expect(c.layersArmed, isTrue);
      expect(platform.pdfArmed, isEmpty);
      expect(platform.progress.single['title'], 'Downloading Austria');
      expect(platform.progress.single['text'], '10%');
    });

    test('progress goes on while it runs, and arms only once', () async {
      final c = make();
      layers = [const FgsLayerJob(id: 'a', label: 'Austria', done: 10, total: 100)];
      await c.update();
      layers = [const FgsLayerJob(id: 'a', label: 'Austria', done: 60, total: 100)];
      await c.update();
      expect(platform.layersArmed, [true]);
      expect(platform.progress.map((p) => p['text']), ['10%', '60%']);
    });

    test('it disarms when the last layer job ends', () async {
      final c = make();
      layers = [const FgsLayerJob(id: 'a', label: 'Austria', done: 10, total: 100)];
      await c.update();
      layers = [];
      await c.update();
      expect(platform.layersArmed, [true, false]);
      expect(c.layersArmed, isFalse);
    });

    test('nothing running: nothing is armed and nothing is said', () async {
      await make().update();
      expect(platform.layersArmed, isEmpty);
      expect(platform.progress, isEmpty);
    });

    test('never off Android', () async {
      layers = [const FgsLayerJob(id: 'a', label: 'Austria', done: 1, total: 4)];
      await make(android: false).update();
      expect(platform.layersArmed, isEmpty);
    });

    test('both orders: PDF adds and layer jobs arm on their own, and each disarms on its own', () async {
      // a region starts during a PDF add
      final c = make();
      pdfs = [sampleJob('a')];
      await c.update();
      expect(c.armed, isTrue);
      expect(c.layersArmed, isFalse);
      layers = [const FgsLayerJob(id: 'r', label: 'Austria', done: 1, total: 10)];
      await c.update();
      expect(c.armed, isTrue);
      expect(c.layersArmed, isTrue);
      // the PDF add ends first: the region stays armed
      pdfs = [];
      await c.update();
      expect(platform.pdfArmed, [true, false]);
      expect(c.layersArmed, isTrue);
      expect(platform.layersArmed, [true]);

      // a PDF add starts during a region
      pdfs = [sampleJob('b')];
      await c.update();
      expect(platform.pdfArmed, [true, false, true]);
      expect(c.layersArmed, isTrue);
      // the region ends first: the PDF add stays armed
      layers = [];
      await c.update();
      expect(platform.layersArmed, [true, false]);
      expect(c.armed, isTrue);
    });

    test("the notification's Pause (layerPause from Android) pauses the layer jobs", () async {
      final c = make();
      expect(await c.handleCall(const MethodCall('layerPause')), isNull);
      expect(paused, 1);
      expect(await c.handleCall(const MethodCall('layerCancel')), isNull);
      expect(paused, 1, reason: 'there is no Cancel in the notification');
    });
  });
}
