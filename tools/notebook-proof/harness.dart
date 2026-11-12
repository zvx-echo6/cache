import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Kills a process this run started and what it started (by PID only).
Future<void> killTree(int pid) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
  } else {
    await Process.run('pkill', ['-KILL', '-P', '$pid']);
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

class Fail implements Exception {
  Fail(this.msg);
  final String msg;
  @override
  String toString() => msg;
}

/// One device: a separate process with its own data dir and fixed port.
class Device {
  Device(this.h, this.name, this.port);
  final Harness h;
  final String name;
  final int port;
  Process? proc;
  int? testerPid; // the flutter_tester process that holds the dll
  String? build;
  int _seq = 0;
  int _starts = 0;

  Directory get dir => Directory('${h.root}/work/$name');
  String get id => _id ?? '';
  String? _id;

  Future<void> start(String build) async {
    h.guard('start $name on $build');
    await h.freeMemCheck(5);
    this.build = build;
    _seq = 0;
    for (final sub in ['cmd', 'res']) {
      final d = Directory('${dir.path}/$sub');
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    final ready = File('${dir.path}/ready.json');
    if (ready.existsSync()) ready.deleteSync();
    final wfOld = File('${dir.path}/workaround.flag');
    if (wfOld.existsSync()) wfOld.deleteSync();
    dir.createSync(recursive: true);
    final wt = build == 'legacy' ? 'wt-legacy' : 'wt-chain';
    final dll = '${h.root}/dll/$build';
    final log = File('${h.logs.path}/$name-${_starts++}-$build.log').openWrite();
    h.say('start $name ($build) port $port');
    proc = await Process.start(
      Platform.environment['FLUTTER'] ?? (Platform.isWindows ? r'C:\src\flutter\bin\flutter.bat' : 'flutter'),
      ['test', '--timeout', 'none', 'test/proof/device_${build == 'legacy' ? 'legacy' : 'chain'}.dart'],
      workingDirectory: '${h.root}/$wt/app',
      runInShell: Platform.isWindows,
      environment: {
        'PROOF_DIR': dir.path,
        'PROOF_PORT': '$port',
        'PROOF_NAME': name,
        // The native library (cache_search.dll / libcache_search.so) is found through the loader path.
        if (Platform.isWindows) 'PATH': '$dll;${Platform.environment['PATH']}' else 'LD_LIBRARY_PATH': '$dll:${Platform.environment['LD_LIBRARY_PATH'] ?? ''}',
      },
    );
    h.started.add(proc!.pid);
    proc!.stdout.transform(utf8.decoder).listen(log.write);
    proc!.stderr.transform(utf8.decoder).listen(log.write);
    unawaited(proc!.exitCode.then((c) {
      log.writeln('[exit $c]');
      log.close();
    }));
    final end = DateTime.now().add(const Duration(minutes: 6));
    while (!ready.existsSync()) {
      if (DateTime.now().isAfter(end)) throw Fail('$name did not become ready in 6 min (see ${h.logs.path})');
      var exited = false;
      proc!.exitCode.then((_) => exited = true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (exited && !ready.existsSync()) throw Fail('$name exited before it was ready (see its log in ${h.logs.path})');
    }
    testerPid = (jsonDecode(ready.readAsStringSync()) as Map)['pid'] as int?;
    if (testerPid != null) h.started.add(testerPid!);
    final wf = File('${dir.path}/workaround.flag');
    if (wf.existsSync()) {
      wf.deleteSync();
      h.note('workaround: sharing.json enabled flipped to false by SharingState.init', '$name, start #$_starts on $build; the harness put enabled:true back');
    }
    h.say('$name ready (tool pid ${proc!.pid}, device pid $testerPid)');
  }

  Future<dynamic> call(String op, [Map<String, Object?> args = const {}, int timeoutSecs = 240]) async {
    h.guard('$name $op');
    final n = (++_seq).toString().padLeft(4, '0');
    File('${dir.path}/cmd/$n.json').writeAsStringSync(jsonEncode({'op': op, 'args': args}));
    final res = File('${dir.path}/res/$n.json');
    final end = DateTime.now().add(Duration(seconds: timeoutSecs));
    while (!res.existsSync()) {
      if (DateTime.now().isAfter(end)) throw Fail('$name $op timed out after ${timeoutSecs}s');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final j = jsonDecode(await _readRetry(res)) as Map;
    if (j['ok'] != true) throw Fail('$name $op failed: ${j['error']}');
    return j['result'];
  }

  /// Sends a command and does not wait for it (a crash test kills the process while it runs).
  void send(String op, [Map<String, Object?> args = const {}]) {
    final n = (++_seq).toString().padLeft(4, '0');
    File('${dir.path}/cmd/$n.json').writeAsStringSync(jsonEncode({'op': op, 'args': args}));
  }

  /// Windows may hold a just-renamed file for a moment (scanners, indexers): read again.
  static Future<String> _readRetry(File f) async {
    for (var i = 0;; i++) {
      try {
        return f.readAsStringSync();
      } on FileSystemException {
        if (i >= 40) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  /// A clean stop (the app closing); the data dir is then safe to copy.
  Future<void> stop() async {
    if (proc == null) return;
    try {
      await call('quit', const {}, 60);
    } catch (e) {
      h.say('$name quit: $e');
    }
    await _wait(const Duration(seconds: 60));
    proc = null;
  }

  /// A crash: the device process is killed by its PID (as when the app is killed), then the tool process around it.
  Future<void> crash() async {
    h.say('CRASH $name: killing device pid $testerPid');
    if (testerPid != null) Process.killPid(testerPid!, ProcessSignal.sigkill);
    await _wait(const Duration(seconds: 30), kill: true);
    proc = null;
  }

  Future<void> _wait(Duration d, {bool kill = false}) async {
    final p = proc!;
    try {
      await p.exitCode.timeout(d);
    } on TimeoutException {
      h.say('$name did not exit in ${d.inSeconds}s; killing its process tree (pid ${p.pid})');
      await killTree(p.pid);
    }
    if (kill) await killTree(p.pid);
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  Future<Map<String, dynamic>> status() async => ((await call('status')) as Map).cast<String, dynamic>();
  Future<Map<String, dynamic>> dump() async => ((await call('dump')) as Map).cast<String, dynamic>();
  Future<List<String>> files() async => [for (final f in ((await call('files')) as Map)['files'] as List) '$f'];
}

class Harness {
  Harness({required this.root, required this.run, required String deadline}) {
    final p = deadline.split(':');
    _deadlineH = int.parse(p[0]);
    _deadlineM = int.parse(p[1]);
    evidence = Directory('$root/evidence/$run')..createSync(recursive: true);
    logs = Directory('${evidence.path}/logs')..createSync(recursive: true);
    Directory('$root/work').createSync(recursive: true);
    // The watchdog: everything this run started is killed at the deadline.
    Timer.periodic(const Duration(seconds: 20), (_) async {
      if (_past()) {
        say('DEADLINE reached: stopping everything this run started');
        await killAll();
        exit(3);
      }
    });
  }
  final String root;
  final String run;
  late final Directory evidence;
  late final Directory logs;
  late int _deadlineH, _deadlineM;
  final List<int> started = [];
  final devices = <String, Device>{};
  late IOSink _log = File('${evidence.path}/run.log').openWrite(mode: FileMode.append);

  bool _past() {
    final n = DateTime.now();
    return n.hour * 60 + n.minute >= _deadlineH * 60 + _deadlineM;
  }

  void guard(String what) {
    if (_past()) throw Fail('past the $_deadlineH:${_deadlineM.toString().padLeft(2, '0')} deadline; not starting: $what');
  }

  void say(String s) {
    final line = '${DateTime.now().toIso8601String().substring(11, 19)} $s';
    stdout.writeln(line);
    _log.writeln(line);
  }

  Device dev(String name, int port) => devices.putIfAbsent(name, () => Device(this, name, port));

  /// Free memory (GB) via PowerShell; waits until at least [needGb] is free (the owner rule keeps 12 GB for the machine).
  Future<void> freeMemCheck(double extraGb) async {
    for (var i = 0; i < 60; i++) {
      double free;
      if (Platform.isWindows) {
        final r = await Process.run('powershell', ['-NoProfile', '-Command', '[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,1)']);
        free = double.tryParse('${r.stdout}'.trim()) ?? 0;
      } else {
        final m = RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(File('/proc/meminfo').readAsStringSync());
        free = m == null ? 0 : int.parse(m.group(1)!) / 1048576;
      }
      if (free >= 12 + extraGb) return;
      say('free memory $free GB < ${12 + extraGb}: waiting');
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    throw Fail('memory stayed below the 12 GB floor');
  }

  Future<void> killAll() async {
    for (final d in devices.values) {
      if (d.proc != null) {
        await killTree(d.proc!.pid);
        if (d.testerPid != null) Process.killPid(d.testerPid!);
      }
    }
  }

  // ---- files ----
  Future<void> copyDir(String from, String to) async {
    if (Platform.isWindows) {
      final r = await Process.run('robocopy', [from.replaceAll('/', '\\'), to.replaceAll('/', '\\'), '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:1']);
      if (r.exitCode >= 8) throw Fail('robocopy $from -> $to failed (${r.exitCode}): ${r.stdout}');
    } else {
      Directory(to).createSync(recursive: true);
      final r = await Process.run('cp', ['-a', '$from/.', to]);
      if (r.exitCode != 0) throw Fail('cp $from -> $to failed: ${r.stderr}');
    }
  }

  Future<void> wipe(String path) async {
    final d = Directory(path);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  /// Copies the devices' work dirs (the app data: identity, links, notebooks, share folder) to evidence/<run>/<scenario>/<stage>/<name>.
  Future<void> snapshot(String scenario, String stage, Iterable<String> names) async {
    for (final n in names) {
      final dst = '${evidence.path}/$scenario/$stage/$n';
      await wipe(dst);
      await copyDir('$root/work/$n', dst);
    }
    say('evidence: $scenario\\$stage');
  }

  /// Puts work dirs back from a snapshot (a scenario starts from stage 1's data).
  Future<void> restore(String fromScenario, String fromStage, Iterable<String> names) async {
    for (final n in names) {
      await wipe('$root/work/$n');
      await copyDir('${evidence.path}/$fromScenario/$fromStage/$n', '$root/work/$n');
    }
    say('restored $fromScenario\\$fromStage -> work');
  }

  // ---- scenario runner and checks ----
  late List<Map<String, Object?>> _checks;
  late String _scn;
  String get scn => _scn;

  void check(String what, bool ok, [String detail = '']) {
    _checks.add({'check': what, 'ok': ok, if (detail.isNotEmpty) 'detail': detail});
    say('  ${ok ? 'PASS' : 'FAIL'} $what${detail.isEmpty ? '' : '  [$detail]'}');
  }

  /// An observation: recorded in checks.json (ok stays true), not a pass or fail.
  void note(String what, String detail) {
    _checks.add({'check': what, 'ok': true, 'observation': true, 'detail': detail});
    say('  NOTE $what  [$detail]');
  }

  void writeJson(String stage, String name, Object? data, {String? scn}) {
    final d = Directory('${evidence.path}/${scn ?? _scn}/$stage')..createSync(recursive: true);
    File('${d.path}/$name.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  }

  Future<String> runScenario(String name, Future<void> Function(Harness h) f) async {
    _scn = name;
    _checks = [];
    say('=== scenario $name');
    var verdict = 'pass';
    try {
      await f(this);
    } catch (e, st) {
      say('ERROR in $name: $e');
      _checks.add({'check': 'scenario ran to the end', 'ok': false, 'detail': '$e'});
      File('${evidence.path}/$name-error.txt').writeAsStringSync('$e\n$st');
    }
    if (_checks.any((c) => c['ok'] != true)) verdict = 'FAIL';
    final dir = Directory('${evidence.path}/$name')..createSync(recursive: true);
    File('${dir.path}/checks.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_checks));
    for (final d in devices.values) {
      if (d.proc != null) await d.stop();
    }
    say('=== $name: $verdict');
    return verdict;
  }

  /// Rounds of sync over the running devices, in order, [n] times.
  Future<void> rounds(List<Device> ds, {int n = 3}) async {
    for (var i = 0; i < n; i++) {
      for (final d in ds) {
        await d.call('sync');
      }
    }
  }

  /// Compact comparable form of a dump: notebook name -> {fields (labels), entries (id|title|body|values)}.
  static Map<String, dynamic> shape(Map<String, dynamic> dump) => {
        for (final nbk in dump['notebooks'] as List)
          '${(nbk as Map)['name']}': {
            'fields': [for (final f in nbk['fields'] as List) '${(f as Map)['label']}:${f['type']}${f['hidden'] == true ? ':hidden' : ''}'],
            'entries': {for (final e in nbk['entries'] as List) '${(e as Map)['id']}': '${e['title']}|${e['body']}|${jsonEncode(e['values'])}'},
          },
      };
}
