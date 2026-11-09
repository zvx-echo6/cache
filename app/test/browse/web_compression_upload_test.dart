import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_page.dart';
import 'package:cache/browse/web/build_library_page.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'build_fakes.dart';
import 'web_fakes.dart';

class CompressionTestApi extends FakeBuildApi implements BuildCompressionApi {
  BuildCompressionSettings settings = const BuildCompressionSettings();
  @override
  Future<BuildCompressionSettings> getCompressionSettings() async => settings;
  @override
  Future<BuildCompressionSettings> putCompressionSettings(BuildCompressionSettings value) async => settings = value;
}

void main() {
  testWidgets('one book waits for its inline choice and sends the explicit selection', (tester) async {
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CompressionTestApi();
    final up = FakeRawUploader();
    final c = BuildController(api: api, uploader: up, poll: false);
    addTearDown(c.dispose);
    await c.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: BuildPage(build: c, initialFiles: [FakeLocalFile('field.pdf', 1024)]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('library-name')), 'Field books');
    await tester.pumpAndSettle();
    expect(up.started, isEmpty);
    expect(find.text("Make this book's file smaller?"), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-drop-zone')), findsNothing);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pending-start')));
    await tester.pumpAndSettle();
    expect(up.urls.single, contains('compression=off'));
    expect(api.settings.compression, CompressionChoice.lossless);
  });

  testWidgets('multiple books start directly with the saved default', (tester) async {
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CompressionTestApi()..settings = const BuildCompressionSettings(compression: CompressionChoice.balanced);
    final up = FakeRawUploader();
    final c = BuildController(api: api, uploader: up, poll: false);
    addTearDown(c.dispose);
    await c.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: BuildPage(build: c, initialFiles: [FakeLocalFile('a.pdf', 1024), FakeLocalFile('b.pdf', 2048)]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('library-name')), 'Field books');
    await tester.pumpAndSettle();
    expect(find.text("Make this book's file smaller?"), findsNothing);
    expect(up.urls, hasLength(2));
    expect(up.urls.every((url) => url.contains('compression=smaller_scans&preset=balanced')), isTrue);
  });

  testWidgets('cancelling the Library single-book choice uploads nothing', (tester) async {
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CompressionTestApi()..libs = [const BuildLibrary(id: 'field', title: 'Field books')];
    final up = FakeRawUploader();
    final c = BuildController(api: api, uploader: up, poll: false, pickPdfs: () async => [FakeLocalFile('one.pdf', 1024)]);
    addTearDown(c.dispose);
    await c.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(CacheThemeId.light),
        home: BuiltLibraryPage(build: c, libraryId: 'field'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add PDFs'));
    await tester.pumpAndSettle();
    expect(find.text('Add this PDF'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(up.started, isEmpty);
  });

  test('changing the default does not change a queued browser upload entry', () async {
    final api = CompressionTestApi();
    final up = FakeRawUploader();
    final c = BuildController(api: api, uploader: up, poll: false, concurrency: 1);
    await c.refresh();
    await c.loadCompressionSettings();
    await c.addFiles([FakeLocalFile('a.pdf', 1024), FakeLocalFile('b.pdf', 1024)], newTitle: 'Field books');
    expect(up.urls, hasLength(1));
    await c.saveCompressionSettings(const BuildCompressionSettings(compression: CompressionChoice.off));
    up.started.first.finish({'id': 'first'});
    await Future<void>.delayed(Duration.zero);
    expect(up.urls, hasLength(2));
    expect(up.urls.last, contains('compression=lossless'));
    up.finishAll();
    await c.upload!.done;
    c.dispose();
  });
}
