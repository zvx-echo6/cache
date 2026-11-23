// Unlink asks for the phone's own screen lock after the plain confirm; with none set, the confirm alone is enough.

import 'dart:io';

import 'package:cache/platform/device_lock.dart';
import 'package:cache/screens/settings/sharing_page.dart';
import 'package:cache/sharing/sharing_state.dart';
import 'package:cache/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart' show testPolicy;
import 'support/sync_fake.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  /// Answers the lock channel with [answer] and records what was asked.
  List<Map<Object?, Object?>> fakeLock(String answer) {
    final asked = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('co.cache/device_lock'), (call) async {
      expect(call.method, 'confirm');
      asked.add(call.arguments as Map<Object?, Object?>);
      return answer;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('co.cache/device_lock'), null));
    return asked;
  }

  Future<FakeSync> open(WidgetTester tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('unlink-lock')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final sync = FakeSync()..peers.add({'id': 'p1', 'name': 'Desk', 'linked': 1, 'last_seen': now - 120000, 'via': 'direct', 'error': null});
    final s = SharingState(policy: testPolicy(wifi: true), supportDir: () async => dir, kinds: const [], opener: (_) async => sync);
    await tester.runAsync(s.setUp);
    await tester.runAsync(s.refresh);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: SharingPage(sharing: s)));
    await tester.pump();
    addTearDown(s.dispose);
    return sync;
  }

  Future<void> unlinkTapped(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('peer-p1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('device-unlink')));
    await tester.tap(find.byKey(const ValueKey('device-unlink')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-unlink')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  testWidgets('no lock set: the plain confirm, then it unlinks', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final asked = fakeLock('none');
      final sync = await open(tester);
      await unlinkTapped(tester);
      expect(asked.single, {'title': 'Unlink Desk?', 'description': "Confirm it's you to unlink this device."});
      expect(sync.argsOf['unlink']!.single, {'peer': 'p1'});
      expect(find.text('Not unlinked'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the lock says ok: it unlinks', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final asked = fakeLock('ok');
      final sync = await open(tester);
      await unlinkTapped(tester);
      expect(asked, hasLength(1));
      expect(sync.argsOf['unlink']!.single, {'peer': 'p1'});
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the lock is cancelled: nothing is unlinked and it says so', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final asked = fakeLock('cancelled');
      final sync = await open(tester);
      await unlinkTapped(tester);
      expect(asked, hasLength(1));
      expect(sync.argsOf['unlink'], isNull);
      expect(find.text('Not unlinked'), findsOneWidget);
      expect(find.text('Desk'), findsWidgets, reason: 'still linked, still on its page');
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on Linux the lock is not asked', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final asked = fakeLock('cancelled');
      final sync = await open(tester);
      await unlinkTapped(tester);
      expect(asked, isEmpty);
      expect(sync.argsOf['unlink']!.single, {'peer': 'p1'});
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('the wrapper answers none on Linux, iOS and with no native side', () async {
    for (final p in [TargetPlatform.linux, TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = p;
      try {
        expect(await DeviceLock.confirm(title: 't', description: 'd'), DeviceLockResult.none, reason: '$p');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });
}
