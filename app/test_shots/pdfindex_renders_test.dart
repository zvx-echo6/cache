// 1.0.30: making a library's PDFs searchable on the device (UX-pdf-index-30, section 7), for the owner to review, drawn by the
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

const _idle = PdfPart(phase: PdfPartPhase.idle, total: 5768);
const _running = PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 1204, range: (Duration(hours: 2), Duration(hours: 3)));
const _live = PdfPart(phase: PdfPartPhase.running, total: 5768, handled: 1251, timeLeft: Duration(hours: 2, minutes: 20));
const _starting = PdfPart(phase: PdfPartPhase.starting, total: 5768);
const _pausedPerson = PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 1204, pause: PdfPause.person);
const _pausedBattery = PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 1204, pause: PdfPause.battery);
const _pausedClosed = PdfPart(phase: PdfPartPhase.paused, total: 5768, handled: 1204, pause: PdfPause.closed);
const _full = PdfPart(phase: PdfPartPhase.failed, total: 5768, handled: 1204, failure: PdfRunFailure(PdfRunFailureKind.full));
const _finishing = PdfPart(phase: PdfPartPhase.finishing, total: 5768, handled: 5768, finishFraction: 0.4);
const _done = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768);
const _doneSome = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, unreadable: 12);
const _fromOther = PdfPart(phase: PdfPartPhase.done, total: 5768, handled: 5768, fromOtherDevice: true);
const _newVersion = PdfPart(phase: PdfPartPhase.newVersion, total: 5790, newCount: 22);

Widget _part(PdfPart p) => PdfPartView(part: p, onStart: () {}, onPause: () {}, onResume: () {}, onRemove: () async {}, onFreeSpace: () {});

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
    testWidgets('1: the Library list: not searchable, indexing, done, from another device (${_t(theme)})', (tester) async {
      await _show(
        tester,
        Builder(
          builder: (context) => _library(context, [
            _row(_doctor, '1.2 GB', _idle),
            _row('Water and Shelter Handbook', '310 MB', _running),
            _row('Survival Manual', '96 MB', _done),
            _row('Field First Aid', '220 MB', _fromOther),
            _row('Wikivoyage', '840 MB', null),
          ]),
        ),
        theme,
      );
      await _snap(tester, '1-library-list', theme);
    });

    testWidgets('2: the PDFs part in every state (${_t(theme)})', (tester) async {
      final states = <(String, PdfPart)>[
        ('Not searchable yet', _idle),
        ('Starting', _starting),
        ('Indexing (first 2 minutes: the range)', _running),
        ('Paused (person)', _pausedPerson),
        ('Paused (battery)', _pausedBattery),
        ('Paused (Cache was closed)', _pausedClosed),
        ('Stopped (device full)', _full),
        ('Finishing', _finishing),
        ('Done', _done),
        ('Done, some unreadable', _doneSome),
        ('From another device', _fromOther),
        ('New version', _newVersion),
      ];
      await _show(
        tester,
        Scaffold(
          appBar: AppBar(title: const Text('PDFs part: every state')),
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
        size: const Size(430, 1500),
      );
      await _snap(tester, '2a-part-states', theme);
      for (final (name, p) in [
        ('2b-menu-not-searchable', _idle),
        ('2c-menu-indexing', _running),
        ('6a-menu-paused-battery', _pausedBattery),
        ('6b-menu-paused-closed', _pausedClosed),
        ('7-menu-done-unreadable', _doneSome),
        ('8a-menu-new-version', _newVersion),
        ('2d-menu-full', _full),
        ('2e-menu-from-another-device', _fromOther),
      ]) {
        await _sheet(tester, p, theme);
        await _snap(tester, name, theme);
      }
    });

    testWidgets('3: the start pop-up: range; not enough space (${_t(theme)})', (tester) async {
      const ok = PdfEstimate(pdfs: 5768, low: Duration(hours: 2), high: Duration(hours: 4), indexBytes: 450 << 20, needBytes: 900 << 20, usable: 40 << 30);
      const short = PdfEstimate(pdfs: 5768, low: Duration(hours: 2), high: Duration(hours: 4), indexBytes: 450 << 20, needBytes: 900 << 20, usable: 300 << 20);
      for (final (name, e) in [('3a-confirm-range', ok), ('3b-confirm-free-space', short)]) {
        await _sheet(tester, _idle, theme);
        Navigator.of(tester.element(find.byType(ListView).first)).pop();
        await tester.pump(const Duration(milliseconds: 400));
        unawaited(confirmPdfIndex(tester.element(find.byType(ListView).first), e));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _snap(tester, name, theme);
      }
    });

    testWidgets('4: the live estimate after about 2 minutes (${_t(theme)})', (tester) async {
      await _sheet(tester, _live, theme);
      await _snap(tester, '4-live-estimate', theme);
    });

    testWidgets('5: Remove confirm (${_t(theme)})', (tester) async {
      await _sheet(tester, _pausedPerson, theme);
      await tester.tap(find.byKey(const ValueKey('pdfindex-remove')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _snap(tester, '5-remove-confirm', theme);
    });

    testWidgets('8b: new version confirm (${_t(theme)})', (tester) async {
      await _sheet(tester, _newVersion, theme);
      Navigator.of(tester.element(find.byType(ListView).first)).pop();
      await tester.pump(const Duration(milliseconds: 400));
      unawaited(confirmPdfIndex(
        tester.element(find.byType(ListView).first),
        const PdfEstimate(pdfs: 5790, low: Duration(hours: 2), high: Duration(hours: 4), indexBytes: 452 << 20, needBytes: 904 << 20, usable: 40 << 30),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _snap(tester, '8b-new-version-confirm', theme);
    });

    testWidgets('9, 10: the synced and auto-start snackbars (${_t(theme)})', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await _show(tester, Builder(builder: (context) => _library(context, [_row(_doctor, '1.2 GB', _fromOther)])), theme, messenger: messenger);
      messenger.currentState!.showSnackBar(const SnackBar(content: Text('Another device finished this. Using its index.')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await _snap(tester, '9-synced-snackbar', theme);
      final second = GlobalKey<ScaffoldMessengerState>();
      await _show(tester, Builder(builder: (context) => _library(context, [_row('Field First Aid', '22 MB', _starting)])), theme, messenger: second);
      showPdfAutoStartSnack(second.currentState!, 140, () {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await _snap(tester, '10-auto-start-snackbar', theme);
    });

    testWidgets('11: search results: an indexed PDF result; the quiet line; the 40% line (${_t(theme)})', (tester) async {
      final layout = LayoutState(settingsDirOverride: Directory('${dir.path}/${_t(theme)}'));
      await tester.runAsync(layout.init);
      const doctor = PdfZimRef(path: '/z/doctor.zim', uuid: 'd', title: _doctor);
      const water = PdfZimRef(path: '/z/water.zim', uuid: 'w', title: 'Water and Shelter Handbook');
      for (final (name, pending) in <(String, List<(PdfZimRef, PdfPart)>)>[
        ('11a-results-pdf-hit', const []),
        ('11b-results-quiet-line', const [(doctor, PdfPart(phase: PdfPartPhase.idle, total: 5768))]),
        ('11c-results-quiet-line-many', const [(doctor, PdfPart(phase: PdfPartPhase.idle, total: 5768)), (water, PdfPart(phase: PdfPartPhase.idle, total: 40)), (PdfZimRef(path: '/z/s.zim', uuid: 's', title: 'Survival'), PdfPart(phase: PdfPartPhase.newVersion, total: 9))]),
        ('11d-results-40-percent', const [(doctor, PdfPart(phase: PdfPartPhase.running, total: 10, handled: 4))]),
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

    testWidgets('12: iPad portrait and landscape, desktop (${_t(theme)})', (tester) async {
      for (final (name, size) in [
        ('12a-tablet-portrait-820', const Size(820, 1180)),
        ('12b-tablet-landscape-1180', const Size(1180, 820)),
        ('12c-desktop-1280', const Size(1280, 800)),
      ]) {
        await _sheet(tester, _running, theme, size: size);
        await _snap(tester, name, theme);
      }
    });
  }
}
