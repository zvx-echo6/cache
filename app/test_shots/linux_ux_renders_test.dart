// Cache on Linux's four UI items, drawn for the owner to approve (design: renders/linux-parity/ux-linux-four-items.md): Storage and
// the log, the share fallback, the update banner, and the location wording. Each screen and state at 390x844, 844x390, 1024x1366 and
// 1440x900, light and dark, as test_shots/linux-ux/<size>-<screen>-<theme>.png. The Linux wording is behind linuxUi, which a test
// switches on with debugLinuxUi (plat.isWeb is a compile-time define). Not part of the test suite.
import 'dart:io';

import 'package:cache/desktop/desktop.dart';
import 'package:cache/desktop/desktop_shell.dart';
import 'package:cache/layout/adaptive.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/linux_ui.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/location/location_web_ui.dart';
import 'package:cache/platform/app_log.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/settings/assistant_page.dart' show UseMyLocationRow;
import 'package:cache/screens/settings/storage_page.dart';
import 'package:cache/screens/settings/widgets.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/share/share_fallback.dart';
import 'package:cache/theme.dart';
import 'package:cache/update/app_update.dart';
import 'package:cache/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/settings_rig.dart';
import 'shot_kit.dart';

const _folder = 'linux-ux';

const Map<String, Size> _sizes = {'390x844': Size(390, 844), '1024x1366': Size(1024, 1366), '1440x900': Size(1440, 900)};

// A phone has a status bar and a home bar; a Linux desktop window has neither.
EdgeInsets _insets(Size s) => s.width < 600 ? const EdgeInsets.only(top: 47, bottom: 34) : EdgeInsets.zero;

/// The page's own scrolling list (the shell has others: the sidebar, the Settings list).
Finder _pageScroll(Type page) => find.descendant(of: find.byType(page), matching: find.byType(Scrollable)).first;

/// Settings' list, as the desktop shows it beside a page (the names and status lines of the real list).
Widget _settingsList() {
  const rows = [
    ('Cache model and web search', 'Gemma 4 E2B \u00b7 web search off'),
    ('Maps', 'Idaho Falls, Twin Falls \u00b7 miles'),
    ('Weather and alerts', '4 sources \u00b7 2 places'),
    ('Notifications', 'Serious alerts \u00b7 quiet 10 PM-6 AM'),
    ('Storage', '41.0 GB free'),
    ('Sharing and sync', 'Off'),
    ('Appearance', 'Light'),
  ];
  return Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        for (final r in rows)
          ListTile(minTileHeight: 52, title: Text(r.$1), subtitle: Text(r.$2)),
      ],
    ),
  );
}

class _Newer implements AppUpdateSource {
  @override
  Future<AppUpdate?> check() async => AppUpdate(
    version: '1.1.1',
    build: 999,
    notes: 'Faster library search and a fix for the log.',
    link: Uri.parse('https://cached.info/linux'),
  );
}

/// A position source whose answers a scene sets.
class _Src implements PositionSource {
  _Src({this.perm = LocationPermissionState.granted, this.service = true});

  LocationPermissionState perm;
  bool service;

  @override
  Future<LocationPermissionState> permission() async => perm;
  @override
  Future<LocationPermissionState> requestPermission() async => perm;
  @override
  Future<bool> serviceEnabled() async => service;
  @override
  Future<Fix> current() async => Fix(lat: 42.5, lon: -113.8, accuracyM: 10, time: DateTime(2026, 11, 9));
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  setUpAll(loadShotFonts);
  setUp(() => debugLinuxUi = true);
  tearDown(() => debugLinuxUi = null);

  for (final entry in _sizes.entries) {
    for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
      final size = entry.value;
      final ratio = size.shortestSide < 600 ? 2.0 : 1.0;
      final tn = theme == CacheThemeId.dark ? 'dark' : 'light';
      final tag = '${entry.key} $tn';

      void view(WidgetTester tester) {
        tester.view.physicalSize = size * ratio;
        tester.view.devicePixelRatio = ratio;
        addTearDown(tester.view.reset);
      }

      Future<void> draw(WidgetTester tester, Widget page, {GlobalKey<ScaffoldMessengerState>? messenger, ModuleId module = ModuleId.settings, bool home = false}) async {
        // A desktop window draws the screen inside the desktop shell (sidebar, page bar, pane); the phone draws it alone, as before.
        final inShell = size.width >= kLinuxDesktopMin;
        final Widget shown = !inShell
            ? page
            : DesktopShell(
                atHome: home,
                module: home ? null : module,
                onHome: () {},
                onModule: (_) {},
                onModuleOptions: (c, m) {},
                child: module == ModuleId.settings && !home
                    ? TwoPane(key: UniqueKey(), list: _settingsList(), initialKey: 'page', initial: (_) => page)
                    : page,
              );
        await tester.pumpWidget(shotApp(shown, messenger: messenger, theme: theme, insets: _insets(size), desktop: inShell));
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      Future<void> snapAs(WidgetTester tester, String id) async {
        final e = tester.takeException();
        final name = '${entry.key}-$id-$tn';
        // ignore: avoid_print
        print('LINUX-UX-SHOT $name');
        if (e != null) {
          // ignore: avoid_print
          print('LINUX-UX-EXC $name: ${e.toString().split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' | ')}');
        }
        await snap(tester, _folder, name);
      }

      Future<void> settle(WidgetTester tester) async {
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
      }

      // ---- 1. Storage and the log ---------------------------------------------------------------------------------------

      testWidgets('1 Storage and log ($tag)', (tester) async {
        final r = await SettingsRig.create(tester);
        view(tester);
        void file(Directory d, String name, int bytes) => File('${d.path}/$name').openSync(mode: FileMode.write)
          ..truncateSync(bytes)
          ..closeSync();
        file(r.libraryDir, 'wikipedia_en_medicine.zim', 940 << 20);
        file(r.libraryDir, 'wikivoyage_en_idaho.zim', 180 << 20);
        file(r.mapsDir, 'tiles.sqlite', 410 << 20);
        file(r.modelsDir, 'gemma-4-E2B-it-Q4_K_M.gguf', 1900 << 20);
        final leftovers = Directory('${r.dir.path}/leftovers')..createSync();
        file(leftovers, 'x.part', 340 << 20);
        await tester.runAsync(r.app.refreshModels);
        await tester.runAsync(r.sources.refresh);
        await draw(tester, StoragePage(deps: r.deps));
        for (var i = 0; i < 40 && !r.storage.measured; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
          await tester.pump();
        }
        await settle(tester);
        await snapAs(tester, '1a-storage');
        await r.dispose(tester);

        // Settings > Storage > Advanced on Linux: no indexing speed; the log level, Share log and Clear log.
        final dir = Directory.systemTemp.createTempSync('linux-ux-log');
        addTearDown(() => dir.deleteSync(recursive: true));
        final settings = AppSettings(settingsDirOverride: dir);
        await tester.runAsync(settings.init);
        final log = AppLog(echo: (_) {});
        await tester.runAsync(() => log.open(Directory('${dir.path}/logs')));
        await draw(tester, IndexingSpeedPage(settings: settings, log: log));
        await snapAs(tester, '1b-advanced-log');

        await tester.scrollUntilVisible(find.byKey(const ValueKey('log-share')), 100, scrollable: _pageScroll(IndexingSpeedPage));
        await tester.tap(find.byKey(const ValueKey('log-share')));
        await settle(tester);
        await snapAs(tester, '1c-share-log-snackbar');

        await draw(tester, IndexingSpeedPage(settings: settings, log: log));
        await tester.scrollUntilVisible(find.byKey(const ValueKey('log-clear')), 100, scrollable: _pageScroll(IndexingSpeedPage));
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('log-clear')));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await settle(tester);
        await snapAs(tester, '1d-clear-log-snackbar');
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(log.close);
      });

      // ---- 2. The share fallback ----------------------------------------------------------------------------------------

      testWidgets('2 Share fallback ($tag)', (tester) async {
        view(tester);
        Widget chat() => Scaffold(
          appBar: AppBar(title: const Text('Chat')),
          body: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('How do I purify water from a stream?', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('Boil it for one minute, or filter it and treat it with chlorine dioxide tablets.'),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('open-share'),
                    onPressed: () => showShareFallback(
                      context,
                      title: 'Share chat',
                      blurb: 'Choose how to take this conversation.',
                      text: '# Water\n\n**You:** How do I purify water from a stream?\n\n**Cache:** Boil it for one minute.',
                      fileName: 'Water.md',
                    ),
                    child: const Text('Share chat'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const ValueKey('open-share-blocked'),
                    onPressed: () => showShareFallback(
                      context,
                      title: 'Share chat',
                      blurb: 'Choose how to take this conversation.',
                      text: '# Water\n\n**You:** How do I purify water from a stream?\n\n**Cache:** Boil it for one minute.',
                      fileName: 'Water.md',
                      clipboardBlocked: true,
                    ),
                    child: const Text('Share chat (insecure page)'),
                  ),
                ],
              ),
            ),
          ),
        );
        final messenger = GlobalKey<ScaffoldMessengerState>();
        await draw(tester, chat(), messenger: messenger, module: ModuleId.ask);
        await tester.tap(find.byKey(const ValueKey('open-share')));
        await settle(tester);
        await snapAs(tester, '2a-share-dialog');
        await tester.tap(find.byKey(const ValueKey('share-save')));
        await settle(tester);
        await snapAs(tester, '2b-download-started');

        await draw(tester, chat(), messenger: messenger, module: ModuleId.ask);
        await tester.tap(find.byKey(const ValueKey('open-share')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('share-copy')));
        await settle(tester);
        await snapAs(tester, '2c-copied');

        await draw(tester, chat(), messenger: messenger, module: ModuleId.ask);
        await tester.tap(find.byKey(const ValueKey('open-share-blocked')));
        await settle(tester);
        await snapAs(tester, '2d-copy-blocked');
        await tester.pumpWidget(const SizedBox());
      });

      // ---- 3. The update banner -----------------------------------------------------------------------------------------

      testWidgets('3 Update banner ($tag)', (tester) async {
        view(tester);
        final dir = Directory.systemTemp.createTempSync('linux-ux-home');
        addTearDown(() => dir.deleteSync(recursive: true));
        final layout = LayoutState(settingsDirOverride: dir);
        await tester.runAsync(layout.init);
        final updates = AppUpdates(source: _Newer(), openUrl: (_) async {}, android: false, linux: true);
        await tester.runAsync(updates.check);
        await draw(tester, HomeScreen(layout: layout, updates: updates, onAsk: (_) {}, onOpenSettings: () {}, onOpenShortcut: (_) {}), home: true);
        await settle(tester);
        await snapAs(tester, '3a-banner-home');
        await tester.tap(find.byKey(const ValueKey('update-open')));
        await settle(tester);
        await snapAs(tester, '3b-how-to-update');
        await tester.pumpWidget(const SizedBox());
        layout.dispose();
        updates.dispose();
      });

      // ---- 4. Location wording ------------------------------------------------------------------------------------------

      testWidgets('4 Location ($tag)', (tester) async {
        view(tester);
        final dir = Directory.systemTemp.createTempSync('linux-ux-loc');
        addTearDown(() => dir.deleteSync(recursive: true));

        Widget behind(Widget body) => Scaffold(appBar: AppBar(title: const Text('Map')), body: body);
        Widget opener(Future<void> Function(BuildContext) open) => behind(
          Builder(builder: (context) => Center(child: FilledButton(key: const ValueKey('open'), onPressed: () => open(context), child: const Text('Find me')))),
        );

        // the question before the browser's own prompt: the map and Ask, then weather
        await draw(tester, opener((c) => showLocationPrePrompt(c)), module: ModuleId.maps);
        await tester.tap(find.byKey(const ValueKey('open')));
        await settle(tester);
        await snapAs(tester, '4a-location-question');
        await draw(tester, opener((c) => showLocationPrePrompt(c, weather: true)), module: ModuleId.maps);
        await tester.tap(find.byKey(const ValueKey('open')));
        await settle(tester);
        await snapAs(tester, '4b-location-question-weather');

        // the Use my location row, in each state
        Future<LocationService> service(_Src src, {bool request = false}) async {
          final l = LocationService(source: src, settingsDirOverride: dir);
          await tester.runAsync(l.init);
          if (request) await tester.runAsync(() => l.request(explain: () async => true));
          return l;
        }

        Widget rowPage(LocationService l, {bool insecure = false}) => SettingsPage(
          title: 'Assistant',
          children: [
            SettingsGroup(label: 'Location', rows: [UseMyLocationRow(location: l, insecure: insecure)]),
          ],
        );

        final ready = await service(_Src());
        await draw(tester, rowPage(ready));
        await snapAs(tester, '4c-row-allowed');

        final blocked = await service(_Src(perm: LocationPermissionState.deniedForever));
        await draw(tester, rowPage(blocked));
        await snapAs(tester, '4d-row-blocked');
        await tester.tap(find.text('How to allow'));
        await settle(tester);
        await snapAs(tester, '4e-how-to-allow');

        final off = await service(_Src(service: false), request: true);
        await draw(tester, rowPage(off));
        await snapAs(tester, '4f-row-computer-cannot-locate');

        await draw(tester, rowPage(ready, insecure: true));
        await snapAs(tester, '4g-row-needs-secure-address');
        await tester.tap(find.text('Why?'));
        await settle(tester);
        await snapAs(tester, '4h-needs-secure-address-dialog');

        // the one-line answers on the map and in weather
        final messenger = GlobalKey<ScaffoldMessengerState>();
        Future<void> snack(SnackBar bar, String id) async {
          await draw(tester, behind(const SizedBox.expand()), messenger: messenger, module: ModuleId.maps);
          messenger.currentState!.showSnackBar(bar);
          await settle(tester);
          await snapAs(tester, id);
        }

        await snack(webLocationSnack(LocationProblem.permissionBlocked), '4i-snack-blocked');
        await snack(webLocationSnack(LocationProblem.permissionDenied), '4j-snack-not-allowed');
        await snack(webLocationSnack(LocationProblem.serviceOff), '4k-snack-computer-cannot-locate');
        await snack(webLocationSnack(LocationProblem.noFix), '4l-snack-no-position');
        await snack(webWeatherBlockedSnack(), '4m-snack-weather-blocked');

        await tester.pumpWidget(const SizedBox());
        for (final l in [ready, blocked, off]) {
          l.dispose();
        }
      });
    }
  }
}
