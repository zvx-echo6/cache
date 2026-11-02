// 1.0.30: a library's PDFs made searchable on the device, always on (owner, 2026-11-02; UX-pdf-index-30 states), for the owner to review, drawn by the
// app's own widgets with sample states (no personal data). Every picture in the light and the dark theme.
// flutter test test_shots/pdfindex_renders_test.dart --update-goldens  (pictures in test_shots/pdfindex/)

import 'dart:async';
import 'dart:io';

import 'package:cache/browse/browse_screen.dart' show LibraryRow;
import 'package:cache/browse/library_actions.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/pdf/index/pdf_index_run.dart';
import 'package:cache/pdf/index/pdf_index_state.dart';
import 'package:cache/pdf/index/pdf_index_ui.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/search/app_search.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shot_kit.dart';

const _out = 'pdfindex';
const Size kPhone = Size(430, 932);
const _doctor = 'Where There Is No Doctor';

String _t(CacheThemeId t) => t == CacheThemeId.light ? 'light' : 'dark';

Future<void> _snap(WidgetTester tester, String name, CacheThemeId theme) => snap(tester, _out, '$name-${_t(theme)}');

Future<void> _show(WidgetTester tester, Widget page, CacheThemeId theme, {Size size = kPhone, GlobalKey<ScaffoldMessengerState>? messenger}) async {
  phone(tester, size: size, ratio: size == kPhone ? 3 : 2);
  await tester.pumpWidget(shotApp(page, theme: theme, messenger: messenger));
  await tester.pump(const Duration(milliseconds: 400));
}

const _waiting = PdfPart(phase: PdfPartPhase.waiting, total: 5768);
const _starting = PdfPart(phase: PdfPartPhase.starting, total: 5768);
const _running = PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 340);
const _pausedPerson = PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.person);
const _pausedBattery = PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 340, pause: PdfPause.battery);
const _needsSpace = PdfPart(phase: PdfPartPhase.needsSpace, total: 5768, handled: 0, needBytes: 1288490189);
const _failed = PdfPart(phase: PdfPartPhase.failed, total: 5768, handled: 340, failure: PdfRunFailure(PdfRunFailureKind.other));
const _finishing = PdfPart(phase: PdfPartPhase.finishing, total: 5768, handled: 5768, finishFraction: 0.4);
const _done = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768);
const _doneSome = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, unreadable: 12);
const _fromOther = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, fromOtherDevice: true);

Widget _part(PdfPart p) => PdfPartView(part: p, onPause: () {}, onResume: () {}, onFreeSpace: () {});

Widget _library(BuildContext context, List<Widget> rows) => Scaffold(
  appBar: AppBar(title: const Text('Library')),
  body: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: rows),
);

Widget _row(String title, String size, PdfPart? p) =>
    LibraryRow(title: title, detail: [size, ?pdfRowNote(p)].join(' · '), onTap: () {}, onHold: () {});

/// The Library list behind, and the library's menu open with its PDFs part (where the part lives: the hold menu and the
/// reader's "...").
Future<void> _sheet(WidgetTester tester, PdfPart p, CacheThemeId theme, {Size size = kPhone}) async {
  await _show(
    tester,
    Builder(builder: (context) => _library(context, [_row(_doctor, '1.2 GB', p), _row('Wikivoyage', '840 MB', null)])),
    theme,
    size: size,
  );
  final context = tester.element(find.byType(ListView));
  unawaited(showLibraryMenu(context, LibraryActions(title: _doctor, bytes: 1288490189, delete: () async {}, checkUpdate: () async {}, changeIcon: () async {}, parts: (_) => _part(p))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

class _Results implements AppSearchProvider {
  @override
  String get module => 'Library';
  @override
  IconData get icon => Icons.menu_book_outlined;
  @override
  Future<List<AppSearchResult>> search(String query, {int limit = 8}) async => [
    AppSearchResult(title: 'Oral rehydration', module: module, icon: icon, detail: '$_doctor, p. 152', score: 0.9, open: () {}),
    AppSearchResult(title: 'Dehydration in children (PDF)', module: module, icon: icon, detail: 'Water and Shelter Handbook, p. 12', score: 0.8, open: () {}),
    AppSearchResult(title: 'Diarrhea and dehydration', module: module, icon: icon, detail: 'Wikivoyage', score: 0.6, open: () {}),
  ];
}

void main() {
  late Directory dir;
  setUpAll(() async {
    await loadShotFonts();
    dir = Directory.systemTemp.createTempSync('pdfindex-shots');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  for (final theme in [CacheThemeId.light, CacheThemeId.dark]) {
    testWidgets('1: the Library list: making searchable, paused, needs space, ready (${_t(theme)})', (tester) async {
      await _show(
        tester,
        Builder(
          builder: (context) => _library(context, [
            _row(_doctor, '1.2 GB', _running),
            _row('Water and Shelter Handbook', '310 MB', _pausedBattery),
            _row('Army Field Manuals', '9.8 GB', _needsSpace),
            _row('Survival Manual', '96 MB', _done),
            _row('Wikivoyage', '840 MB', null),
          ]),
        ),
        theme,
      );
      await _snap(tester, '1-library-list', theme);
    });

    testWidgets('2: the PDFs status in every state (${_t(theme)})', (tester) async {
      final states = <(String, PdfPart)>[
        ('Waiting (another library first)', _waiting),
        ('Starting', _starting),
        ('Making searchable', _running),
        ('Paused (person)', _pausedPerson),
        ('Paused (low battery, or a long job on battery under 50%)', _pausedBattery),
        ('Not enough room', _needsSpace),
        ('Stopped (could not read)', _failed),
        ('Finishing', _finishing),
        ('Ready', _done),
        ('Ready, some unreadable', _doneSome),
      ];
      await _show(
        tester,
        Scaffold(
          appBar: AppBar(title: const Text('PDFs: every state')),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (label, p) in states) ...[
                Padding(padding: const EdgeInsets.fromLTRB(14, 8, 0, 0), child: Text(label, style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic))),
                _part(p),
              ],
            ],
          ),
        ),
        theme,
        size: const Size(430, 1250),
      );
      await _snap(tester, '2a-states', theme);
      for (final (name, p) in [
        ('2b-menu-making-searchable', _running),
        ('2c-menu-paused-low-battery', _pausedBattery),
        ('2d-menu-needs-space', _needsSpace),
        ('2e-menu-ready', _done),
        ('2f-menu-ready-unreadable', _doneSome),
        ('2g-menu-ready-from-another-device', _fromOther),
      ]) {
        await _sheet(tester, p, theme);
        await _snap(tester, name, theme);
      }
    });

    testWidgets('3: the synced snackbar (${_t(theme)})', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await _show(tester, Builder(builder: (context) => _library(context, [_row(_doctor, '1.2 GB', _done)])), theme, messenger: messenger);
      messenger.currentState!.showSnackBar(const SnackBar(content: Text('Another device finished this. Using its index.')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await _snap(tester, '3-synced-snackbar', theme);
    });

    testWidgets('4: search results: a PDF hit; still making one library searchable; two (${_t(theme)})', (tester) async {
      final layout = LayoutState(settingsDirOverride: Directory('${dir.path}/${_t(theme)}'));
      await tester.runAsync(layout.init);
      const doctor = PdfZimRef(path: '/z/doctor.zim', uuid: 'd', title: _doctor);
      const water = PdfZimRef(path: '/z/water.zim', uuid: 'w', title: 'Water and Shelter Handbook');
      for (final (name, pending) in <(String, List<(PdfZimRef, PdfPart)>)>[
        ('4a-results-pdf-hit', const []),
        ('4b-results-still-making', const [(doctor, _running)]),
        ('4c-results-still-making-two', const [(doctor, _running), (water, PdfPart(phase: PdfPartPhase.waiting, total: 40))]),
      ]) {
        await _show(
          tester,
          HomeScreen(
            layout: layout,
            onAsk: (_) {},
            onOpenSettings: () {},
            onOpenShortcut: (_) {},
            search: AppSearch([_Results()]),
            searchFootnote: PdfSearchNoteView(pending: pending, open: (_) {}, hide: (_) {}),
          ),
          theme,
        );
        await tester.enterText(find.byKey(const ValueKey('home-search')), 'dehydration');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 300));
        await _snap(tester, name, theme);
      }
      await tester.pumpWidget(const SizedBox());
      layout.dispose();
    });

    testWidgets('5: iPad portrait and landscape, desktop (${_t(theme)})', (tester) async {
      for (final (name, size) in [
        ('5a-tablet-portrait-820', const Size(820, 1180)),
        ('5b-tablet-landscape-1180', const Size(1180, 820)),
        ('5c-desktop-1280', const Size(1280, 800)),
      ]) {
        await _sheet(tester, _running, theme, size: size);
        await _snap(tester, name, theme);
      }
    });
  }
}
