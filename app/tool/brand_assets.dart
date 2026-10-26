// Builds every generated brand asset from the source artwork in ../assets/brand/source.
//
//   cd app && dart run tool/brand_assets.dart            # writes the app icons, splash, wordmarks and tiles
//   cd app && dart run tool/brand_assets.dart --preview build/brand_preview.png   # also renders a contact sheet
//
// The source art sits on flat #00FF00 (02, 03 and 04 fill the frame and are not keyed). It is chroma-keyed
// with a soft edge and green despill, trimmed to its content, then scaled. Re-running gives the same files.
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

final srcDir = Directory('../assets/brand/source');
const res = 'android/app/src/main/res';
const brandOut = 'assets/brand';

// Android density buckets (scale relative to mdpi).
const densities = <String, double>{'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4};

const tileNames = <String, String>{
  'library': '07_library',
  'maps': '08_maps',
  'videos': '09_videos',
  'games': '10_games',
  'journal': '11_journal',
  'tools': '12_tools',
  'weather': '13_weather',
  'alerts': '14_alerts',
  'shortcuts': '15_shortcuts',
  'routes': '16_routes',
  'chat': '17_chat',
  'settings': '18_settings',
  'home': '19_home_a', // 19_home_b is kept in the record only
  'ask': '20_ask',
};

img.Image load(String name) {
  final f = File('${srcDir.path}/$name.png');
  if (!f.existsSync()) throw StateError('missing source ${f.path}');
  final d = img.decodePng(f.readAsBytesSync());
  if (d == null) throw StateError('cannot decode ${f.path}');
  return d.convert(format: img.Format.uint8, numChannels: 4);
}

/// Chroma key: alpha from greenness (g - max(r,b)), ramped 60..180, with despill on the edge pixels.
img.Image key(img.Image src) {
  final out = img.Image.from(src);
  for (final p in out) {
    final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
    final m = math.max(r, b);
    final gn = g - m;
    final t = ((gn - 60) / 120).clamp(0.0, 1.0);
    final a = 1 - t * t * (3 - 2 * t);
    if (gn > 36) p.g = m; // despill: g = min(g, max(r, b)) on edge pixels
    p.a = (p.a * a).round();
  }
  return out;
}

/// Crops to the visible content plus a small margin.
img.Image trim(img.Image src) {
  var x0 = src.width, y0 = src.height, x1 = -1, y1 = -1;
  for (final p in src) {
    if (p.a > 12) {
      if (p.x < x0) x0 = p.x;
      if (p.x > x1) x1 = p.x;
      if (p.y < y0) y0 = p.y;
      if (p.y > y1) y1 = p.y;
    }
  }
  if (x1 < 0) return src;
  final margin = (math.max(x1 - x0, y1 - y0) * 0.02).round();
  x0 = math.max(0, x0 - margin);
  y0 = math.max(0, y0 - margin);
  x1 = math.min(src.width - 1, x1 + margin);
  y1 = math.min(src.height - 1, y1 + margin);
  return img.copyCrop(src, x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1);
}

img.Image keyed(String name) => trim(key(load(name)));

/// Scales to fit inside [maxW] x [maxH] (keeping the aspect), in premultiplied alpha so edges do not pick up halos.
img.Image fit(img.Image src, int maxW, int maxH) {
  final scale = math.min(maxW / src.width, maxH / src.height);
  final w = math.max(1, (src.width * scale).round());
  final h = math.max(1, (src.height * scale).round());
  final pm = img.Image.from(src);
  for (final p in pm) {
    final a = p.a.toInt();
    p.r = (p.r * a / 255).round();
    p.g = (p.g * a / 255).round();
    p.b = (p.b * a / 255).round();
  }
  final rs = img.copyResize(pm,
      width: w, height: h, interpolation: scale < 1 ? img.Interpolation.average : img.Interpolation.cubic);
  for (final p in rs) {
    final a = p.a.toInt();
    if (a > 0 && a < 255) {
      p.r = (p.r * 255 / a).round().clamp(0, 255);
      p.g = (p.g * 255 / a).round().clamp(0, 255);
      p.b = (p.b * 255 / a).round().clamp(0, 255);
    }
  }
  return rs;
}

img.Image blank(int w, int h) => img.Image(width: w, height: h, numChannels: 4);

/// A square layer of [size] px with [content] fitted into the middle [fraction] of it.
img.Image placed(img.Image content, int size, double fraction) {
  final box = (size * fraction).round();
  final f = fit(content, box, box);
  final c = blank(size, size);
  img.compositeImage(c, f, dstX: (size - f.width) ~/ 2, dstY: (size - f.height) ~/ 2);
  return c;
}

/// A single-colour silhouette of the art's alpha.
img.Image silhouette(img.Image src, {int r = 255, int g = 255, int b = 255}) {
  final out = img.Image.from(src);
  for (final p in out) {
    p.r = r;
    p.g = g;
    p.b = b;
  }
  return out;
}

img.Image scaleOpaque(img.Image src, int size) =>
    img.copyResize(src, width: size, height: size, interpolation: img.Interpolation.average);

img.Image circleMask(img.Image src) {
  final out = img.Image.from(src);
  final c = src.width / 2;
  for (final p in out) {
    final d = math.sqrt(math.pow(p.x + .5 - c, 2) + math.pow(p.y + .5 - c, 2));
    p.a = (p.a * (c - d + .5).clamp(0.0, 1.0)).round();
  }
  return out;
}

img.Image roundedMask(img.Image src, double radiusFraction) {
  final out = img.Image.from(src);
  final w = src.width.toDouble();
  final rad = w * radiusFraction;
  for (final p in out) {
    final dx = math.max(0.0, math.max(rad - (p.x + .5), (p.x + .5) - (w - rad)));
    final dy = math.max(0.0, math.max(rad - (p.y + .5), (p.y + .5) - (w - rad)));
    final d = math.sqrt(dx * dx + dy * dy);
    p.a = (p.a * (rad - d + .5).clamp(0.0, 1.0)).round();
  }
  return out;
}

int written = 0;
void save(String path, List<int> bytes) {
  final f = File(path)..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  written++;
}

void savePng(String path, img.Image im) => save(path, img.encodePng(im, level: 9));

void main(List<String> args) {
  final logo = keyed('01_logo');
  final background = load('03_icon_background');
  final charcoal = img.ColorRgba8(0x1A, 0x1D, 0x1F, 255);

  // --- Android adaptive icon (108 dp layers; the logo sits inside the 66 dp safe zone) ---
  const safe = 66 / 108;
  for (final e in densities.entries) {
    final d = e.key;
    final layer = (108 * e.value).round();
    final bg = scaleOpaque(background, layer);
    final fg = placed(logo, layer, safe);
    final mono = placed(silhouette(logo), layer, safe);
    savePng('$res/mipmap-$d/ic_launcher_background.png', bg);
    savePng('$res/mipmap-$d/ic_launcher_foreground.png', fg);
    savePng('$res/mipmap-$d/ic_launcher_monochrome.png', mono);

    // Legacy icons: the same two layers, the central 72 dp (what a launcher shows) at 48 dp.
    final big = 432;
    final comp = scaleOpaque(background, big);
    img.compositeImage(comp, placed(logo, big, safe));
    final crop = img.copyCrop(comp, x: 72, y: 72, width: 288, height: 288);
    final legacy = (48 * e.value).round();
    final sq = scaleOpaque(crop, legacy);
    savePng('$res/mipmap-$d/ic_launcher.png', sq);
    savePng('$res/mipmap-$d/ic_launcher_round.png', circleMask(img.Image.from(sq)));

    // --- notification small icon: white silhouette, 24 dp ---
    final n = (24 * e.value).round();
    savePng('$res/drawable-$d/ic_stat_cache.png', placed(silhouette(logo), n, 0.92));

    // --- Android 12+ splash icon (288 dp canvas, logo in the middle, inside the 192 dp circle) ---
    final s = (288 * e.value).round();
    savePng('$res/drawable-$d/splash_logo.png', placed(logo, s, 128 / 288));
  }

  // --- iOS: AppIcon set (01 over 03, no alpha) and the launch logo ---
  final iosIcons = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final contents = File('$iosIcons/Contents.json').readAsStringSync();
  final iosMaster = scaleOpaque(background, 1024);
  img.compositeImage(iosMaster, placed(logo, 1024, 0.74));
  final flat = iosMaster.convert(numChannels: 3);
  var iosCount = 0;
  for (final obj in RegExp(r'\{[^{}]*\}').allMatches(contents)) {
    final t = obj.group(0)!;
    final fn = RegExp(r'"filename"\s*:\s*"([^"]+)"').firstMatch(t)?.group(1);
    final sz = RegExp(r'"size"\s*:\s*"([\d.]+)x').firstMatch(t)?.group(1);
    final sc = RegExp(r'"scale"\s*:\s*"(\d)x"').firstMatch(t)?.group(1);
    if (fn == null || sz == null || sc == null) continue;
    final px = (double.parse(sz) * int.parse(sc)).round();
    savePng('$iosIcons/$fn', px == 1024 ? flat : img.copyResize(flat, width: px, height: px, interpolation: img.Interpolation.average));
    iosCount++;
  }
  const launch = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
  savePng('$launch/LaunchImage.png', placed(logo, 168, 1));
  savePng('$launch/LaunchImage@2x.png', placed(logo, 336, 1));
  savePng('$launch/LaunchImage@3x.png', placed(logo, 504, 1));

  // --- in-app assets ---
  final fitted512 = fit(logo, 512, 512);
  savePng('$brandOut/logo.png', fitted512);
  final wmParchment = keyed('05_wordmark_parchment');
  final wmCharcoal = keyed('06_wordmark_charcoal');
  savePng('$brandOut/wordmark_parchment.png', fit(wmParchment, 1200, 1200));
  savePng('$brandOut/wordmark_charcoal.png', fit(wmCharcoal, 1200, 1200));
  final scene = load('04_splash_scene').convert(numChannels: 3);
  save('$brandOut/splash_scene.jpg', img.encodeJpg(scene, quality: 86));
  final tiles = <String, img.Image>{};
  for (final e in tileNames.entries) {
    final t = fit(keyed(e.value), 384, 384);
    tiles[e.key] = t;
    savePng('$brandOut/tiles/${e.key}.png', t);
  }
  stdout.writeln('wrote $written files (iOS icons: $iosCount)');

  final pi = args.indexOf('--preview');
  if (pi >= 0 && pi + 1 < args.length) {
    _preview(args[pi + 1], logo, background, tiles, wmParchment, wmCharcoal, scene, charcoal);
  }
}

void _preview(String out, img.Image logo, img.Image background, Map<String, img.Image> tiles, img.Image wmP,
    img.Image wmC, img.Image scene, img.Color charcoal) {
  const w = 2400;
  final sheet = img.Image(width: w, height: 1900, numChannels: 4);
  img.fill(sheet, color: img.ColorRgba8(0x2A, 0x30, 0x36, 255));
  void put(img.Image im, int x, int y) => img.compositeImage(sheet, im, dstX: x, dstY: y);

  // Launcher icons from the xxxhdpi layers: circle, rounded square, themed (monochrome), legacy.
  const l = 432;
  final comp = scaleOpaque(background, l);
  img.compositeImage(comp, placed(logo, l, 66 / 108));
  final visible = img.copyCrop(comp, x: 72, y: 72, width: 288, height: 288);
  final v = img.copyResize(visible, width: 300, height: 300, interpolation: img.Interpolation.average);
  put(circleMask(img.Image.from(v)), 40, 40);
  put(roundedMask(img.Image.from(v), .24), 380, 40);
  final themedBg = img.Image(width: 300, height: 300, numChannels: 4);
  img.fill(themedBg, color: img.ColorRgba8(0xDC, 0xC9, 0xA3, 255));
  final mono = placed(silhouette(logo, r: 0x3B, g: 0x4D, b: 0x3A), l, 66 / 108);
  img.compositeImage(themedBg, img.copyResize(img.copyCrop(mono, x: 72, y: 72, width: 288, height: 288), width: 300, height: 300), dstX: 0, dstY: 0);
  put(circleMask(themedBg), 720, 40);
  final ios = scaleOpaque(background, 300);
  img.compositeImage(ios, placed(logo, 300, .74));
  put(roundedMask(img.Image.from(ios.convert(numChannels: 4)), .225), 1060, 40);
  // Notification icon, 24 dp at 4x and 1x, on dark and light.
  final n = placed(silhouette(logo), 96, .92);
  put(n, 1420, 40);
  final n1 = placed(silhouette(logo), 24, .92);
  put(n1, 1540, 40);
  // Native splash: charcoal with the logo.
  final splash = img.Image(width: 300, height: 520, numChannels: 4);
  img.fill(splash, color: charcoal);
  img.compositeImage(splash, fit(logo, 150, 150), dstX: 75, dstY: 185);
  put(splash, 1680, 40);
  // In-app launch screen.
  final sc = img.copyResize(scene.convert(numChannels: 4), width: 300, height: 667, interpolation: img.Interpolation.average);
  for (final p in sc) {
    final f = (1 - p.y / 267).clamp(0.0, 1.0) * .45;
    p.r = (p.r * (1 - f)).round();
    p.g = (p.g * (1 - f)).round();
    p.b = (p.b * (1 - f)).round();
  }
  img.compositeImage(sc, fit(logo, 120, 120), dstX: 90, dstY: 150);
  img.compositeImage(sc, fit(wmP, 220, 70), dstX: 40, dstY: 275);
  put(sc, 2040, 40);

  // Wordmarks.
  final wLight = img.Image(width: 1000, height: 200, numChannels: 4);
  img.fill(wLight, color: img.ColorRgba8(0xF3, 0xEB, 0xD9, 255));
  img.compositeImage(wLight, fit(wmC, 900, 160), dstX: 50, dstY: 20);
  put(wLight, 40, 400);
  final wDark = img.Image(width: 1000, height: 200, numChannels: 4);
  img.fill(wDark, color: charcoal);
  img.compositeImage(wDark, fit(wmP, 900, 160), dstX: 50, dstY: 20);
  put(wDark, 1100, 400);

  // Tiles on slate, two rows of seven.
  var i = 0;
  for (final t in tiles.values) {
    final f = fit(t, 280, 280);
    put(f, 40 + (i % 7) * 330, 660 + (i ~/ 7) * 320);
    i++;
  }
  // Tiles on parchment (light themes).
  final strip = img.Image(width: w, height: 340, numChannels: 4);
  img.fill(strip, color: img.ColorRgba8(0xF3, 0xEB, 0xD9, 255));
  var j = 0;
  for (final t in tiles.values.take(7)) {
    img.compositeImage(strip, fit(t, 280, 280), dstX: 40 + j * 330, dstY: 30);
    j++;
  }
  put(strip, 0, 1320);
  File(out)
    ..createSync(recursive: true)
    ..writeAsBytesSync(img.encodePng(sheet));
  stdout.writeln('preview: $out');
}
