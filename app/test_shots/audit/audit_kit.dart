// The screen-size audit's sizes and picture writer. Each audit_*_test.dart sets [auditSizeName] and [auditTheme], then registers the
// scenes; every picture is written as test_shots/audit/<size>-<screen>-<theme>.png. Layout errors (overflow and the like) do not
// stop the run: each picture's are printed to the log as "AUDIT-EXC <picture>: <first line>" so the audit can list them.
// Not part of the test suite.

import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shot_kit.dart';

/// The audit sizes (logical points): phone upright and sideways, tablet upright (11" and 12.9") and sideways, a desktop browser
/// window.
const Map<String, Size> kAuditSizes = {
  '390x844': Size(390, 844),
  '844x390': Size(844, 390),
  '820x1180': Size(820, 1180),
  '1024x1366': Size(1024, 1366),
  '1180x820': Size(1180, 820),
  '1440x900': Size(1440, 900),
};

String auditSizeName = '390x844';
CacheThemeId auditTheme = CacheThemeId.light;

Size get auditSize => kAuditSizes[auditSizeName]!;

/// The system bars' room at each size (a notched phone upright and sideways, a tablet's status bar, none in a browser window).
EdgeInsets get auditInsets => switch (auditSizeName) {
  '390x844' => const EdgeInsets.only(top: 47, bottom: 34),
  '844x390' => const EdgeInsets.only(left: 47, right: 47, bottom: 21),
  '820x1180' || '1180x820' || '1024x1366' => const EdgeInsets.only(top: 24, bottom: 20),
  _ => EdgeInsets.zero,
};

double get _ratio => auditSize.shortestSide < 600 ? 2 : 1;

/// Sets the test window to the audit size.
void auditView(WidgetTester tester) {
  tester.view.physicalSize = auditSize * _ratio;
  tester.view.devicePixelRatio = _ratio;
  addTearDown(tester.view.reset);
}

/// [page] in the app's frame at the audit size and theme.
Widget auditApp(Widget page, {GlobalKey<ScaffoldMessengerState>? messenger}) => shotApp(page, messenger: messenger, theme: auditTheme, insets: auditInsets);

/// The screens drawn dark as well (the busiest ones); every screen is drawn light.
const Set<String> kAuditDarkIds = {
  'settings',
  'settings-storage',
  'settings-weather',
  'home',
  'home-search',
  'ask',
  'ask-sources',
  'weather',
  'notebooks',
  'notebook-entry',
  'places-list',
  'models-screen',
  'region-detail',
  'regions-updates-tab',
  'videos-list',
  'video-player',
  'maps-find-me',
  'place-card',
  'directions-panel',
  'guidance',
  'connections',
  'ask-confirm-card',
  'chat-list',
  'region-row',
  'home-setup-card',
  'pdf-cited-passage',
};

/// Writes the picture [id] at the audit size (dark only for [kAuditDarkIds] or [always]), and logs any layout errors drawn in it.
Future<void> auditSnap(WidgetTester tester, String id, {bool always = false}) async {
  final dark = auditTheme == CacheThemeId.dark;
  final name = '$auditSizeName-$id-${dark ? 'dark' : 'light'}';
  final e = tester.takeException();
  if (dark && !always && !kAuditDarkIds.contains(id)) return;
  // ignore: avoid_print
  print('AUDIT-SHOT $name');
  if (e != null) {
    // ignore: avoid_print
    print('AUDIT-EXC $name: ${e.toString().split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' | ')}');
  }
  await expectLater(find.byType(MaterialApp).first, matchesGoldenFile('$name.png'));
}
