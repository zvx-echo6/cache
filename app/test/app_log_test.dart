import 'dart:io';

import 'package:cache/platform/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late DateTime now;
  late List<String> echoed;
  late List<AppLog> opened;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('app-log');
    now = DateTime(2026, 11, 3, 12);
    echoed = [];
    opened = [];
  });
  tearDown(() async {
    for (final log in opened) {
      await log.close();
    }
    await appLog.close();
    dir.deleteSync(recursive: true);
  });

  Future<AppLog> open({int fileBytes = kLogFileBytes, int files = kLogFiles}) async {
    final log = AppLog(clock: () => now, fileBytes: fileBytes, files: files, echo: echoed.add);
    await log.open(dir);
    opened.add(log);
    return log;
  }

  Future<String> text(AppLog log) async {
    await log.flush();
    return [for (final f in log.logFiles.reversed) f.readAsStringSync()].join();
  }

  test('each level writes what the one before writes, and more; Standard is the default', () async {
    final log = await open();
    expect(log.level, LogLevel.standard);
    void all() {
      log.add(LogLevel.minimal, 'ERROR', 'a failure');
      log.add(LogLevel.standard, 'INFO', 'a step');
      log.add(LogLevel.detailed, 'DETAIL', 'a file name');
      log.add(LogLevel.everything, 'CONTENT', 'a question');
    }

    all();
    var t = await text(log);
    expect((t.contains('a failure'), t.contains('a step'), t.contains('a file name'), t.contains('a question')), (true, true, false, false));
    await log.setLevel(LogLevel.minimal);
    await log.clear();
    all();
    t = await text(log);
    expect((t.contains('a failure'), t.contains('a step'), t.contains('a file name')), (true, false, false));
    await log.setLevel(LogLevel.detailed);
    await log.clear();
    all();
    t = await text(log);
    expect((t.contains('a file name'), t.contains('a question')), (true, false));
    expect(echoed.where((l) => l.contains('a failure')), isNotEmpty, reason: 'every line also goes to the system log');
  });

  test('an error is named by its type below Detailed (its text can hold file names); its text from Detailed', () async {
    await appLog.open(dir);
    await appLog.setLevel(LogLevel.standard);
    logError('Could not remove an index', error: const FileSystemException('x', '/data/secret/name.zim'), detail: 'name.zim');
    logInfo('PDF 3 of 37 starts', detail: 'Manuals/water.pdf');
    var t = await text(appLog);
    expect(t, contains('Could not remove an index: FileSystemException'));
    expect(t, contains('PDF 3 of 37 starts'));
    expect(t, isNot(contains('/data/secret')));
    expect(t, isNot(contains('water.pdf')));
    await appLog.setLevel(LogLevel.detailed);
    logInfo('PDF 4 of 37 starts', detail: 'Manuals/fire.pdf');
    t = await text(appLog);
    expect(t, contains('PDF 4 of 37 starts: Manuals/fire.pdf'));
    await appLog.setLevel(LogLevel.standard);
  });

  test('Everything goes back to the level before it after 24 hours, and says so', () async {
    var log = await open();
    await log.setLevel(LogLevel.detailed);
    await log.setLevel(LogLevel.everything);
    expect(log.everythingUntil, now.add(kLogEverythingFor));
    now = now.add(const Duration(hours: 23));
    expect(log.level, LogLevel.everything);
    // the level is kept on the device: a new start still has it, with its end
    log = await open();
    expect(log.level, LogLevel.everything);
    now = now.add(const Duration(hours: 1, minutes: 1));
    expect(log.level, LogLevel.detailed, reason: 'back to the level before it');
    expect(log.everythingUntil, isNull);
    expect(await text(log), contains('Log level back to Detailed after 24 hours of Everything'));
    log = await open();
    expect(log.level, LogLevel.detailed, reason: 'and that is kept');
  });

  test('Turn off on the banner ends Everything at once', () async {
    final log = await open();
    await log.setLevel(LogLevel.everything);
    await log.endEverything();
    expect((log.level, log.everythingUntil), (LogLevel.standard, null));
  });

  test('a full file turns over: at most the set number of files, the oldest dropped', () async {
    final log = await open(fileBytes: 200, files: 3);
    for (var i = 0; i < 60; i++) {
      log.add(LogLevel.standard, 'INFO', 'line $i ${'x' * 20}');
      await log.flush();
    }
    await log.flush();
    final files = log.logFiles;
    expect(files.length, lessThanOrEqualTo(3));
    expect(files.length, greaterThan(1));
    for (final f in files.skip(1)) {
      expect(f.lengthSync(), lessThan(400), reason: 'each turned-over file stays near the cap');
    }
    final t = await text(log);
    expect(t, contains('line 59'));
    expect(t, isNot(contains('line 0 ')), reason: 'the oldest went');
  });

  test("a job's Details keep its last lines, at any level", () async {
    final log = await open();
    await log.setLevel(LogLevel.minimal);
    for (var i = 0; i < kLogJobLines + 5; i++) {
      log.add(LogLevel.standard, 'INFO', 'PDF $i of 37', job: 'zim-pdf/w');
    }
    final lines = log.jobLines('zim-pdf/w');
    expect(lines, hasLength(kLogJobLines));
    expect(lines.last, endsWith('PDF ${kLogJobLines + 4} of 37'));
    expect(await text(log), isNot(contains('PDF 3 of 37')), reason: 'Minimal writes none of them to the file');
  });
}
