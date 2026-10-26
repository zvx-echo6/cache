import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/web_search_setup.dart';
import 'package:cache/video/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

String err(String type, String detail) => '{"ok":false,"error":{"type":"$type","detail":"$detail"}}';

void main() {
  group('what the core\'s web_search answered, in words for people', () {
    test('results mean the key works', () {
      expect(keyCheckFromToolContent('[1] Cache (web, fetched 2026-10-26 12:00) - a result').ok, isTrue);
      expect(keyCheckFromToolContent('No results found.').ok, isTrue);
    });

    test('a rejected key is the core\'s key_missing, and only that: a bare HTTP 400 is not taken for one', () {
      const m = "Kagi didn't accept this key. Check you copied all of it.";
      expect(keyCheckFromToolContent(err('key_missing', 'web search key rejected')).message, m);
      final other = keyCheckFromToolContent(err('fetch_failed', 'web search failed (HTTP 400)')).message;
      expect(other, isNot(m), reason: 'the core says key_missing for a rejected key; a 400 without that is something else');
      expect(other, contains('HTTP 400'));
    });

    test('no credit says so', () {
      final r = keyCheckFromToolContent(err('quota', 'web search limit reached'));
      expect(r.ok, isFalse);
      expect(r.message, contains('no search credit'));
    });

    test('no connection says so, and only a real 5xx says try again in a moment', () {
      for (final d in ['could not reach the web search server', 'web search timed out', 'the web search request failed']) {
        expect(keyCheckFromToolContent(err('fetch_failed', d)).message, "Couldn't reach Kagi. Check your connection.");
      }
      expect(keyCheckFromToolContent(err('fetch_failed', 'web search failed (HTTP 500)')).message, contains('Try again in a moment'));
      expect(keyCheckFromToolContent(err('fetch_failed', 'web search failed (HTTP 503)')).message, contains('(HTTP 503)'));
      expect(keyCheckFromToolContent(err('fetch_failed', 'web search failed (HTTP 404)')).message, isNot(contains('Try again in a moment')));
      expect(keyCheckFromToolContent(err('bad_response', 'x')).message, isNot(contains('moment')));
    });

    test('no message ever holds the key', () {
      final all = [
        err('key_missing', 'web search key rejected'),
        err('quota', 'q'),
        err('fetch_failed', 'web search failed (HTTP 400)'),
      ];
      for (final c in all) {
        expect(keyCheckFromToolContent(c).message, isNot(contains('secret')));
      }
    });
  });

  test('saving a key checks it with one search through the core, and puts the core back if it fails', () async {
    final calls = <(String?, String?, bool)>[];
    final probed = <String>[];
    var answer = err('key_missing', 'web search key rejected');
    final s = AppSettings();
    final secrets = MemoryTokenStore();
    final w = WebSearchSetup(
      settings: s,
      secrets: secrets,
      setWeb: (p, k, o) async => calls.add((p, k, o)),
      searchProbe: (k) async {
        probed.add(k);
        return answer;
      },
    );
    final bad = await w.saveKey('wrong');
    expect(bad.ok, isFalse);
    expect(probed, ['wrong']);
    expect(secrets.values, isEmpty);
    expect(calls.last, (null, null, false));
    answer = 'results';
    final good = await w.saveKey('right');
    expect(good.ok, isTrue);
    expect(secrets.values[WebSearchSetup.keyName], 'right');
    expect(calls.last.$1, 'kagi');
    w.dispose();
  });
}
