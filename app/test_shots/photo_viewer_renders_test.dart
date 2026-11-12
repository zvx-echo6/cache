// The photo viewer for review (feat/photo-viewer): the viewer on a photo, zoomed in, on the second of three photos, with its
// share or save menu, and an entry whose thumbnails open it. Sample photos are generated here (landscapes drawn from shapes and
// gradients; no real pictures). 390 and 1440 wide, light, dark and Tactical.
// flutter test test_shots/photo_viewer_renders_test.dart --update-goldens  (pictures in test_shots/photo_viewer/)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/entry_editor.dart';
import 'package:cache/screens/notebooks/photo_viewer.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../test/support/notebook_fake.dart';
import 'shot_kit.dart';

const _out = 'photo_viewer';

/// A generic landscape: a sky gradient, a sun, two ridges and a lake. [seed] changes the colours.
Uint8List _photo(int seed, {int w = 1600, int h = 1200}) {
  final skies = [
    ((250, 190, 120), (90, 140, 210)),
    ((240, 120, 100), (60, 70, 140)),
    ((170, 215, 235), (70, 130, 190)),
  ][seed % 3];
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    for (var x = 0; x < w; x++) {
      final a = skies.$1, b = skies.$2;
      im.setPixelRgb(x, y, (a.$1 + (b.$1 - a.$1) * (1 - t)).round(), (a.$2 + (b.$2 - a.$2) * (1 - t)).round(), (a.$3 + (b.$3 - a.$3) * (1 - t)).round());
    }
  }
  img.fillCircle(im, x: (w * (0.25 + 0.2 * seed)).round(), y: (h * 0.3).round(), radius: (h * 0.09).round(), color: img.ColorRgb8(255, 240, 200));
  for (var layer = 0; layer < 2; layer++) {
    final base = h * (0.55 + 0.1 * layer);
    final shade = layer == 0 ? 90 : 55;
    for (var x = 0; x < w; x++) {
      final top = base - math.sin(x / w * math.pi * (2 + seed + layer)) * h * 0.1 - math.sin(x / 90.0 + layer) * 8;
      for (var y = top.round(); y < h; y++) {
        im.setPixelRgb(x, y, shade - 20, shade + 25, shade - 10 + layer * 10);
      }
    }
  }
  for (var y = (h * 0.82).round(); y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, 60 + (y - h * 0.82) ~/ 6, 110 + (y - h * 0.82) ~/ 8, 150);
    }
  }
  // A few marks so zooming in shows detail.
  for (var i = 0; i < 40; i++) {
    img.drawCircle(im, x: (w * ((i * 37) % 100) / 100).round(), y: (h * (0.58 + ((i * 17) % 20) / 100)).round(), radius: 6 + i % 5, color: img.ColorRgb8(30, 70, 40));
  }
  // Fine detail, to show a zoom to the photo's own pixels: one-pixel lines near the sun.
  if (w >= 2400) {
    for (var y = (h * 0.30).round(); y < (h * 0.30).round() + 160; y++) {
      for (var x = (w * 0.30).round(); x < (w * 0.30).round() + 240; x++) {
        if ((x + y) % 4 == 0) im.setPixelRgb(x, y, 20, 40, 70);
      }
    }
  }
  return img.encodeJpg(im, quality: 88);
}

late NotebookState _nb;
late List<String> _ids;

/// Decodes the pictures on the real clock before the screen is built (a load that starts inside a test's own clock is never
/// finished by the engine), so the screen finds them in the image cache.
Future<void> _warm(WidgetTester tester, [List<String>? ids]) async {
  ids ??= _ids;
  await tester.runAsync(() async {
    final files = [for (final id in ids!) await _nb.thumbFile(id), for (final id in ids) await _nb.photoFile(id)];
    for (final f in files) {
      final c = Completer<void>();
      final stream = FileImage(f).resolve(ImageConfiguration.empty);
      final l = ImageStreamListener((_, _) {
        if (!c.isCompleted) c.complete();
      }, onError: (e, _) {
        if (!c.isCompleted) c.complete();
      });
      stream.addListener(l);
      await c.future.timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('picture did not load: ${f.path}'));
      stream.removeListener(l);
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  setUp(() async {
    _nb = fakeNotebook(FakeNotebookBackend());
    final dir = Directory('${Directory.systemTemp.path}/cache-notebook-test-media');
    await Directory('${dir.path}/photos').create(recursive: true);
    await Directory('${dir.path}/thumbs').create(recursive: true);
    _ids = ['p-sample-1', 'p-sample-2', 'p-sample-3'];
    final wide = _photo(1, w: 2400, h: 1200);
    File('${dir.path}/photos/p-wide.jpg').writeAsBytesSync(wide);
    File('${dir.path}/thumbs/p-wide.jpg').writeAsBytesSync(img.encodeJpg(img.copyResize(img.decodeJpg(wide)!, width: 256), quality: 80));
    for (var i = 0; i < 3; i++) {
      final full = _photo(i);
      File('${dir.path}/photos/${_ids[i]}.jpg').writeAsBytesSync(full);
      final t = img.copyResize(img.decodeJpg(full)!, width: 256);
      File('${dir.path}/thumbs/${_ids[i]}.jpg').writeAsBytesSync(img.encodeJpg(t, quality: 80));
    }
  });

  final sizes = [('390', const Size(390, 844), 2.0), ('1440', const Size(1440, 900), 1.0)];
  for (final (label, size, ratio) in sizes) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark, CacheThemeId.tactical]) {
      final tag = '$label-${theme.name}';
      Widget viewer(int i) => shotApp(PhotoViewer(ids: _ids, initialIndex: i, fileFor: _nb.photoFile), theme: theme, insets: EdgeInsets.only(top: label == '390' ? 54 : 0, bottom: label == '390' ? 34 : 0));

      testWidgets('viewer, photo 1 of 3, $tag', (tester) async {
        phone(tester, size: size, ratio: ratio);
        await _warm(tester);
        await tester.pumpWidget(viewer(0));
        await _settle(tester);
        await snap(tester, _out, '$tag-viewer');
      });

      testWidgets('viewer zoomed, $tag', (tester) async {
        phone(tester, size: size, ratio: ratio);
        await _warm(tester);
        await tester.pumpWidget(viewer(0));
        await _settle(tester);
        final at = Offset(size.width * 0.28, size.height * 0.32);
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 100));
        await snap(tester, _out, '$tag-viewer-zoomed');
      });

      testWidgets('viewer, photo 2 of 3, $tag', (tester) async {
        phone(tester, size: size, ratio: ratio);
        await _warm(tester);
        await tester.pumpWidget(viewer(1));
        await _settle(tester);
        await snap(tester, _out, '$tag-viewer-page-2-of-3');
      });

      testWidgets('viewer share or save menu, $tag', (tester) async {
        phone(tester, size: size, ratio: ratio);
        await _warm(tester);
        await tester.pumpWidget(viewer(0));
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('photo-menu')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Save to device'), findsOneWidget);
        await snap(tester, _out, '$tag-viewer-menu');
      });

      testWidgets('entry with thumbnails, $tag', (tester) async {
        phone(tester, size: size, ratio: ratio);
        late Notebook book;
        late NbEntry e;
        await tester.runAsync(() async {
          await _nb.start();
          book = _nb.journal!;
          e = await _nb.saveEntry(
            notebookId: book.id,
            occurredAt: '2026-11-09T09:30:00-07:00',
            title: 'Dry Creek loop',
            body: 'Water was running at the second crossing. Snow above 6,500 feet.',
            photos: [for (final id in _ids) NbPhoto(id: id, width: 1600, height: 1200, bytes: 90000)],
          );
        });
        await _warm(tester);
        await tester.pumpWidget(shotApp(
          EntryEditor(notebook: _nb, book: book, places: PlaceChoices.none, entry: e, now: () => DateTime(2026, 11, 9, 10)),
          theme: theme,
          insets: EdgeInsets.only(top: label == '390' ? 54 : 0, bottom: label == '390' ? 34 : 0),
        ));
        await _settle(tester);
        await snap(tester, _out, '$tag-entry-thumbnails');
      });
    }
  }

  // The viewer turned sideways (a wide photo fills the screen) and zoomed to the photo's own pixels. Light and Tactical.
  for (final theme in [CacheThemeId.light, CacheThemeId.tactical]) {
    for (final (label, size) in [('390', const Size(390, 844)), ('844x390', const Size(844, 390))]) {
      final tag = '$label-${theme.name}';
      Widget wideViewer() => shotApp(PhotoViewer(ids: const ['p-wide'], fileFor: _nb.photoFile), theme: theme, insets: label == '390' ? const EdgeInsets.only(top: 54, bottom: 34) : EdgeInsets.zero);

      testWidgets('wide photo, $tag', (tester) async {
        phone(tester, size: size, ratio: 2);
        await _warm(tester, ['p-wide']);
        await tester.pumpWidget(wideViewer());
        await _settle(tester);
        await snap(tester, _out, '$tag-viewer-wide');
      });

      testWidgets('zoomed to the photo\'s own pixels, $tag', (tester) async {
        phone(tester, size: size, ratio: 2);
        await _warm(tester, ['p-wide']);
        await tester.pumpWidget(wideViewer());
        await _settle(tester);
        final lim = photoZoomLimits(const Size(2400, 1200), size);
        final c = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first).transformationController!;
        // The fine lines near the sun in the middle of the screen, at the largest zoom.
        final p = Offset(lim.fit.left + lim.fit.width * 0.35, lim.fit.top + lim.fit.height * 0.38);
        final s = lim.max;
        c.value = Matrix4.identity()
          ..translateByDouble(size.width / 2 - s * p.dx, size.height / 2 - s * p.dy, 0, 1)
          ..scaleByDouble(s, s, 1, 1);
        await _settle(tester);
        await snap(tester, _out, '$tag-viewer-actual-pixels');
      });
    }
  }
}
