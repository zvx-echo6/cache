import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// This test is plain Dart (`dart test`): if settings_log.dart imported Flutter, or sharing_state.dart, it would not compile here.
import '../../../app/lib/sharing/settings_log.dart';

SettingsEvent ev(String dev, String key, Object? value, int at, {bool hasPrev = false, Object? prev, Object? note}) =>
    SettingsEvent(at: at, dev: dev, key: key, value: value, hasPrev: hasPrev, prev: prev, note: note);

void main() {
  late Directory tmp;
  late SettingsLog log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('settings_log_test');
    log = SettingsLog(dir: '${tmp.path}/settings-sync', device: 'me');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('an event is one line and reads back the same; a bad line reads as nothing', () {
    final e = ev('me', 'ui.theme', {'b': 1, 'a': [1, 2]}, 5, hasPrev: true, prev: 'light', note: {'name': 'x'});
    final back = SettingsEvent.fromLine(e.toLine())!;
    expect(back.at, 5);
    expect(back.dev, 'me');
    expect(back.key, 'ui.theme');
    expect(back.value, {'b': 1, 'a': [1, 2]});
    expect(back.hasPrev, isTrue);
    expect(back.prev, 'light');
    expect(back.note, {'name': 'x'});
    expect(e.toLine().contains('\n'), isFalse);
    // No previous value and no note: neither is in the line.
    final bare = jsonDecode(ev('me', 'k', 1, 1).toLine()) as Map;
    expect(bare.containsKey('prev'), isFalse);
    expect(bare.containsKey('note'), isFalse);
    // A null value is a value; a missing one, a wrong version, a bad time and plain text are not events.
    expect(SettingsEvent.fromLine(ev('me', 'k', null, 1).toLine())!.value, isNull);
    expect(SettingsEvent.fromLine('{"v":1,"at":1,"dev":"me","k":"k"}'), isNull);
    expect(SettingsEvent.fromLine('{"v":2,"at":1,"dev":"me","k":"k","val":1}'), isNull);
    expect(SettingsEvent.fromLine('{"v":1,"at":"1","dev":"me","k":"k","val":1}'), isNull);
    expect(SettingsEvent.fromLine('not json'), isNull);
  });

  test('append writes this device\'s own log, <dir>/log/<device>.jsonl, a line at a time, in order', () async {
    await log.append(ev('me', 'a', 1, 1));
    await log.append(ev('me', 'b', 2, 2));
    await log.append(ev('someone-else', 'c', 3, 3)); // only this device writes its own log
    final f = File('${tmp.path}/settings-sync/log/me.jsonl');
    final lines = f.readAsStringSync().split('\n');
    expect(lines.length, 3); // two lines and the end of the last
    expect(lines.last, '');
    expect([for (final l in lines.take(2)) SettingsEvent.fromLine(l)!.key], ['a', 'b']);
    expect(Directory('${tmp.path}/settings-sync/log').listSync().length, 1);
  });

  test('read a peer\'s log from seen onward: the latest line of each setting, and a log that got shorter is read again', () async {
    final peer = File('${tmp.path}/settings-sync/log/peer.jsonl')..createSync(recursive: true);
    peer.writeAsStringSync([
      ev('peer', 'a', 1, 1).toLine(),
      ev('peer', 'b', 'x', 2).toLine(),
      '',
      'junk',
      ev('other', 'z', 0, 3).toLine(), // a line of another device's name in this log is not this peer's
      ev('peer', 'a', 2, 4).toLine(),
    ].map((l) => '$l\n').join());
    var r = (await log.readPeer('peer'))!;
    expect(r.latest.keys.toSet(), {'a', 'b'});
    expect(r.latest['a']!.$2.value, 2); // the later line of a
    expect(r.latest['a']!.$1, 6);
    expect(r.latest['b']!.$1, 2);
    expect(log.state.isUnseen('peer', 'a', 6), isTrue);
    log.state.markSeen('peer', 'a', 6);
    expect(log.state.isUnseen('peer', 'a', 6), isFalse);
    expect(log.state.isUnseen('peer', 'b', 2), isTrue); // b is still not seen
    expect(r.unseen(log.state.seenOf('peer')).keys.toList(), ['b']);
    // A new line arrives: only it is newer than seen.
    peer.writeAsStringSync('${ev('peer', 'a', 3, 9).toLine()}\n', mode: FileMode.append);
    r = (await log.readPeer('peer'))!;
    expect(r.unseen(log.state.seenOf('peer')).keys.toSet(), {'a', 'b'});
    expect(r.latest['a']!.$1, 7);
    // The log is started again, shorter than what was seen: everything is read again.
    log.state.markSeen('peer', 'b', 2);
    log.state.markSeen('peer', 'a', 7);
    peer.writeAsStringSync('${ev('peer', 'a', 'again', 10).toLine()}\n');
    r = (await log.readPeer('peer'))!;
    expect(log.state.seenOf('peer'), isEmpty);
    expect(r.unseen(log.state.seenOf('peer')).keys.toList(), ['a']);
    // A log that is not there reads as null.
    expect(await log.readPeer('nobody'), isNull);
  });

  test('state.json: every part round trips; a damaged file starts again', () async {
    final s = log.state;
    s.localAt['a'] = 5;
    s.last['a'] = '1';
    s.markSeen('peer', 'a', 3);
    s.keysFor['peer'] = {'live.key.x', 'search.kagi.key'};
    s.notes['a'] = {'name': 'n'};
    s.waiting['m'] = ev('peer', 'm', 'file', 7, note: {'name': 'Model'});
    await log.saveState();
    final f = File('${tmp.path}/settings-sync/.local/state.json');
    expect(f.existsSync(), isTrue);
    expect((jsonDecode(f.readAsStringSync()) as Map)['keys'], {'peer': ['live.key.x', 'search.kagi.key']});
    expect(Directory('${tmp.path}/settings-sync/.local').listSync().length, 1); // no temp file left

    final other = SettingsLog(dir: '${tmp.path}/settings-sync', device: 'me');
    await other.loadState();
    expect(other.state.localAt, {'a': 5});
    expect(other.state.last, {'a': '1'});
    expect(other.state.seen, {'peer': {'a': 3}});
    expect(other.state.keysFor, {'peer': {'live.key.x', 'search.kagi.key'}});
    expect(other.state.notes, {'a': {'name': 'n'}});
    expect(other.state.waiting['m']!.toLine(), s.waiting['m']!.toLine());

    f.writeAsStringSync('{not json');
    final broken = SettingsLog(dir: '${tmp.path}/settings-sync', device: 'me');
    await broken.loadState();
    expect(broken.state.localAt, isEmpty);
    expect(broken.state.seen, isEmpty);
    // No state file at all is the same.
    f.deleteSync();
    await broken.loadState();
    expect(broken.state.last, isEmpty);
  });

  test('newest wins: Match takes the later change, or one made on the value this device still has; Send mine and Off never take', () {
    final later = ev('peer', 'k', 'new', 20);
    final earlier = ev('peer', 'k', 'new', 10);
    expect(applies(SettingsLink.match, later, current: '"mine"', localAt: 15), isTrue);
    expect(applies(SettingsLink.match, earlier, current: '"mine"', localAt: 15), isFalse);
    // Only one side changed it: the other's previous value is the value here, so it applies whatever the clocks say.
    final onMine = ev('peer', 'k', 'new', 10, hasPrev: true, prev: {'b': 1, 'a': 2});
    expect(applies(SettingsLink.match, onMine, current: canonical({'a': 2, 'b': 1}), localAt: 15), isTrue);
    expect(applies(SettingsLink.match, onMine, current: '"other"', localAt: 15), isFalse);
    // Receiving takes everything; sending and off take nothing.
    expect(applies(SettingsLink.receiving, earlier, current: '"mine"', localAt: 15), isTrue);
    expect(applies(SettingsLink.sending, later, current: '"mine"', localAt: 0), isFalse);
    expect(applies(SettingsLink.off, later, current: '"mine"', localAt: 0), isFalse);
    // Two equal values compare equal whatever the order of their keys.
    expect(canonical({'b': 1, 'a': [2, {'d': 1, 'c': 2}]}), canonical({'a': [2, {'c': 2, 'd': 1}], 'b': 1}));
  });

  test('which way a link goes, and which settings it includes', () {
    SettingsLink way(Map<String, Object?>? l, {bool sinceAsking = false}) => linkOfRecord(l, peer: 'p', myId: 'me', linkedSinceAsking: sinceAsking);
    expect(way({'mode': 'match'}), SettingsLink.match);
    expect(way({'mode': 'off'}), SettingsLink.off);
    expect(way({'mode': 'send', 'from': 'p'}), SettingsLink.receiving);
    expect(way({'mode': 'send', 'from': 'me'}), SettingsLink.sending);
    expect(way({'mode': 'send', 'from': 'third'}), SettingsLink.off);
    // A link with nothing chosen: Match when it was made before the question was asked, Off when it is new.
    expect(way(null), SettingsLink.match);
    expect(way({}, sinceAsking: true), SettingsLink.off);
    expect(linkSends(SettingsLink.match), isTrue);
    expect(linkSends(SettingsLink.sending), isTrue);
    expect(linkSends(SettingsLink.receiving), isFalse);
    expect(linkTakes(SettingsLink.match), isTrue);
    expect(linkTakes(SettingsLink.receiving), isTrue);
    expect(linkTakes(SettingsLink.off), isFalse);
    expect(linkIncludes({'off_groups': ['maps'], 'off_keys': ['b']}, group: 'appearance', key: 'a'), isTrue);
    expect(linkIncludes({'off_groups': ['maps'], 'off_keys': ['b']}, group: 'maps', key: 'a'), isFalse);
    expect(linkIncludes({'off_groups': ['maps'], 'off_keys': ['b']}, group: 'appearance', key: 'b'), isFalse);
    expect(linkIncludes({}, group: 'appearance', key: 'a'), isTrue);
  });
}
