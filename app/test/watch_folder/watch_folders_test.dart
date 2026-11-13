// Watch a folder's rules, on real folders in a temporary directory (the same folder access Add a folder uses, with plain paths):
// new-file detection by content hash (a rename or a move is not added again, a removed PDF stays, changed content is new),
// skip-and-count for a PDF that could not be added (never tried again by a check by itself, Try again once more), a folder that
// can't be reached (the others keep being checked, Choose again), what is kept across restarts, and when checks run (on open; on
// Android every 30 minutes as index work under the indexing rules: charging, battery, Cache open).

import 'dart:io';

import 'package:cache/library/add_pdf/add_pdf_state.dart';
import 'package:cache/library/add_pdf/watch_folders.dart';
import 'package:cache/platform/battery.dart';
import 'package:cache/search/index_scheduler.dart';
import 'package:cache/settings/space.dart';
import 'package:flutter_test/flutter_test.dart';

import '../add_pdf/add_pdf_fixtures.dart';

const _lib = AddPdfTarget(title: 'My books', path: '/tmp/my-books');

void main() {
  late Directory tmp;
  late Directory manuals;
  late AddPdfState pdf;
  late WatchFoldersState w;
  late DateTime now;

  WatchFoldersState make({Duration? every = kWatchEvery}) =>
      WatchFoldersState(addPdf: pdf, dir: () async => Directory('${tmp.path}/ingest'), every: every, clock: () => now);

  setUp(() {
    now = DateTime(2026, 11, 9, 12);
    tmp = Directory.systemTemp.createTempSync('watch-folders');
    manuals = Directory('${tmp.path}/Manuals')..createSync();
    pdf = testAddPdfState(Directory('${tmp.path}/ingest'));
    w = make();
  });

  tearDown(() {
    w.dispose();
    pdf.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File put(String rel, String content, {Directory? dir, DateTime? at}) {
    final f = File('${(dir ?? manuals).path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    if (at != null) f.setLastModifiedSync(at);
    return f;
  }

  Future<WatchedFolder> watch({bool add = true, Directory? dir, String name = 'Manuals'}) async {
    final f = await w.watch(root: (dir ?? manuals).path, name: name, target: _lib, addExisting: add);
    // the first check runs at once; a check after it waits its turn, so this returns when the first is done
    await w.check(f);
    return f;
  }

  Set<String?> sources() => {for (final j in pdf.jobs) j.sourcePath};

  group('new files', () {
    test('Watch and add: every PDF in the folder and its subfolders is queued once, tagged with the folder, through Add PDF', () async {
      put('Water filter guide.pdf', 'pdf one');
      put('Pumps/Pump repair notes.PDF', 'pdf two');
      put('readme.txt', 'not a pdf');
      put('.hidden.pdf', 'hidden');
      put('.trash/old.pdf', 'hidden folder');
      final f = await watch();
      expect(sources(), {'Water filter guide.pdf', 'Pumps/Pump repair notes.PDF'});
      for (final j in pdf.jobs) {
        expect(j.watchId, f.id);
        expect(j.watchName, 'Manuals');
        expect(j.folderRoot, manuals.path);
        expect(j.libraryPath, '/tmp/my-books');
        expect(j.watchHash, hasLength(64));
        expect(j.status, AddPdfStatus.active);
      }
      // one check: one summary card later
      expect({for (final j in pdf.jobs) j.checkId}, hasLength(1));
      expect(f.pending, hasLength(2));
      expect(f.lastCheck, now);
      expect(f.where, manuals.path);
      // a second check finds nothing new
      await w.check(f);
      expect(pdf.jobs, hasLength(2));
    });

    test('Watch new PDFs only: what is there is noted, not added; a PDF that comes later is', () async {
      put('a.pdf', 'one');
      put('b.pdf', 'two');
      final f = await watch(add: false);
      expect(pdf.jobs, isEmpty);
      expect(f.hashes, hasLength(2));
      put('c.pdf', 'three');
      await w.check(f);
      expect(sources(), {'c.pdf'});
    });

    test('a renamed or moved PDF is not added again: it is known by its content, not its path', () async {
      final a = put('a.pdf', 'one');
      final f = await watch();
      expect(pdf.jobs, hasLength(1));
      Directory('${manuals.path}/Moved').createSync();
      a.renameSync('${manuals.path}/Moved/a renamed.pdf');
      await w.check(f);
      expect(pdf.jobs, hasLength(1));
      expect(f.files.keys, ['Moved/a renamed.pdf']);
      // a second copy of the same file under another name is not added either
      put('copy of a.pdf', 'one');
      await w.check(f);
      expect(pdf.jobs, hasLength(1));
    });

    test('a PDF removed from the folder stays in Cache, and is not added again when it comes back', () async {
      final a = put('a.pdf', 'one');
      put('b.pdf', 'two');
      final f = await watch();
      final job = pdf.jobs.firstWhere((j) => j.sourcePath == 'a.pdf');
      a.deleteSync();
      await w.check(f);
      expect(pdf.byId(job.id), isNotNull, reason: 'its job (and so its book) is untouched');
      expect(f.files.keys, ['b.pdf']);
      expect(f.hashes, hasLength(2));
      put('a.pdf', 'one');
      await w.check(f);
      expect(pdf.jobs, hasLength(2));
    });

    test('new content under the same name is a new PDF', () async {
      put('a.pdf', 'one', at: DateTime(2026, 11, 1));
      final f = await watch();
      put('a.pdf', 'one, second edition', at: DateTime(2026, 11, 5));
      await w.check(f);
      expect(pdf.jobs, hasLength(2));
    });

    test('a file that has not changed is not read again', () async {
      put('a.pdf', 'one');
      final f = await watch();
      final before = f.files['a.pdf'];
      // the kept hash is used as it is: a wrong one would show if the file were read again
      f.files['a.pdf'] = (size: before!.size, mtime: before.mtime, hash: 'kept');
      await w.check(f);
      expect(f.files['a.pdf']!.hash, 'kept');
    });
  });

  group('skip and count', () {
    test('a PDF that could not be added is counted on the folder, never tried again by a check; Try again queues it once more', () async {
      put('a.pdf', 'damaged');
      final f = await watch();
      final job = pdf.jobs.single;
      job
        ..status = AddPdfStatus.failed
        ..errorCode = 'damaged';
      pdf.debugSet(pdf.jobs);
      expect(f.pending, isEmpty);
      expect(f.skipped.single.path, 'a.pdf');
      expect(f.skipped.single.jobId, job.id);
      expect(f.added, 0);
      await w.check(f);
      await w.check(f);
      expect(pdf.jobs, hasLength(1), reason: 'not tried again at every check');
      expect(f.skipped, hasLength(1));
      await w.tryAgain(f);
      expect(job.status, AddPdfStatus.active);
      expect(f.skipped, isEmpty);
      expect(f.pending, [job.id]);
      job.status = AddPdfStatus.done;
      pdf.debugSet(pdf.jobs);
      expect(f.added, 1);
      expect(f.pending, isEmpty);
    });

    test('Try again after the stopped card was put away queues the PDF as a new job', () async {
      put('a.pdf', 'locked');
      final f = await watch();
      final job = pdf.jobs.single;
      job.status = AddPdfStatus.failed;
      pdf.debugSet(pdf.jobs);
      await pdf.cancel(job);
      expect(f.skipped, hasLength(1));
      await w.tryAgain(f);
      expect(pdf.jobs.single.sourcePath, 'a.pdf');
      expect(pdf.jobs.single.id, isNot(job.id));
      expect(f.pending, [pdf.jobs.single.id]);
    });

    test('a stopped PDF tried again on the progress page is pending again', () async {
      put('a.pdf', 'no text');
      final f = await watch();
      final job = pdf.jobs.single;
      job.status = AddPdfStatus.failed;
      pdf.debugSet(pdf.jobs);
      await pdf.retry(job);
      expect(f.skipped, isEmpty);
      expect(f.pending, [job.id]);
    });

    test('a PDF the person stopped while it was being added is not counted and not added again', () async {
      put('a.pdf', 'one');
      final f = await watch();
      await pdf.cancel(pdf.jobs.single);
      expect(f.pending, isEmpty);
      expect(f.skipped, isEmpty);
      expect(f.added, 0);
      await w.check(f);
      expect(pdf.jobs, isEmpty);
    });

    test('each added PDF is counted', () async {
      put('a.pdf', 'one');
      put('b.pdf', 'two');
      final f = await watch();
      for (final j in pdf.jobs) {
        j.status = AddPdfStatus.done;
      }
      pdf.debugSet(pdf.jobs);
      expect(f.added, 2);
    });
  });

  group('a folder that cannot be reached', () {
    test('is marked and paused, keeps its counts; the other folders keep being checked; Choose again adds only what is new', () async {
      put('a.pdf', 'one');
      final f1 = await watch();
      final field = Directory('${tmp.path}/Field guides')..createSync();
      put('x.pdf', 'field one', dir: field);
      final f2 = await watch(dir: field, name: 'Field guides');
      f1.added = 7;
      final checked = f1.lastCheck;
      manuals.deleteSync(recursive: true);
      put('y.pdf', 'field two', dir: field);
      now = now.add(const Duration(hours: 1));
      await w.checkAll();
      expect(f1.unreachable, isTrue);
      expect(f1.lastCheck, checked, reason: 'the last check that reached it');
      expect(f1.added, 7);
      expect(w.unreachable, 1);
      expect(sources(), {'a.pdf', 'x.pdf', 'y.pdf'});
      // the automatic checks leave it until Choose again
      expect(w.due, isNot(contains(f1)));
      // Choose again: a folder with the PDF it already added and a new one
      final again = Directory('${tmp.path}/Manuals again')..createSync();
      put('a.pdf', 'one', dir: again);
      put('b.pdf', 'two', dir: again);
      await w.chooseAgain(f1, root: again.path, name: 'Manuals again');
      expect(f1.unreachable, isFalse);
      expect(f1.root, again.path);
      expect(f1.added, 7);
      expect(sources(), {'a.pdf', 'x.pdf', 'y.pdf', 'b.pdf'});
      expect(pdf.jobs.where((j) => j.sourcePath == 'a.pdf'), hasLength(1));
      expect(f2.unreachable, isFalse);
    });
  });

  test('the folders, their counts and what they have seen are kept across restarts', () async {
    put('a.pdf', 'one');
    final f = await watch();
    f
      ..added = 3
      ..skipped.add(const WatchSkip(path: 'bad.pdf', name: 'bad.pdf', hash: 'h', bytes: 9));
    await w.save();
    final again = make();
    await again.load();
    final g = again.folders.single;
    expect(g.id, f.id);
    expect(g.root, manuals.path);
    expect(g.name, 'Manuals');
    expect(g.added, 3);
    expect(g.lastCheck, f.lastCheck);
    expect(g.hashes, f.hashes);
    expect(g.files.keys, ['a.pdf']);
    expect(g.pending, f.pending);
    expect(g.skipped.single.path, 'bad.pdf');
    again.dispose();
    // and the job keeps its folder
    final kept = AddPdfJob.fromJson(pdf.jobs.single.toJson());
    expect(kept.watchId, f.id);
    expect(kept.watchName, 'Manuals');
    expect(kept.checkId, pdf.jobs.single.checkId);
    expect(kept.watchHash, pdf.jobs.single.watchHash);
  });

  test('Stop watching forgets the folder; what it added and queued stays', () async {
    put('a.pdf', 'one');
    final f = await watch();
    await w.stop(f);
    expect(w.folders, isEmpty);
    expect(pdf.jobs, hasLength(1));
  });

  test('where a folder is, from an Android tree, an iOS bookmark or a path', () {
    expect(watchWhere('content://com.android.externalstorage.documents/tree/primary%3ADownload%2FManuals', 'Manuals'), 'Download/Manuals');
    expect(watchWhere('bookmark:abc', 'Manuals'), 'Manuals');
    expect(watchWhere('/home/me/Manuals', 'Manuals'), '/home/me/Manuals');
    expect(isWatchedPdf('a/B.PDF'), isTrue);
    expect(isWatchedPdf('.a/b.pdf'), isFalse);
    expect(isWatchedPdf('a/b.txt'), isFalse);
  });

  group('when it checks', () {
    test('Android: a check is due every 30 minutes as long index work; never for a folder that cannot be reached', () async {
      put('a.pdf', 'one');
      final f = await watch();
      expect(await w.pending(), isEmpty, reason: 'just checked');
      now = now.add(const Duration(minutes: 29));
      expect(await w.pending(), isEmpty);
      now = now.add(const Duration(minutes: 1));
      final t = (await w.pending()).single;
      expect(t.key, '$kWatchCheckKind/folders');
      expect(t.long, isTrue, reason: 'it waits for charging or half a battery, and pauses for a low battery and heat');
      expect(t.anyway, isFalse);
      f.unreachable = true;
      expect(await w.pending(), isEmpty);
    });

    test('iOS: no background check; only on open', () async {
      w.dispose();
      w = make(every: null);
      put('a.pdf', 'one');
      final f = await watch();
      now = now.add(const Duration(days: 1));
      expect(await w.pending(), isEmpty);
      put('b.pdf', 'two');
      await w.checkAll();
      expect(sources(), {'a.pdf', 'b.pdf'});
      expect(f.lastCheck, now);
    });

    test('on open: a folder checked within the last minute is left', () async {
      put('a.pdf', 'one');
      final f = await watch();
      put('b.pdf', 'two');
      now = now.add(const Duration(seconds: 30));
      await w.checkAll(minGap: const Duration(minutes: 1));
      expect(pdf.jobs, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      await w.checkAll(minGap: const Duration(minutes: 1));
      expect(pdf.jobs, hasLength(2));
      expect(f.lastCheck, now);
    });

    group('the index scheduler runs the check under the indexing rules', () {
      BatteryReading? battery;
      late IndexScheduler s;

      Future<void> until(bool Function() ok) async {
        for (var i = 0; i < 200 && !ok(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      Future<WatchedFolder> dueFolder() async {
        put('a.pdf', 'one');
        final f = await watch();
        put('b.pdf', 'two');
        now = now.add(kWatchEvery);
        // only the check: the Add PDF jobs are not this scheduler's work here
        s = IndexScheduler(sources: [w], space: () => const Space(free: 100 << 30, reserve: 1 << 30), battery: () async => battery);
        return f;
      }

      tearDown(() => s.dispose());

      test('on battery at half or less, it waits for charging', () async {
        battery = const BatteryReading(percent: 38, charging: false);
        final f = await dueFolder();
        s.setOpen(true);
        await s.kick();
        expect(s.statusOf('$kWatchCheckKind/folders')?.why, IndexWait.charging);
        expect(f.files.keys, ['a.pdf']);
      });

      test('a low battery holds it', () async {
        battery = const BatteryReading(percent: 15, charging: false);
        await dueFolder();
        s.setOpen(true);
        await s.kick();
        expect(s.statusOf('$kWatchCheckKind/folders')?.why, IndexWait.battery);
      });

      test('while Cache is closed it does not run', () async {
        battery = const BatteryReading(percent: 90, charging: true);
        final f = await dueFolder();
        await s.kick();
        expect(f.files.keys, ['a.pdf']);
        expect(s.running, isNull);
      });

      test('charging: it runs, and finds the new PDF', () async {
        battery = const BatteryReading(percent: 60, charging: true);
        final f = await dueFolder();
        s.setOpen(true);
        await s.kick();
        await until(() => f.files.length == 2 && !f.checking);
        expect(sources(), {'a.pdf', 'b.pdf'});
        expect(f.lastCheck, now);
        await until(() => s.running == null);
        expect(await w.pending(), isEmpty, reason: 'not due again for 30 minutes');
      });
    });
  });
}
