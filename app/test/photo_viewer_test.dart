import 'dart:async';
import 'dart:io';

import 'package:cache/screens/notebooks/photo_viewer.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _jpg(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(90, 140, 200));
  img.fillRect(im, x1: 0, y1: h ~/ 2, x2: w, y2: h, color: img.ColorRgb8(40, 90, 50));
  return img.encodeJpg(im, quality: 80);
}

late Directory _dir;
Future<File> _file(String id) async => File('${_dir.path}/$id.jpg');

/// Decodes the pictures on the real clock before the screen is built, so it finds them in the image cache.
Future<void> _warm(WidgetTester tester, List<String> ids) async {
  await tester.runAsync(() async {
    for (final id in ids) {
      final c = Completer<void>();
      final stream = FileImage(await _file(id)).resolve(ImageConfiguration.empty);
      final l = ImageStreamListener((_, _) => c.isCompleted ? null : c.complete(), onError: (e, _) => c.isCompleted ? null : c.complete());
      stream.addListener(l);
      await c.future.timeout(const Duration(seconds: 20));
      stream.removeListener(l);
    }
  });
}

Matrix4 _matrix(WidgetTester tester) => tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).transformationController!.value;

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('photo-viewer-test');
    File('${_dir.path}/big.jpg').writeAsBytesSync(_jpg(4000, 3000));
    File('${_dir.path}/small.jpg').writeAsBytesSync(_jpg(500, 375));
    File('${_dir.path}/two.jpg').writeAsBytesSync(_jpg(800, 600));
  });
  tearDownAll(() => _dir.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, List<String> ids) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _warm(tester, ids);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: PhotoViewer(ids: ids, fileFor: _file)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  test('the size of a JPEG or PNG is read from its first bytes', () {
    expect(imageFileSize(_jpg(4000, 3000)), const Size(4000, 3000));
    expect(imageFileSize(_jpg(375, 500)), const Size(375, 500));
    expect(imageFileSize(Uint8List.fromList([1, 2, 3, 4, 5, 6])), isNull);
  });

  test('zoom limits: at least 4x and at least the photo\'s own pixels; double-tap 2.5x or own pixels if smaller', () {
    final big = photoZoomLimits(const Size(4000, 3000), const Size(390, 844));
    expect(big.max, closeTo(4000 / 390, 0.01));
    expect(big.tap, 2.5);
    final small = photoZoomLimits(const Size(500, 375), const Size(390, 844));
    expect(small.max, 4);
    expect(small.tap, closeTo(500 / 390, 0.5), reason: 'never under 1.5');
    expect(small.tap, greaterThanOrEqualTo(1.5));
    // Landscape: the width is the limit of the fit in the other axis.
    final wide = photoZoomLimits(const Size(4000, 3000), const Size(844, 390));
    expect(wide.max, closeTo(4000 / (390 * 4 / 3), 0.01));
  });

  testWidgets('a 4000 px photo can be pinched to its own pixels', (tester) async {
    await open(tester, ['big']);
    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first);
    expect(iv.maxScale, closeTo(4000 / 390, 0.01));
    expect(iv.minScale, 1);
  });

  testWidgets('a photo with a preview shows the preview, and loads the full file when zoomed', (tester) async {
    File('${_dir.path}/big-preview.jpg').writeAsBytesSync(_jpg(1600, 1200));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _warm(tester, ['big', 'big-preview']);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: PhotoViewer(ids: const ['big'], fileFor: _file, previewFor: (id) => _file('$id-preview')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 1600);
    // The zoom limit is the full photo's, known before it is loaded.
    expect(tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).maxScale, closeTo(4000 / 390, 0.01));
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 4000);
  });

  testWidgets('a small photo still zooms to 4x', (tester) async {
    await open(tester, ['small']);
    expect(tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).maxScale, 4);
  });

  testWidgets('double-tap toggles between fit and 2.5x centred on the tap, and back', (tester) async {
    await open(tester, ['big']);
    expect(find.byType(RawImage), findsOneWidget, reason: 'the photo is drawn');
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
    const at = Offset(120, 400);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    final m = _matrix(tester);
    expect(m.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
    // The tapped spot is in the middle of the screen across (the photo is wider than the screen at 2.5x); up and down the photo, no
    // taller than the screen at 2.5x, stays centred.
    expect(MatrixUtils.transformPoint(m, at).dx, closeTo(195, 1));
    expect(MatrixUtils.transformPoint(m, const Offset(195, 422)).dy, closeTo(422, 1));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
  });

  testWidgets('a drag at fit is the swipe to the next photo', (tester) async {
    await open(tester, ['two', 'small']);
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.fling(find.byKey(const ValueKey('photo-pages')), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('every orientation is allowed while the viewer is open, and the choice is given back on close', (tester) async {
    final calls = <List<dynamic>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(List<dynamic>.from(call.arguments as List));
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _warm(tester, ['two']);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Builder(builder: (c) => TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => PhotoViewer(ids: const ['two'], fileFor: _file))), child: const Text('open'))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(calls.last.toSet(), {'DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown', 'DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'});
    await tester.tap(find.byKey(const ValueKey('photo-close')));
    await tester.pumpAndSettle();
    expect(calls.last, isEmpty, reason: 'no preference of its own: the system\'s choice is back');
  });
}
