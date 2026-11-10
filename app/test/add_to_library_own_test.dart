import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/discover/ui/discover_screen.dart';
import 'package:cache/library/add_pdf/add_pdf_pages.dart';
import 'package:cache/screens/libraries_screen.dart' show LibrariesScreen;
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'add_pdf/add_pdf_world.dart';
import 'support/discover_fakes.dart';

void main() {
  late AddPdfWorld w;
  tearDown(() => w.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> open(WidgetTester tester, {required bool fromAddToLibrary}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async => w = await AddPdfWorld.make());
    final d = await makeDiscover(FakeDiscoverDevice());
    final page = fromAddToLibrary
        ? DiscoverScreen(discover: d, face: DiscoverFace.resources, yourOwn: YourOwnGroup.forBrowse(w.browse))
        : DiscoverScreen(discover: d);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: page));
    await settle(tester);
  }

  testWidgets('Add to Library opens Discover with YOUR OWN first, above Resources', (tester) async {
    await open(tester, fromAddToLibrary: true);
    expect(find.text('Your own'), findsOneWidget);
    expect(find.text('Your own library'), findsOneWidget);
    expect(find.text('From a file or a download link'), findsOneWidget);
    expect(find.text('Add a PDF'), findsOneWidget);
    expect(find.text('A manual or a scanned book'), findsOneWidget);
    expect(find.text('Add a folder'), findsOneWidget);
    final own = tester.getTopLeft(find.byKey(const ValueKey('add-own-library'))).dy;
    expect(own, lessThan(tester.getTopLeft(find.text('Collections')).dy));
    expect(own, lessThan(tester.getTopLeft(find.text('Libraries')).dy));
  });

  testWidgets('Each YOUR OWN row opens its screen', (tester) async {
    await open(tester, fromAddToLibrary: true);
    final picked = <String>[];
    addPdfPicker = () async {
      picked.add('pdf');
      return null;
    };
    addPdfFolderPicker = () async {
      picked.add('folder');
      return null;
    };
    await tester.tap(find.byKey(const ValueKey('add-pdf')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-pdf-folder')));
    await settle(tester);
    expect(picked, ['pdf', 'folder']);
    await tester.tap(find.byKey(const ValueKey('add-own-library')));
    await settle(tester);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Your own library')), findsOneWidget);
    expect(find.byType(LibrariesScreen), findsOneWidget);
  });

  testWidgets('Discover opened normally does not show the group', (tester) async {
    await open(tester, fromAddToLibrary: false);
    expect(find.text('Your own'), findsNothing);
    expect(find.byKey(const ValueKey('add-own-library')), findsNothing);
    expect(find.byKey(const ValueKey('add-pdf')), findsNothing);
  });
}
