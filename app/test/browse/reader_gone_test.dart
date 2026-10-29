import 'package:cache/browse/reader_resources.dart';
import 'package:cache/browse/reader_screen.dart';
import 'package:cache/browse/zim_urls.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '17e9fb54-9554-d2cd-e15f-17cf750882d1';

void main() {
  test('the reader asks to be told when its renderer dies, so Android does not end the app', () {
    expect(readerSettings(customScheme: false).useOnRenderProcessGone, isTrue);
    expect(readerSettings(customScheme: true).useOnRenderProcessGone, isTrue);
  });

  test('Reload opens the page that was on screen, else where the reader started', () {
    final start = readerUrl('zim:$id/A/Main_Page')!;
    expect(reloadUrl('zim:$id/A/Georgia', start, customScheme: false), readerUrl('zim:$id/A/Georgia'));
    expect(reloadUrl('zim:$id/A/Georgia', start, customScheme: true), readerUrl('zim:$id/A/Georgia', customScheme: true));
    expect(reloadUrl(null, start, customScheme: false), start);
    expect(reloadUrl('not an address', start, customScheme: false), start);
  });

  testWidgets('a stopped page says so and offers Reload', (tester) async {
    var reloads = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(CacheThemeId.dark),
      home: Scaffold(body: ReaderPageGone(onReload: () => reloads++)),
    ));
    expect(find.text('This page stopped. The phone may be low on memory.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-reload')));
    expect(reloads, 1);
  });
}
