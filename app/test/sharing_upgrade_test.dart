import 'dart:convert';
import 'dart:io';

import 'package:cache/sharing/sharing_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

void main() {
  testWidgets('a sharing.json from 1.0 (no ask_since) keeps sharing on at the next start', (tester) async {
    final r = await SettingsRig.create(tester);
    final file = File('${r.dir.path}/sharing.json')..writeAsStringSync('{"enabled":true}');
    SharingState open() => SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], opener: (_) async => r.sync);

    final first = open();
    await tester.runAsync(first.init);
    expect(first.enabled, isTrue);
    expect(first.running, isTrue);
    first.dispose();

    final second = open();
    await tester.runAsync(second.init);
    expect(second.enabled, isTrue, reason: 'the first start must not rewrite the file with enabled false');
    expect(second.running, isTrue);
    second.dispose();

    final j = jsonDecode(file.readAsStringSync()) as Map;
    expect(j['enabled'], isTrue);
    expect(j['ask_since'], isA<int>());
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });

  testWidgets('a new install (no sharing.json) writes nothing and stays off', (tester) async {
    final r = await SettingsRig.create(tester);
    final file = File('${r.dir.path}/sharing.json');
    final s = SharingState(policy: r.policy, supportDir: () async => r.dir, kinds: const [], opener: (_) async => r.sync);
    await tester.runAsync(s.init);
    expect(s.enabled, isFalse);
    expect(s.running, isFalse);
    expect(file.existsSync(), isFalse);
    s.dispose();
    await tester.pumpWidget(const SizedBox());
    await r.dispose(tester);
  });
}
