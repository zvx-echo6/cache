// The 1.0.29 download pattern (UX-downloads-29) for the owner to approve, drawn by the app's own widgets with sample data.
// flutter test test_shots/downloads_renders_test.dart --update-goldens  (pictures in test_shots/downloads/)

import 'dart:async';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/browse/opds.dart';
import 'package:cache/browse/zim_dl.dart';
import 'package:cache/downloads/download_row.dart';
import 'package:cache/maps/layers/layer_def.dart' show AreaPhase;
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/recommendations.dart';
import 'package:cache/regions/ui/region_page.dart';
import 'package:cache/regions/ui/regions_screen.dart';
import 'package:cache/screens/model_search_screen.dart';
import 'package:cache/screens/models_screen.dart';
import 'package:cache/screens/settings/widgets.dart' show GroupLabel;
import 'package:cache/screens/videos/video_dl.dart';
import 'package:cache/sources/libraries_state.dart';
import 'package:cache/theme.dart';
import 'package:cache/video/video_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/browse/fakes.dart' show FakeSources;
import '../test/support/owner_state.dart';
import 'shot_kit.dart';

const _out = 'downloads';
const Size kPhone = Size(430, 932);
const Size kTabLandscape = Size(1280, 800);
const Size kTabPortrait = Size(800, 1280);
const EdgeInsets kTabletInsets = EdgeInsets.only(top: 24, bottom: 20);
const _gb = 1 << 30;
const _mb = 1 << 20;

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _show(WidgetTester tester, Widget page, {CacheThemeId theme = CacheThemeId.light, Size size = kPhone}) async {
  phone(tester, size: size, ratio: size == kPhone ? 3 : 2);
  await tester.pumpWidget(shotApp(page, theme: theme, insets: size == kPhone ? null : kTabletInsets));
  await _settle(tester);
}

/// The measured speed of [key] reads [bytesPerSecond] at [done] bytes (as after ten seconds of data).
final DateTime _t0 = DateTime(2026, 11, 1, 12);
void _speed(String key, int done, double bytesPerSecond) {
  DlMeter.reset(key);
  DlMeter.now = () => _t0;
  DlMeter.speed(key, (done - bytesPerSecond * 10).round().clamp(0, done));
  DlMeter.now = () => _t0.add(const Duration(seconds: 10));
}

/// Model downloads whose rows show fixed states.
class _ShotDownloads extends ModelDownloads {
  _ShotDownloads({required super.app, super.hub});
  final Map<String, DlState> fixed = {};
  void Function(HfFile f)? onStart;

  @override
  DlState stateOf(HfFile f) => fixed[f.fileName] ?? super.stateOf(f);

  @override
  Future<void> start(HfFile f, {bool anyway = false}) async => onStart?.call(f);

  void set(String file, DlState s) {
    fixed[file] = s;
    notifyListeners();
  }
}

class _ShotHub extends HfHub {
  @override
  Future<List<HfFile>> ggufFiles(String repo) async => [
        HfFile(repo: repo, path: 'gemma-4-E4B-it-Q3_K_M.gguf', size: (2.1 * _gb).round()),
        HfFile(repo: repo, path: 'gemma-4-E4B-it-Q4_K_M.gguf', size: (3.0 * _gb).round()),
        HfFile(repo: repo, path: 'gemma-4-E4B-it-Q6_K.gguf', size: (4.2 * _gb).round()),
        HfFile(repo: repo, path: 'gemma-4-E4B-it-Q8_0.gguf', size: (7.0 * _gb).round()),
      ];
}

const _e2b = 'e2b-stock-cache-1.0-Q4_K_M.gguf';
const _e4b = 'gemma-4-E4B-it-Q4_K_M.gguf';
final int _e4bSize = 4977171584;

Future<(AppState, _ShotDownloads, RecommendedModels, Directory)> _models() async {
  final dir = Directory.systemTemp.createTempSync('dl-shots');
  final app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
  app.modelsDir = Directory('${dir.path}/models')..createSync();
  final d = _ShotDownloads(app: app);
  ModelDownloads.shared = d;
  final rec = RecommendedModels(builtIn: () async => File('assets/models/recommended.json').readAsStringSync(), fetch: () async => throw 'offline');
  rec.models = parseRecommendations(File('assets/models/recommended.json').readAsStringSync())!;
  return (app, d, rec, dir);
}

CatalogEntry _entry(String id, String title, int size, {String summary = ''}) => CatalogEntry(
      id: id,
      title: title,
      summary: summary,
      language: 'eng',
      name: id,
      flavour: '',
      category: '',
      tags: const [],
      updated: '2026-10-01',
      size: size,
      articleCount: 1,
      downloadUrl: Uri.parse('https://example.invalid/$id.zim'),
      iconUrl: null,
    );

/// A list of rows under section labels, as on the screens that hold them.
Widget _rows(String title, List<Widget> children) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), children: children),
    );

void main() {
  setUpAll(loadShotFonts);
  tearDown(() {
    DlMeter.clear();
    DlMeter.now = DateTime.now;
    ModelDownloads.shared = null;
  });

  testWidgets('1, 2: Models, Recommended: E4B in every state; full device (dark)', (tester) async {
    final (app, d, rec, dir) = await tester.runAsync(_models) as (AppState, _ShotDownloads, RecommendedModels, Directory);
    final total = _e4bSize;
    final states = <String, DlState>{
      'not-downloaded': DlState(DlPhase.idle, total: total),
      'starting': DlState(DlPhase.starting, total: total),
      'downloading': DlState(DlPhase.running, done: (1.7 * _gb).round(), total: total, speed: 6.2 * _mb),
      'pausing': DlState(DlPhase.pausing, done: (1.7 * _gb).round(), total: total),
      'paused': DlState(DlPhase.paused, done: (1.7 * _gb).round(), total: total),
      'failed': DlState(DlPhase.failed, done: (1.7 * _gb).round(), total: total, reason: DlReason.noConnection),
      'verifying': DlState(DlPhase.verifying, done: total, total: total),
      'done': DlState(DlPhase.done, total: total),
    };
    for (final e in states.entries) {
      d.fixed
        ..clear()
        ..[_e4b] = e.value;
      await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb));
      await snap(tester, _out, '01-models-e4b-${e.key}');
    }
    // Waiting: E2B behind E4B.
    d.fixed
      ..clear()
      ..[_e4b] = DlState(DlPhase.running, done: (1.7 * _gb).round(), total: total, speed: 6.2 * _mb)
      ..[_e2b] = const DlState(DlPhase.waiting, total: 3427879936, waitingFor: 'Gemma 4 E4B · Q4_K_M');
    await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb));
    await snap(tester, _out, '01-models-e4b-waiting-e2b');
    d.fixed
      ..clear()
      ..[_e4b] = DlState(DlPhase.failed, done: (1.7 * _gb).round(), total: total, reason: DlReason.full);
    await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb), theme: CacheThemeId.dark);
    await snap(tester, _out, '02-models-e4b-full-free-space-dark');
    await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb));
    await snap(tester, _out, '02-models-e4b-full-free-space');
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });

  testWidgets('3: Hugging Face results: one downloading, one waiting', (tester) async {
    final (_, d, _, dir) = await tester.runAsync(_models) as (AppState, _ShotDownloads, RecommendedModels, Directory);
    d.fixed
      ..['gemma-4-E4B-it-Q4_K_M.gguf'] = DlState(DlPhase.running, done: (1.1 * _gb).round(), total: (3.0 * _gb).round(), speed: 5.4 * _mb)
      ..['gemma-4-E4B-it-Q6_K.gguf'] = const DlState(DlPhase.waiting, waitingFor: 'gemma-4-E4B-it-Q4_K_M');
    final files = _ShotDownloads(app: d.app, hub: _ShotHub())..fixed.addAll(d.fixed);
    await _show(tester, ModelFilesScreen(downloads: files, model: const HfModel(id: 'unsloth/gemma-4-E4B-it-GGUF'), memory: 8 * _gb));
    await snap(tester, _out, '03-hf-results-downloading-waiting');
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });

  testWidgets('4: press and hold on a Paused row; the Remove pop-up', (tester) async {
    final (app, d, rec, dir) = await tester.runAsync(_models) as (AppState, _ShotDownloads, RecommendedModels, Directory);
    d.fixed[_e4b] = DlState(DlPhase.paused, done: (1.7 * _gb).round(), total: _e4bSize);
    await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb));
    await tester.longPress(find.byKey(const ValueKey('model-$_e4b-row')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '04-models-hold-menu-paused');
    await tester.tap(find.byKey(const ValueKey('download-menu-remove')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '04-models-remove-confirm');
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });

  testWidgets('5, 6, 7: Regions list and the region page', (tester) async {
    final o = await OwnerState.boot(tester);
    // Idaho: directions ready, places 40%, off-road waiting (the rig's start).
    final places = (o.core.regions['us-id']!['parts'] as Map)['places'] as Map<String, dynamic>;
    final done = places['done_bytes'] as int;
    await tester.runAsync(o.regions.refresh);
    final l = o.regions.regionOf('us-id')!;
    final regionDone = l.parts.fold<int>(0, (s, p) => s + p.bytes);
    _speed('region:us-id', regionDone, 9.0 * _mb);
    _speed('part:us-id:places', done, 9.0 * _mb);
    await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await snap(tester, _out, '05-regions-idaho-downloading');
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await snap(tester, _out, '06-region-page-downloading');
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'), theme: CacheThemeId.dark);
    await snap(tester, _out, '06-region-page-downloading-dark');
    // A second region waits for Idaho.
    await tester.runAsync(() => o.core.call('add', {'id': 'us-ut', 'name': 'Utah', 'geometry': {}, 'parts': ['routing', 'places']}));
    await tester.runAsync(o.regions.refresh);
    await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await snap(tester, _out, '05-regions-utah-waiting');
    await tester.runAsync(() => o.core.call('remove', {'id': 'us-ut'}));
    // Paused by the person.
    await tester.runAsync(o.regions.pauseAll);
    await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await snap(tester, _out, '05-regions-idaho-paused');
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await snap(tester, _out, '06-region-page-paused');
    await tester.runAsync(() => o.regions.resumeAll());
    // Failed: places stopped with no connection.
    places
      ..['state'] = 'failed'
      ..['code'] = 'offline'
      ..['error'] = 'connection refused';
    await tester.runAsync(o.regions.refresh);
    await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1));
    await snap(tester, _out, '05-regions-idaho-failed');
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await snap(tester, _out, '07-region-page-failed-places');
    // 9: an off-road layer of the region downloading, then paused.
    final usfs = o.legacy['usfs']!;
    usfs
      ..phase = AreaPhase.running
      ..interrupted = false
      ..error = null;
    places
      ..['state'] = 'downloading'
      ..remove('code')
      ..['error'] = null;
    await tester.runAsync(o.regions.refresh);
    _speed('area:${usfs.id}', usfs.bytes, 2.4 * _mb);
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await _settle(tester);
    await snap(tester, _out, '09-offroad-layer-downloading');
    usfs
      ..phase = AreaPhase.failed
      ..paused = true;
    await tester.runAsync(o.regions.refresh);
    await _show(tester, RegionPage(regions: o.regions, id: 'us-id'));
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await _settle(tester);
    await snap(tester, _out, '09-offroad-layer-paused');
    // 12: tablets.
    usfs.phase = AreaPhase.done;
    await tester.runAsync(o.regions.refresh);
    for (final e in {'landscape': kTabLandscape, 'portrait': kTabPortrait}.entries) {
      _speed('region:us-id', regionDone, 9.0 * _mb);
      await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1), size: e.value);
      await tester.tap(find.byKey(const ValueKey('local-us-id-row')));
      await _settle(tester);
      await snap(tester, _out, '12-tablet-${e.key}-regions');
      await _show(tester, RegionsScreen(regions: o.regions, initialTab: 1), size: e.value, theme: CacheThemeId.dark);
      await tester.tap(find.byKey(const ValueKey('local-us-id-row')));
      await _settle(tester);
      await snap(tester, _out, '12-tablet-${e.key}-regions-dark');
    }
    await o.dispose(tester);
  });

  testWidgets('8: Add to Library: one downloading, one waiting; catalogue: failed', (tester) async {
    final dir = Directory.systemTemp.createTempSync('dl-shots-browse');
    final b = BrowseState(sources: FakeSources(dir), settingsDirOverride: dir, phoneLanguage: 'en');
    final wiki = _entry('wikipedia_en_medicine', 'Wikipedia (Medicine)', (2.9 * _gb).round(), summary: 'Medical articles');
    final voyage = _entry('wikivoyage_en', 'Wikivoyage', 870 * _mb, summary: 'Travel guide');
    final gut = _entry('gutenberg_en', 'Project Gutenberg', (6.4 * _gb).round(), summary: 'Free books');
    b.transfers[wiki.id] = ZimTransfer(wiki)
      ..phase = TransferPhase.downloading
      ..done = (1.2 * _gb).round()
      ..total = wiki.size;
    _speed('zim:${wiki.id}', (1.2 * _gb).round(), 7.5 * _mb);
    b.transfers[voyage.id] = ZimTransfer(voyage)..phase = TransferPhase.blockedByMobileData;
    b.transfers[gut.id] = ZimTransfer(gut)
      ..phase = TransferPhase.failed
      ..done = (2.2 * _gb).round()
      ..total = gut.size
      ..error = 'The connection failed: connection reset';
    await _show(
      tester,
      _rows('Add to Library', [
        const GroupLabel('Ready-made collections'),
        for (final e in [wiki, voyage, gut]) EntryTile(browse: b, entry: e),
      ]),
    );
    await snap(tester, _out, '08-library-catalogue-downloading-waiting-failed');
    b.dispose();
  });

  testWidgets('10: Videos, the guide and Wikipedia', (tester) async {
    final v = VideoState();
    final run = DownloadTask(instance: 'tilvids.com', uuid: 'a1', title: 'Purifying water in the field', choice: '480', label: '480p', expectedSize: 412 * _mb)
      ..done = 160 * _mb
      ..total = 412 * _mb;
    _speed('video:${run.key}', 160 * _mb, 3.1 * _mb);
    final done = DownloadTask(instance: 'tilvids.com', uuid: 'a2', title: 'Knots every camper should know', choice: '480', label: '480p', expectedSize: 230 * _mb)
      ..phase = DownloadPhase.done
      ..done = 230 * _mb
      ..total = 230 * _mb;
    final guide = AddTask('Cache guide')..step = AddStep.unpacking;
    final wiki = _entry('wikipedia_en_all_maxi', 'Wikipedia', (118.7 * _gb).round(), summary: 'The free encyclopedia');
    final wt = ZimTransfer(wiki)
      ..phase = TransferPhase.downloading
      ..done = (12.4 * _gb).round()
      ..total = wiki.size;
    _speed('zim:${wiki.id}', (12.4 * _gb).round(), 9.8 * _mb);
    final wAdding = ZimTransfer(_entry('wikipedia_en_medicine', 'Wikipedia (Medicine)', (2.9 * _gb).round()))..phase = TransferPhase.adding;
    await _show(
      tester,
      _rows('Downloads', [
        const GroupLabel('Videos'),
        DownloadRow(keyBase: 'v1', title: run.title, subtitle: run.label, state: videoDl(run), actions: videoActions(v, run)),
        DownloadRow(
          keyBase: 'v2',
          title: done.title,
          subtitle: done.label,
          state: videoDl(done),
          actions: videoActions(v, done),
          doneAction: TextButton(onPressed: () {}, child: const Text('Play')),
        ),
        const GroupLabel('Guide'),
        DownloadRow(keyBase: 'g', title: 'Adding ${guide.name}', state: addDl(guide), actions: const DlActions()),
        const GroupLabel('Wikipedia'),
        DownloadRow(keyBase: 'w1', title: wiki.title, state: zimDl(wt), actions: const DlActions(pause: _nop)),
        DownloadRow(keyBase: 'w2', title: wAdding.entry.title, state: zimDl(wAdding), actions: const DlActions()),
      ]),
    );
    await snap(tester, _out, '10-videos-guide-wikipedia');
    v.dispose();
  });

  testWidgets('12: Models on a tablet', (tester) async {
    final (app, d, rec, dir) = await tester.runAsync(_models) as (AppState, _ShotDownloads, RecommendedModels, Directory);
    d.fixed[_e4b] = DlState(DlPhase.running, done: (1.7 * _gb).round(), total: _e4bSize, speed: 6.2 * _mb);
    for (final e in {'landscape': kTabLandscape, 'portrait': kTabPortrait}.entries) {
      await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb), size: e.value);
      await snap(tester, _out, '12-tablet-${e.key}-models');
      await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb), size: e.value, theme: CacheThemeId.dark);
      await snap(tester, _out, '12-tablet-${e.key}-models-dark');
    }
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });

  testWidgets('14: one tap, frame by frame: Download, the pop-up, Starting, first bytes', (tester) async {
    final (app, d, rec, dir) = await tester.runAsync(_models) as (AppState, _ShotDownloads, RecommendedModels, Directory);
    d.onStart = (f) => d.set(f.fileName, DlState(DlPhase.starting, total: f.size));
    await _show(tester, ModelsScreen(app: app, recommended: rec, memory: 8 * _gb));
    await snap(tester, _out, '14-frame-1-not-downloaded');
    await tester.tap(find.byKey(const ValueKey('model-$_e4b-download')));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, _out, '14-frame-2-pop-up');
    await tester.tap(find.text('Download').last);
    await tester.pump();
    await snap(tester, _out, '14-frame-3-starting');
    d.set(_e4b, DlState(DlPhase.running, done: 18 * _mb, total: _e4bSize));
    await tester.pump();
    await snap(tester, _out, '14-frame-4-first-bytes');
    await _settle(tester);
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });
}

void _nop() {}

