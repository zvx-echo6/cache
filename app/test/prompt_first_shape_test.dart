// The saved prompt start on the first prompt shape since a load: the whole start is saved even when a file from an earlier day
// covers only the part before the date, so a later load finds it whole. Run against the fake native layer (it follows the native
// rules in cache_llama.cpp: update_probe, align_cache, decode_tokens); the real template, tokenizer and files are covered by the
// native test tool (cl_prefix) only.
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_native_chat.dart';

Map<String, dynamic> request({String date = '2026-11-12', bool known = true, String q = 'how do I purify water'}) => {
      'messages': [
        {
          'role': 'system',
          'content': 'You are Cache, an offline survival and preparedness assistant on this phone. '
              'Cite every sourced fact with its number. Current local date: $date. '
              "The phone's current location is ${known ? 'known' : 'not known'}; use tools."
        },
        if (q.isNotEmpty) {'role': 'user', 'content': q},
      ],
      'tools': [
        {'type': 'function', 'function': {'name': 'search', 'description': 'search the library for a passage', 'parameters': {'type': 'object'}}},
        {'type': 'function', 'function': {'name': 'read', 'description': 'read a source in full', 'parameters': {'type': 'object'}}},
      ],
      'enable_thinking': false,
    };

Future<void> ask(FakeNativeChat n, Map<String, dynamic> r) => n.generate(r).drain<void>();

void main() {
  late FakeNativeChat n;
  setUp(() => n = FakeNativeChat());

  List<String> start(Map<String, dynamic> r) => FakeNativeChat.stableStart(r)!;

  /// After a reload, the question's start is covered whole: all of it was reused and only what follows was decoded.
  Future<void> expectCoveredAfterReload(Map<String, dynamic> r) async {
    n.reload();
    final before = n.decoded;
    await ask(n, r);
    final tokens = n.questions.last;
    expect(n.lastReused, greaterThanOrEqualTo(start(r).length), reason: 'the whole start was restored, not read again');
    expect(n.decoded - before, tokens.length - n.lastReused);
  }

  Future<void> yesterday() async {
    await ask(n, request(date: '2026-11-11'));
    expect(n.files, hasLength(1));
  }

  test('1. yesterday\'s file shares only up to the date: a read ahead and a question save today\'s whole start, and the next load restores it whole', () async {
    await yesterday();
    n.reload();
    final r = request();
    expect((await n.warm(r, checkOnly: true)).outcome.name, 'read');
    expect((await n.warm(r)).outcome.name, 'read');
    expect(n.files.first, start(r));
    await ask(n, r);
    await expectCoveredAfterReload(r);
  });

  test('2. the same with no read ahead at all (a hot phone): the question saves the whole start', () async {
    await yesterday();
    n.reload();
    final r = request();
    await ask(n, r);
    expect(n.files.first, start(r), reason: 'today\'s whole start, tools included');
    expect(n.lastReused, lessThan(start(r).length), reason: 'only the part before the date was restored');
    expect(n.lastReused, greaterThan(0));
    await expectCoveredAfterReload(r);
  });

  test('3. the check ran, the read was skipped, then a question: the question saves the whole start, and a reload is covered', () async {
    await yesterday();
    n.reload();
    final r = request();
    await n.warm(r, checkOnly: true); // (a hot phone skips the read after the check)
    expect(n.files, hasLength(1));
    await ask(n, r);
    expect(n.files.first, start(r));
    await expectCoveredAfterReload(r);
  });

  test('4. alternating starts across loads (location known / not known) stay covered with two files', () async {
    final a = request(known: true), b = request(known: false);
    await ask(n, a);
    n.reload();
    await ask(n, b);
    expect(n.files, hasLength(2));
    for (final r in [a, b, a, b]) {
      await expectCoveredAfterReload(r);
      expect(n.files, hasLength(2));
    }
  });

  test('5. in one load a start that flips between questions writes no new file', () async {
    final a = request(known: true), b = request(known: false);
    await ask(n, a);
    expect(n.files, hasLength(1));
    for (final r in [b, a, b, a]) {
      await ask(n, r);
      expect(n.files, hasLength(1), reason: 'a changed shape saves only what it shares with the one before, which the file already holds');
    }
  });
}
