import 'dart:io';

import 'package:cache/browse/browse_screen.dart';
import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/catalogue_screen.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/device_flows.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/browse/web/device_widgets.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'web_fakes.dart';

Widget app(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: Scaffold(body: child));

Widget screen(Widget child) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: child);

void main() {
  late Directory tmp;
  late FakeSources sources;
  late FakeDeviceApi api;
  late MemoryAppFs fs;
  late FakeUploader uploader;
  late DeviceLibrary device;
  late BrowseState browse;

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('weblib');
    sources = FakeSources(Directory('${tmp.path}/zims')..createSync());
    api = FakeDeviceApi();
    fs = MemoryAppFs();
    uploader = FakeUploader();
    device = DeviceLibrary(api: api, fs: fs, uploader: uploader, leaveWarning: (_) {});
    browse = BrowseState(
      sources: sources,
      catalog: catalogWith(recorded),
      settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
      phoneLanguage: 'en',
      device: device,
    );
  });
  tearDown(() {
    browse.dispose();
    device.dispose();
    tmp.deleteSync(recursive: true);
  });

  void wide(WidgetTester tester) {
    // Wide enough for two panes, just under the desktop layout (1280), which has its own tests (web_desktop_test.dart).
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> show(WidgetTester tester) async {
    wide(tester);
    await tester.runAsync(() async {
      await browse.init();
      await device.refresh();
    });
    await tester.pumpWidget(screen(BrowseScreen(browse: browse, active: true)));
    await tester.pumpAndSettle();
  }

  group('the Library list in a browser', () {
    testWidgets('nothing yet: the empty words say "this device", and the storage footer is always there', (tester) async {
      api.spaceInfo = const DeviceSpaceInfo(free: 50 << 30, total: 500 << 30);
      await show(tester);
      expect(find.textContaining('They are kept on this device and work with no internet.'), findsOneWidget);
      expect(find.textContaining('no signal'), findsNothing);
      expect(find.text('Device storage'), findsOneWidget);
      expect(find.textContaining('free of 500.0 GB', findRichText: true), findsOneWidget);
      expect(find.textContaining('Cache keeps 20 GB free for the device'), findsOneWidget);
      expect(find.text('Add to Library'), findsOneWidget);
    });

    testWidgets('the footer says what is still to download and what will be free after; a transfer is a card with a Cancel', (tester) async {
      api.spaceInfo = const DeviceSpaceInfo(free: 50 << 30, total: 500 << 30);
      api.itemList = [item('a.zim', bytes: 10 << 30)];
      api.jobList = [job('j1', 'running', bytes: 1 << 30, total: 5 << 30, name: 'wiki.zim')];
      await show(tester);
      expect(find.textContaining('4.0 GB still to download, 46.0 GB will be free after'), findsOneWidget);
      expect(find.text('Downloads keep going if you close this tab.'), findsOneWidget);
      expect(find.text('wiki.zim'), findsOneWidget);
      expect(find.text('Downloading · 1.0 GB of 5.0 GB'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsNothing, reason: 'there is no pause in a browser');
      await tester.tap(find.byKey(const ValueKey('cancel-j1')));
      await tester.pumpAndSettle();
      expect(api.cancelled, contains('j1'));
    });

    testWidgets('a transfer that stopped has Try again and Dismiss, in words that do not name the machine', (tester) async {
      api.jobList = [job('f1', 'failed', error: 'Not enough free space on the server: 5 MB needed, 1 MB free.')];
      await show(tester);
      expect(find.text('Not enough space on this device.'), findsOneWidget);
      expect(find.textContaining('server'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('retry-f1')));
      await tester.pump();
      await tester.pump();
      expect(api.downloads.single['url'], 'https://dl.example/f1.zim');
    });

    testWidgets('"While this tab was closed" lists what finished, still runs or stopped, and Dismiss clears it', (tester) async {
      api.jobList = [job('j1', 'running', bytes: 1, total: 9, name: 'WikiMed.zim'), job('j2', 'running', name: 'Wikipedia.zim'), job('j3', 'running', name: 'Guides.zim')];
      await tester.runAsync(device.start);
      api.jobList = [job('j1', 'done', name: 'WikiMed.zim'), job('j2', 'running', bytes: 5, total: 9, name: 'Wikipedia.zim'), job('j3', 'failed', name: 'Guides.zim', error: 'x')];
      // a second visit
      browse.dispose();
      device.dispose();
      device = DeviceLibrary(api: api, fs: fs, uploader: uploader, leaveWarning: (_) {});
      browse = BrowseState(sources: sources, catalog: catalogWith(recorded), settingsDirOverride: Directory('${tmp.path}/s'), phoneLanguage: 'en', device: device);
      await tester.runAsync(device.start);
      wide(tester);
      await tester.pumpWidget(screen(BrowseScreen(browse: browse, active: true)));
      await tester.pumpAndSettle();
      expect(find.text('While this tab was closed'), findsOneWidget);
      expect(find.text('•  WikiMed.zim finished.'), findsOneWidget);
      expect(find.text('•  Wikipedia.zim is still downloading.'), findsOneWidget);
      expect(find.text('•  Guides.zim stopped.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dismiss-while-closed')));
      await tester.pumpAndSettle();
      expect(find.text('While this tab was closed'), findsNothing);
      // the running one is still there as a card
      expect(find.byKey(const ValueKey('job-j2')), findsOneWidget);
    });

    testWidgets('"While this tab was closed" says when it finished or stopped, and when the running one started, in local time', (tester) async {
      final n = DateTime.now();
      final yesterday = DateTime(n.year, n.month, n.day - 1, 22, 10).toUtc();
      final early = DateTime(n.year, n.month, n.day, 3, 12).toUtc();
      final stop = DateTime(n.year, n.month, n.day, 9, 5).toUtc();
      api.jobList = [job('j1', 'running', name: 'WikiMed.zim'), job('j2', 'running', name: 'Wikipedia.zim'), job('j3', 'running', name: 'Guides.zim')];
      await tester.runAsync(device.start);
      api.jobList = [
        job('j1', 'done', name: 'WikiMed.zim', createdAt: yesterday, finishedAt: early),
        job('j2', 'running', bytes: 5, total: 9, name: 'Wikipedia.zim', createdAt: yesterday),
        job('j3', 'failed', name: 'Guides.zim', error: 'x', createdAt: yesterday, finishedAt: stop),
      ];
      browse.dispose();
      device.dispose();
      device = DeviceLibrary(api: api, fs: fs, uploader: uploader, leaveWarning: (_) {});
      browse = BrowseState(sources: sources, catalog: catalogWith(recorded), settingsDirOverride: Directory('${tmp.path}/s'), phoneLanguage: 'en', device: device);
      await tester.runAsync(device.start);
      wide(tester);
      await tester.pumpWidget(screen(BrowseScreen(browse: browse, active: true)));
      await tester.pumpAndSettle();
      expect(find.text('•  WikiMed.zim finished at 03:12.'), findsOneWidget);
      expect(find.text('•  Wikipedia.zim is still downloading, started yesterday 22:10.'), findsOneWidget);
      expect(find.text('•  Guides.zim stopped at 09:05.'), findsOneWidget);
      expect(find.textContaining('started yesterday 22:10'), findsNWidgets(2), reason: 'the running card says it too');
      expect(startedWords(early, now: DateTime(n.year, n.month, n.day, 12)), '03:12');
      expect(startedWords(DateTime(2026, 10, 3, 22, 10), now: DateTime(2026, 11, 1, 12)), '3 Oct 22:10');
    });

    testWidgets('an upload is a card with the name, bytes and Cancel; the hint and the footer say to keep the tab open', (tester) async {
      await show(tester);
      final sent = device.send(FakeLocalFile('wikipedia_fr_all_nopic_2026-09.zim', 4000));
      uploader.started.single.progress(1000);
      await tester.pump();
      expect(find.text('Uploading'), findsOneWidget);
      expect(find.textContaining('wikipedia_fr_all_nopic_2026-09.zim'), findsOneWidget);
      expect(find.textContaining('1000 B of 4 KB'), findsOneWidget);
      expect(find.text('Keep this tab open until the upload ends. Downloads and indexing carry on without it.'), findsOneWidget);
      expect(find.textContaining('3 KB still to upload'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-upload')));
      await tester.pump();
      expect(uploader.started.single.cancelled, isTrue);
      await sent;
      await tester.pump();
      expect(find.text('Uploading'), findsNothing);
    });

    testWidgets('when every byte is there the card says the device is putting it in place, and Cancel is gone', (tester) async {
      await show(tester);
      final sent = device.send(FakeLocalFile('x.zim', 4000));
      uploader.started.single.progress(4000);
      await tester.pump();
      expect(find.textContaining('Putting it in place…'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('cancel-upload'))).onPressed, isNull);
      uploader.started.single.finish({'name': 'x.zim'});
      await sent;
      await tester.pump();
      expect(find.text('Uploading'), findsNothing);
    });

    testWidgets('a failed upload stays as a card with the reason until OK', (tester) async {
      await show(tester);
      final sent = device.send(FakeLocalFile('big.zim', 4000));
      uploader.started.single.fail(const DeviceException('no_space', 'x', status: 507));
      await sent;
      await tester.pump();
      expect(find.text('Not enough space on this device. The partly uploaded file was removed.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dismiss-upload')));
      await tester.pump();
      expect(find.textContaining('partly uploaded'), findsNothing);
    });

    testWidgets('with something in the Library and nothing going on, the line about changing icons is not there (a browser cannot)', (tester) async {
      File('${sources.zimsDir!.path}/one.zim').writeAsBytesSync(List.filled(2048, 0));
      await sources.refresh();
      await show(tester);
      expect(find.byKey(const ValueKey('zim-one.zim')), findsOneWidget);
      expect(find.textContaining('Icons come from'), findsNothing);
    });

    testWidgets('a library package that was downloaded waits as a card with Add', (tester) async {
      api.jobList = [job('p1', 'done', kind: 'library', name: 'pack.cache-library')];
      await show(tester);
      expect(find.text('pack.cache-library'), findsOneWidget);
      expect(find.text('Downloaded. Ready to add to your library.'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-package-p1')), findsOneWidget);
    });

    testWidgets('deleting a ZIM that was uploaded says it comes back only by uploading it again; one that was downloaded keeps the phone\'s line', (tester) async {
      File('${sources.zimsDir!.path}/up.zim').writeAsBytesSync(List.filled(2048, 0));
      File('${sources.zimsDir!.path}/dl.zim').writeAsBytesSync(List.filled(2048, 0));
      await sources.refresh();
      for (final z in sources.zims) {
        sources.titles[z.path] = z.fileName == 'up.zim' ? 'Uploaded one' : 'Downloaded one';
      }
      await show(tester);
      final sent = device.send(FakeLocalFile('up.zim', 10));
      uploader.started.single.finish({'name': 'up.zim'});
      await sent;
      await tester.pump();
      await tester.longPress(find.text('Uploaded one'));
      await tester.pumpAndSettle();
      expect(find.text('Change icon'), findsNothing, reason: 'the picture is a file beside the ZIM on a phone');
      await tester.tap(find.textContaining('Delete · frees'));
      await tester.pumpAndSettle();
      expect(find.text('You uploaded this file. To get it back, upload it again.'), findsOneWidget);
      expect(find.textContaining('80.0 GB free now'), findsOneWidget, reason: 'the confirm shows the device\'s storage, as on a phone');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Downloaded one'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Delete · frees'));
      await tester.pumpAndSettle();
      expect(find.text('You can download it again later.'), findsOneWidget);
    });
  });

  group('Add to Library in a browser', () {
    testWidgets('the first section is "From this computer", with the drop zone and Choose a file', (tester) async {
      wide(tester);
      await tester.runAsync(browse.init);
      await tester.pumpWidget(screen(AddToLibraryScreen(browse: browse)));
      await tester.pumpAndSettle();
      expect(find.text('FROM THIS COMPUTER'), findsOneWidget);
      expect(find.text('Drop a file here'), findsOneWidget);
      expect(find.text('A .zim file, a .cache-library file or a library snapshot. Files of several GB are fine.'), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-file')), findsOneWidget);
      expect(tester.getTopLeft(find.text('FROM THIS COMPUTER')).dy, lessThan(tester.getTopLeft(find.text('READY-MADE COLLECTIONS · FREE FROM KIWIX')).dy));
    });

    testWidgets('a download asks first, says it keeps going with the tab closed, and sends the link, name, origin and icon', (tester) async {
      wide(tester);
      await tester.runAsync(() async {
        await browse.init();
        await device.refresh();
      });
      await tester.pumpWidget(screen(AddToLibraryScreen(browse: browse)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download Wikivoyage - Europe').first);
      await tester.pumpAndSettle();
      expect(find.text('Download Wikivoyage - Europe?'), findsOneWidget);
      expect(find.text('It keeps downloading if you close this tab.'), findsOneWidget);
      expect(find.text('Device storage'), findsOneWidget);
      expect(find.text('Wait for Wi-Fi'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('confirm-download')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final sent = api.downloads.single;
      expect(sent['kind'], 'zim');
      expect(sent['url'], startsWith('https://'));
      expect(sent['name'], endsWith('.zim'));
      expect((sent['origin'] as Map)['title'], 'Wikivoyage - Europe');
      expect(find.text('Download started. It keeps downloading if you close this tab.'), findsOneWidget);
      // the entry now shows the device's transfer, not a download button
      expect(find.byTooltip('Download Wikivoyage - Europe'), findsOneWidget, reason: 'the other variant is still offered');
    });

    testWidgets('a download that does not fit says so, with the phone\'s own dialog', (tester) async {
      api.spaceInfo = const DeviceSpaceInfo(free: 20 << 30, total: 500 << 30);
      wide(tester);
      await tester.runAsync(() async {
        await browse.init();
        await device.refresh();
      });
      await tester.pumpWidget(screen(AddToLibraryScreen(browse: browse)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download Wikivoyage - Europe').first);
      await tester.pumpAndSettle();
      expect(find.text('Not enough space'), findsOneWidget);
      expect(find.textContaining('Cache keeps 20.0 GB free for the device.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.downloads, isEmpty);
    });

    testWidgets('a download that is running shows on its entry from the device\'s transfer list', (tester) async {
      wide(tester);
      await tester.runAsync(() async {
        await browse.init();
        await browse.loadFirstPage();
      });
      final e = browse.entries.first;
      api.jobList = [job('j9', 'running', url: e.downloadUrl.toString(), bytes: 100, total: 1000)];
      await tester.runAsync(device.refresh);
      await tester.pumpWidget(screen(AddToLibraryScreen(browse: browse)));
      await tester.pumpAndSettle();
      expect(find.text('Downloading 100 B of 1000 B'), findsOneWidget);
    });
  });

  group('adding a file from this computer', () {
    Future<void> run(WidgetTester tester, FakeLocalFile file) async {
      wide(tester);
      await tester.runAsync(() async {
        await browse.init();
        await device.refresh();
      });
      await tester.pumpWidget(app(Builder(
        builder: (ctx) => Column(children: [
          Expanded(child: FromThisComputer(device: device, onChoose: () {})),
          TextButton(onPressed: () => addFromComputer(ctx, device: device, dropped: file), child: const Text('drop')),
        ]),
      )));
      await tester.tap(find.text('drop'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a file of the wrong type is refused before anything is sent, inline and in a snackbar', (tester) async {
      await run(tester, FakeLocalFile('notes-2026.pdf', 100));
      expect(uploader.started, isEmpty);
      expect(find.text('notes-2026.pdf is not a library file. Choose a .zim file, a .cache-library file or a library snapshot. Nothing was uploaded.'), findsOneWidget);
      expect(find.text('notes-2026.pdf was not uploaded. It is not a library file.'), findsOneWidget);
    });

    testWidgets('a file that does not fit is stopped before sending with the phone\'s "Not enough space" dialog', (tester) async {
      api.spaceInfo = const DeviceSpaceInfo(free: 31 << 30, total: 500 << 30);
      await run(tester, FakeLocalFile('wikipedia_en_all_maxi_2026-09.zim', 78 << 30));
      expect(uploader.started, isEmpty);
      expect(find.text('Not enough space'), findsOneWidget);
      expect(find.textContaining('wikipedia_en_all_maxi_2026-09.zim needs 78.0 GB. You have 11.0 GB to use; Cache keeps 20.0 GB free for the device.'), findsOneWidget);
      expect(find.text('Nothing was uploaded.'), findsOneWidget);
    });

    testWidgets('a ZIM that fits is uploaded under its own name', (tester) async {
      await run(tester, FakeLocalFile('wiki.zim', 5000));
      expect(uploader.started.single.name, 'wiki.zim');
      expect(uploader.started.single.kind, 'zim');
      expect(find.text('Uploading wiki.zim. Keep this tab open.'), findsOneWidget);
      expect(find.text('Uploading wiki.zim'), findsOneWidget, reason: 'the drop zone says one file at a time while it runs');
      uploader.started.single.cancel();
      await tester.pump();
    });
  });
}
