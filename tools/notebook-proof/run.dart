// Notebook sync proof harness, entry point. Re-runnable: every run makes a fresh evidence folder.
//   dart tools/notebook-proof/run.dart --scenarios stage1,swap,N1 [--run NAME] [--root E:\cache-proof] [--deadline 18:55]
// Scenarios: stage1 (legacy v1.0.30 devices A and B link, share a notebook with fields and entries, sync), swap (the same data dirs
// started on the chain build), N1, ... (see scenarios.dart). Every device is a separate OS process (flutter test of
// app/test/proof/device_*.dart) with its own data dir, running the real NotebookSync / SharingState / SyncCore.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'harness.dart';
import 'scenarios.dart';

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length) o[args[i].substring(2)] = args[++i];
  }
  final root = o['root'] ?? (Platform.isWindows ? r'E:\cache-proof' : '${Platform.environment['HOME']}/cache-proof');
  final names = (o['scenarios'] ?? 'stage1,swap,N1').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
  final run = o['run'] ?? 'run-$stamp';
  final h = Harness(root: root, run: run, deadline: o['deadline'] ?? '18:55');
  // The legacy worktree (tag v1.0.30) gets the same device code (the part both builds share, and its own wiring).
  final legacyProof = Directory('$root/wt-legacy/app/test/proof')..createSync(recursive: true);
  for (final f in ['agent.dart', 'device_legacy.dart']) {
    File('$root/wt-chain/app/test/proof/$f').copySync('${legacyProof.path}/$f');
  }
  for (final w in ['wt-legacy', 'wt-chain']) {
    final r = await Process.run('git', ['-C', '$root/$w', 'log', '--oneline', '-3']);
    h.say('$w: ${'${r.stdout}'.trim().replaceAll('\n', ' | ')}');
  }
  h.say('run $run scenarios $names evidence ${h.evidence.path}');
  final results = <String, Object?>{};
  try {
    for (final n in names) {
      final f = scenarios[n];
      if (f == null) {
        h.say('unknown scenario $n (known: ${scenarios.keys.join(', ')})');
        results[n] = 'unknown';
        continue;
      }
      results[n] = await h.runScenario(n, f);
    }
  } finally {
    await h.killAll();
    File('${h.evidence.path}/summary.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    h.say('SUMMARY ${jsonEncode(results)}');
  }
  exit(results.values.every((v) => v == 'pass') ? 0 : 1);
}
