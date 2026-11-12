import 'dart:convert';
import 'dart:io';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/sync/field_sync.dart';
import 'package:cache/notebook/sync/share_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/prefix/share_format_prefix.dart' as pre;
import 'support/share_rig.dart';

/// A notebook's fields between a person's own devices: a field has one id on every device, each of its properties (name, type,
/// unit, choices, removed, place in the order) goes by its own time, and a device that held its fields before the field sync matches
/// them to the record the first time. Every test syncs through the simulated share.
Future<void> rounds(List<Dev> devs, ShareLink link, {int n = 3}) async {
  for (var i = 0; i < n; i++) {
    for (final d in devs) {
      await d.sync();
    }
    link.sync();
  }
  for (final d in devs) {
    await d.sync();
  }
}

LogField txt(String label) => LogField(label: label, type: FieldType.text);
LogField num_(String label, {String? unit}) => LogField(label: label, type: FieldType.number, unit: unit);

Future<(Dev, Dev, ShareLink)> pair() async {
  final a = Dev('a');
  final b = Dev('b');
  await a.boot();
  await b.boot();
  return (a, b, ShareLink(a.folder, b.folder));
}

/// Two devices that share a notebook "Hikes" (Distance, Weather, Notes) made after the field sync existed.
Future<(Dev, Dev, ShareLink, String)> shared({List<LogField>? fields}) async {
  final (a, b, link) = await pair();
  final n = await a.makeWith('Hikes', fields ?? [num_('Distance', unit: 'km'), txt('Weather'), txt('Notes')]);
  await rounds([a, b], link);
  return (a, b, link, n.id);
}

/// A notebook shared before the field sync whose device b had named the field "Weather" `sky` in its notes (its file for the note says
/// so, and its state remembers it); both devices have no field ids and no record `fields`.
Future<(Dev, Dev, ShareLink, String)> drifted({bool extraSky = false}) async {
  final (a, b, link, id) = await shared(fields: [txt('Weather'), txt('Notes')]);
  await a.addValues(id, 'e1', {'Weather': 'Sun'});
  await rounds([a, b], link);
  for (final d in [a, b]) {
    await d.beforeFields();
    Dev.stripRecordFields(d.folder);
  }
  final fidB = b.field(id, 'Weather').fid!;
  await b.beforeFields(props: {id: jsonEncode({fidB: 'sky'})});
  final path = b.folder.text.keys.firstWhere((k) => k.startsWith('$id/') && k.endsWith('.cnote'));
  b.folder.text[path] = b.folder.text[path]!.replaceFirst('weather:', 'sky:');
  final stateFile = File('${b.stateDir.path}/share2.json');
  final j = jsonDecode(await stateFile.readAsString()) as Map;
  ((j['items'] as Map)['e1'] as Map)['base'] = b.folder.text[path];
  await stateFile.writeAsString(jsonEncode(j));
  if (extraSky) {
    await a.editFields(id, (fs) => [...fs, txt('Sky')]);
    await a.stripGids();
  }
  link.sync();
  return (a, b, link, id);
}

Future<Map<String, Object?>> valuesOf(Dev d, String id, String entryId) async {
  final e = (await d.nb.entries(id)).firstWhere((e) => e.id == entryId);
  final names = {for (final f in d.nb.notebook(id)!.def.fields) f.fid: f.label};
  return {for (final v in e.values.entries) names[v.key] ?? v.key: v.value};
}

void failOn(Dev d, bool Function(String path) when) {
  d.folder.beforeWrite = (p) async {
    if (when(p)) throw const FormatException('the folder stopped answering');
  };
}

Future<void> syncQuiet(Dev d) async {
  try {
    await d.sync();
  } catch (_) {}
}

/// Notebooks shared by the sync of v1.0.30 before the update, each device with its own id for "Hikes" and the same fields.
Future<(Dev, Dev, ShareLink)> oldShare() async {
  final a = Dev('a', old: true);
  final b = Dev('b', old: true);
  await a.boot();
  await b.boot();
  final fields = [num_('Distance', unit: 'km'), txt('Weather'), txt('Notes')];
  await a.makeWith('Hikes', fields, id: 'a-1');
  await b.makeWith('Hikes', fields, id: 'b-2');
  await a.stripGids();
  await b.stripGids();
  await a.addValues('a-1', 'ea1', {'Distance': 3, 'Weather': 'Sun'});
  await b.addValues('b-2', 'eb1', {'Distance': 5, 'Notes': 'Wet'});
  final link = ShareLink(a.folder, b.folder);
  await rounds([a, b], link, n: 3);
  return (a, b, link);
}

Future<void> expectOneSet(Dev a, Dev b, {String id = 'a-1'}) async {
  for (final d in [a, b]) {
    expect(d.ids('Hikes'), [id], reason: d.label);
    expect(d.labels(id), ['Distance', 'Weather', 'Notes'], reason: '${d.label}: one set of fields');
    expect(d.nb.notebook(id)!.def.fields.length, 3, reason: '${d.label}: none twice, none hidden');
    expect(await valuesOf(d, id, 'ea1'), {'Distance': 3, 'Weather': 'Sun'}, reason: d.label);
    expect(await valuesOf(d, id, 'eb1'), {'Distance': 5, 'Notes': 'Wet'}, reason: d.label);
  }
  for (final l in ['Distance', 'Weather', 'Notes']) {
    expect(a.field(id, l).gid, b.field(id, l).gid, reason: l);
  }
}

void main() {
  group('the ids', () {
    test('a field has the same id on every device, and the notebook comes across with its fields in order', () async {
      final (a, b, _, id) = await shared();
      expect(b.labels(id), ['Distance', 'Weather', 'Notes']);
      for (final l in ['Distance', 'Weather', 'Notes']) {
        expect(b.field(id, l).gid, a.field(id, l).gid);
        expect(a.field(id, l).gid, isNotNull);
      }
      expect(b.field(id, 'Distance').unit, 'km');
    });

    test('the ids by rule are stable, and tell fields apart', () {
      expect(gidOfSnapshotField('n1', 0, 'Distance'), gidOfSnapshotField('n1', 0, '  distance '));
      expect(gidOfSnapshotField('n1', 0, 'Distance'), isNot(gidOfSnapshotField('n1', 1, 'Distance')));
      expect(gidOfSnapshotField('n1', 0, 'Distance'), isNot(gidOfSnapshotField('n2', 0, 'Distance')));
      expect(gidOfSnapshotField('n1', 0, 'Distance'), hasLength(32));
      expect(gidOfLocalField('n1', 'Elevation', 'number'), isNot(gidOfLocalField('n1', 'Elevation', 'text')));
    });
  });

  group('changes after the first share', () {
    test('a rename, a new field, a removal and a reorder go across; the values stay with their field', () async {
      final (a, b, link, id) = await shared();
      await a.addValues(id, 'e1', {'Distance': 12, 'Weather': 'Sun'});
      await rounds([a, b], link);
      final gidWeather = a.field(id, 'Weather').gid;
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await rounds([a, b], link);
      expect(b.labels(id), ['Distance', 'Sky', 'Notes']);
      expect(b.field(id, 'Sky').gid, gidWeather);
      final e = (await b.nb.entries(id)).single;
      expect(e.values[b.field(id, 'Sky').fid], 'Sun', reason: 'the value of a renamed field is still there');
      // a new field on b goes to a
      await b.editFields(id, (fs) => [...fs, txt('Trail')]);
      await rounds([a, b], link);
      expect(a.labels(id), ['Distance', 'Sky', 'Notes', 'Trail']);
      // a field moved to the front
      await a.editFields(id, (fs) => [fs.firstWhere((f) => f.label == 'Trail'), ...fs.where((f) => f.label != 'Trail')]);
      await rounds([a, b], link);
      expect(b.labels(id), ['Trail', 'Distance', 'Sky', 'Notes']);
      // a removal: the field with no values is gone; the one with values stays hidden in the entries
      await b.editFields(id, (fs) => fs.where((f) => f.label != 'Notes' && f.label != 'Distance').toList());
      await rounds([a, b], link);
      expect(a.labels(id), ['Trail', 'Sky']);
      expect((await a.nb.entries(id)).single.values.length, 2, reason: 'the entry keeps the value of the field that was removed');
    });

    test('a rename on one device and a hide on the other both stay', () async {
      final (a, b, link, id) = await shared();
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await b.editFields(id, (fs) => fs.where((f) => f.label != 'Notes').toList());
      await rounds([a, b], link);
      for (final d in [a, b]) {
        expect(d.labels(id), ['Distance', 'Sky'], reason: d.label);
      }
    });

    test('two devices rename one field at once: the later wins on both', () async {
      var t = DateTime.utc(2026, 11, 10, 12);
      final a = Dev('a', clock: () => t);
      final b = Dev('b', clock: () => t);
      await a.boot();
      await b.boot();
      final link = ShareLink(a.folder, b.folder);
      final id = (await a.makeWith('Hikes', [txt('Weather'), txt('Notes')])).id;
      await rounds([a, b], link);
      t = t.add(const Duration(minutes: 1));
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await a.sync();
      t = t.add(const Duration(minutes: 1));
      await b.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Conditions') : f]);
      await rounds([b, a], link);
      expect(a.labels(id), ['Conditions', 'Notes']);
      expect(b.labels(id), ['Conditions', 'Notes']);
    });

    test('a unit and choices changed on one device while the other adds an entry', () async {
      final (a, b, link, id) = await shared(fields: [num_('Distance', unit: 'km'), LogField(label: 'Surface', type: FieldType.choice, choices: const ['Dirt', 'Rock'])]);
      await b.addValues(id, 'e1', {'Distance': 5, 'Surface': 'Rock'});
      await a.editFields(id, (fs) => [
            for (final f in fs)
              f.label == 'Distance' ? f.copyWith(unit: 'mi') : (f.label == 'Surface' ? f.copyWith(choices: const ['Dirt', 'Rock', 'Sand']) : f),
          ]);
      await rounds([a, b], link);
      for (final d in [a, b]) {
        expect(d.field(id, 'Distance').unit, 'mi', reason: d.label);
        expect(d.field(id, 'Surface').choices, ['Dirt', 'Rock', 'Sand'], reason: d.label);
        expect((await d.nb.entries(id)).single.values.values, containsAll([5, 'Rock']), reason: d.label);
      }
    });

    test('a type changed where the other device has values for it: that device keeps its type and the record is corrected', () async {
      final (a, b, link, id) = await shared(fields: [txt('Distance'), txt('Notes')]);
      await b.addValues(id, 'e1', {'Distance': 'about 5'});
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Distance' ? f.copyWith(type: FieldType.number) : f]);
      await rounds([a, b], link, n: 4);
      expect(b.field(id, 'Distance').type, FieldType.text);
      expect(a.field(id, 'Distance').type, FieldType.text, reason: 'a takes the corrected record');
    });

    test('no echo: a settled share writes nothing more, on either side', () async {
      final (a, b, link, id) = await shared();
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await rounds([a, b], link, n: 4);
      final before = {for (final d in [a, b]) d.label: Map.of(d.folder.text)};
      final saves = [a.store.notebooks.length, b.store.notebooks.length];
      for (var i = 0; i < 3; i++) {
        await rounds([a, b], link, n: 1);
      }
      expect(a.folder.text, before['a']);
      expect(b.folder.text, before['b']);
      expect(a.folder.text['$id/notebook.json'], b.folder.text['$id/notebook.json']);
      expect([a.store.notebooks.length, b.store.notebooks.length], saves);
    });
  });

  group('two fields added at once', () {
    test('both are kept, and the second shows " (2)" on every device', () async {
      final (a, b, link, id) = await shared(fields: [txt('Weather')]);
      await a.editFields(id, (fs) => [...fs, num_('Elevation', unit: 'm')]);
      await b.editFields(id, (fs) => [...fs, num_('Elevation', unit: 'ft')]);
      await rounds([a, b], link, n: 4);
      for (final d in [a, b]) {
        expect(d.labels(id).toSet(), {'Weather', 'Elevation', 'Elevation (2)'}, reason: d.label);
      }
      expect(a.labels(id), b.labels(id));
      expect(a.field(id, 'Elevation (2)').gid, b.field(id, 'Elevation (2)').gid);
      expect(a.field(id, 'Elevation (2)').unit, b.field(id, 'Elevation (2)').unit);
      // the record keeps the label it has; the suffix is not written back
      final names = [for (final f in a.record(id)!['fields'] as List) (f as Map)['name']];
      expect(names, ['Weather', 'Elevation', 'Elevation']);
    });
  });

  group('the cap of 12', () {
    test('a notebook that came to more than 12 fields shows them all and can still be saved, trimmed and renamed', () async {
      final (a, b, link, id) = await shared(fields: [for (var i = 0; i < 11; i++) txt('F$i')]);
      await a.editFields(id, (fs) => [...fs, txt('A1')]);
      await b.editFields(id, (fs) => [...fs, txt('B1')]);
      await rounds([a, b], link, n: 4);
      expect(a.nb.notebook(id)!.def.visible.length, 13);
      expect(b.nb.notebook(id)!.def.visible.length, 13);
      // the editor's save that does not add a field passes (the real store; here the fake keeps no cap)
      await a.editFields(id, (fs) => fs.where((f) => f.label != 'F0').toList());
      await rounds([a, b], link, n: 3);
      expect(b.nb.notebook(id)!.def.visible.length, 12);
    });
  });

  group('the migration', () {
    /// The notebook was shared before the field sync (records with a first-share snapshot and no `fields`; devices with no ids).
    Future<(Dev, Dev, ShareLink, String)> old() async {
      final (a, b, link, id) = await shared(fields: [num_('Distance', unit: 'km'), txt('Weather'), txt('Notes')]);
      for (final d in [a, b]) {
        await d.beforeFields();
        Dev.stripRecordFields(d.folder);
      }
      link.sync();
      return (a, b, link, id);
    }

    test('both migrate, in either order: same ids, nothing changed, values still in place', () async {
      for (final order in [0, 1]) {
        final (a, b, link, id) = await old();
        await a.addValues(id, 'e1', {'Distance': 3});
        for (final d in order == 0 ? [a, b] : [b, a]) {
          await d.sync();
          link.sync();
        }
        await rounds([a, b], link);
        for (final d in [a, b]) {
          expect(d.labels(id), ['Distance', 'Weather', 'Notes'], reason: '${d.label} order $order');
          expect(d.field(id, 'Distance').gid, isNotNull);
        }
        expect(a.field(id, 'Weather').gid, b.field(id, 'Weather').gid);
        expect((await b.nb.entries(id)).single.values.values, [3]);
      }
    });

    test('a field added on one device before the migration comes to the other', () async {
      final (a, b, link, id) = await old();
      await a.editFields(id, (fs) => [...fs, txt('Trail')]);
      await a.beforeFields();
      await rounds([a, b], link, n: 4);
      expect(b.labels(id), ['Distance', 'Weather', 'Notes', 'Trail']);
    });

    test('the same field added on both before the migration is one field', () async {
      final (a, b, link, id) = await old();
      await a.editFields(id, (fs) => [...fs, txt('Trail')]);
      await b.editFields(id, (fs) => [...fs, txt('trail ')]);
      // fields made before the update have no ids
      await a.beforeFields();
      await b.beforeFields();
      await rounds([a, b], link, n: 4);
      expect(a.labels(id).where((l) => l.toLowerCase().startsWith('trail')).length, 1, reason: '${a.labels(id)} ${b.labels(id)} ${jsonEncode(a.record(id)!['fields'])}');
      expect(a.labels(id), b.labels(id));
    });

    test('a field renamed and a field reordered before the migration go across by the property name and the label', () async {
      final (a, b, link, id) = await old();
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await b.editFields(id, (fs) => [fs.last, ...fs.take(fs.length - 1)]);
      await rounds([a, b], link, n: 4);
      expect(a.labels(id).toSet(), {'Distance', 'Sky', 'Notes'});
      expect(a.labels(id), b.labels(id));
    });

    test('values beat a removal that was only inferred: it stays where it has values, and comes back where it was removed', () async {
      for (final order in [0, 1]) {
        final (a, b, link, id) = await old();
        await a.addValues(id, 'e1', {'Weather': 'Sun'});
        await b.editFields(id, (fs) => fs.where((f) => f.label != 'Weather').toList());
        for (final d in order == 0 ? [a, b] : [b, a]) {
          await d.sync();
          link.sync();
        }
        await rounds([a, b], link, n: 4);
        expect(a.labels(id), contains('Weather'), reason: 'order $order');
        expect(b.labels(id), contains('Weather'), reason: 'order $order: it comes back on b');
        final e = (await a.nb.entries(id)).single;
        expect(e.values[a.field(id, 'Weather').fid], 'Sun', reason: 'the value is still visible');
      }
    });

    test('a removal where the other device has no values is applied', () async {
      final (a, b, link, id) = await old();
      await b.editFields(id, (fs) => fs.where((f) => f.label != 'Notes').toList());
      await rounds([a, b], link, n: 4);
      expect(a.labels(id), ['Distance', 'Weather']);
    });

    test('a removal made after the upgrade is a removal: it propagates', () async {
      final (a, b, link, id) = await old();
      await rounds([a, b], link, n: 3);
      await b.editFields(id, (fs) => fs.where((f) => f.label != 'Weather').toList());
      await rounds([a, b], link, n: 3);
      expect(a.labels(id), ['Distance', 'Notes']);
    });

    test('the sync stops after the record was written and before the notebook took its ids: the next run finishes it', () async {
      final (a, b, link, id) = await old();
      await a.sync();
      link.sync();
      // a "killed" before its notebook state was written: forget what it remembered and take the ids back
      await a.beforeFields();
      await rounds([a, b], link, n: 3);
      expect(a.labels(id), ['Distance', 'Weather', 'Notes']);
      expect(a.field(id, 'Notes').gid, b.field(id, 'Notes').gid);
    });
  });

  group('three devices, and one that is away', () {
    test('three devices come to one list; the one that was offline takes it when it is back', () async {
      final a = Dev('a');
      final b = Dev('b');
      final c = Dev('c');
      for (final d in [a, b, c]) {
        await d.boot();
      }
      final ab = ShareLink(a.folder, b.folder);
      final bc = ShareLink(b.folder, c.folder);
      final n = await a.makeWith('Hikes', [txt('Weather'), txt('Notes')]);
      for (var i = 0; i < 4; i++) {
        for (final d in [a, b, c]) {
          await d.sync();
        }
        ab.sync();
        bc.sync();
      }
      // c is away: a and b change fields
      await a.editFields(n.id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await b.editFields(n.id, (fs) => [...fs, num_('Elevation')]);
      for (var i = 0; i < 3; i++) {
        await a.sync();
        await b.sync();
        ab.sync();
      }
      expect(a.labels(n.id).toSet(), {'Sky', 'Notes', 'Elevation'});
      // c returns and changes its own while behind
      await c.editFields(n.id, (fs) => [for (final f in fs) f.label == 'Notes' ? f.copyWith(label: 'Remarks') : f]);
      for (var i = 0; i < 5; i++) {
        for (final d in [a, b, c]) {
          await d.sync();
        }
        ab.sync();
        bc.sync();
      }
      for (final d in [a, b, c]) {
        expect(d.labels(n.id).toSet(), {'Sky', 'Remarks', 'Elevation'}, reason: d.label);
      }
      expect(a.labels(n.id), c.labels(n.id));
    });
  });

  group('the record', () {
    test('fields are merged one property at a time, and a build that does not know fields takes the later list whole', () {
      List<Map<String, dynamic>> f(String name, int at, {Object? removed}) => [
            {'gid': 'g1', 'pname': 'weather', 'name': name, 'name_at': at, 'type': 'text', 'type_at': 0, 'ord': 1000, 'ord_at': 0, 'removed': ?removed, if (removed != null) 'removed_at': at},
          ];
      final r1 = NbRecord.live('n', nameAt: 5, body: {'name': 'Hikes', 'fields': f('Sky', 10), 'fields_at': 10});
      final r2 = NbRecord.live('n', nameAt: 5, body: {'name': 'Hikes', 'fields': f('Weather', 5, removed: true), 'fields_at': 5});
      final m = NbRecord.merge([r1, r2])!;
      final g = (m.body['fields'] as List).single as Map;
      expect(g['name'], 'Sky', reason: 'the later name');
      expect(g['removed'], true, reason: 'the removal is a property of its own');
      expect(m.body['fields_at'], 10);
      // the same result whichever way round
      expect(jsonEncode(NbRecord.merge([r2, r1])!.body['fields']), jsonEncode(m.body['fields']));
    });
  });

  group('a device that stored values under its own earlier property name', () {
    test('its notes are written again under the shared name, so the other device reads the value as the field', () async {
      final (a, b, link, id) = await drifted();
      final path = b.folder.text.keys.firstWhere((k) => k.startsWith('$id/') && k.endsWith('.cnote'));
      await rounds([a, b], link, n: 4);
      for (final d in [a, b]) {
        expect((await valuesOf(d, id, 'e1'))['Weather'], 'Sun', reason: '${d.label}: the value is in the field');
      }
      expect(b.folder.text[path], contains('weather: Sun'));
      expect(b.folder.text[path], isNot(contains('sky:')));
    });
  });

  group('a build without the field sync carries the fields it does not understand', () {
    test('a real record with fields survives merge and rewrite in both conflict orders', () async {
      final (a, b, link, id) = await shared();
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Sky') : f]);
      await rounds([a, b], link);
      final real = a.folder.text['$id/notebook.json']!;
      final rec = NbRecord.parse(real)!;
      expect((rec.body['fields'] as List).length, 3);
      // two writes of the record at once, as an older build sees them: this one, and an older-looking one (earlier fields_at)
      final other = {...jsonDecode(real) as Map}..['fields_at'] = (rec.body['fields_at'] as int) - 1;
      other['name'] = 'Hikes';
      for (final cutoffOrder in [0, 1]) {
        final x = pre.NbRecord.parse(real)!;
        final y = pre.NbRecord.parse(jsonEncode(other))!;
        final m = pre.NbRecord.merge(cutoffOrder == 0 ? [x, y] : [y, x])!;
        // the rewrite: written, read again, merged again
        final again = pre.NbRecord.merge([pre.NbRecord.parse(m.text)!, y])!;
        expect(jsonEncode(again.body['fields']), jsonEncode(rec.body['fields']), reason: 'order $cutoffOrder');
        expect(again.body['fields_at'], rec.body['fields_at']);
        // and the fixed build reads what the older one wrote
        final back = NbRecord.parse(again.text)!;
        expect(jsonEncode(back.body['fields']), jsonEncode(rec.body['fields']));
      }
    });
  });

  group('a crash in the middle of the migration', () {
    Future<(Dev, Dev, ShareLink, String)> old() async {
      final (a, b, link, id) = await shared(fields: [num_('Distance', unit: 'km'), txt('Weather'), txt('Notes')]);
      await a.addValues(id, 'e1', {'Distance': 3, 'Weather': 'Sun'});
      await rounds([a, b], link);
      for (final d in [a, b]) {
        await d.beforeFields();
        Dev.stripRecordFields(d.folder);
      }
      link.sync();
      return (a, b, link, id);
    }

    Future<void> checkSame(Dev a, Dev b, String id) async {
      expect(a.labels(id), ['Distance', 'Weather', 'Notes']);
      expect(b.labels(id), a.labels(id));
      for (final l in ['Distance', 'Weather', 'Notes']) {
        expect(a.field(id, l).gid, isNotNull);
        expect(a.field(id, l).gid, b.field(id, l).gid, reason: l);
      }
      expect(a.nb.notebook(id)!.def.fields.length, 3, reason: 'no field twice');
      for (final d in [a, b]) {
        final e = (await d.nb.entries(id)).single;
        expect(e.values.values.toSet(), {3, 'Sun'}, reason: d.label);
      }
    }

    test('both devices stop after the record was written and before their notebooks took the ids; then they sync', () async {
      final (a, b, link, id) = await old();
      for (final d in [a, b]) {
        await d.sync();
        link.sync();
        await d.beforeFields(); // the ids and what it remembers are gone; the record stays
      }
      await rounds([a, b], link, n: 4);
      await checkSame(a, b, id);
    });

    test('both stop after their notebooks took the ids and before they wrote down that they were done; then they sync', () async {
      final (a, b, link, id) = await old();
      for (final d in [a, b]) {
        await d.sync();
        link.sync();
        await d.beforeFields(keepGids: true);
      }
      await rounds([a, b], link, n: 4);
      await checkSame(a, b, id);
    });

    test('each device stops at a different step, each of which looks complete on its own', () async {
      final (a, b, link, id) = await old();
      await a.sync();
      link.sync();
      await a.beforeFields(); // a: the record is written, a has no ids
      await b.sync();
      link.sync();
      await b.beforeFields(keepGids: true); // b: it has the ids, it does not remember
      await rounds([a, b], link, n: 4);
      await checkSame(a, b, id);
    });

    test('after the rerun nothing is written any more (no loop)', () async {
      final (a, b, link, id) = await old();
      for (final d in [a, b]) {
        await d.sync();
        link.sync();
        await d.beforeFields(keepGids: true);
      }
      await rounds([a, b], link, n: 4);
      final before = {for (final d in [a, b]) d.label: Map.of(d.folder.text)};
      await rounds([a, b], link, n: 2);
      expect(a.folder.text, before['a']);
      expect(b.folder.text, before['b']);
      await checkSame(a, b, id);
    });

    test('an inferred removal is not lost or turned round by a rerun', () async {
      final (a, b, link, id) = await old();
      // b has no value in the field (the store drops a field without values; only a removal it cannot see is inferred)
      final weather = b.field(id, 'Weather').fid;
      for (final e in b.store.entries) {
        (e['values'] as Map).remove(weather);
      }
      await b.nb.reload();
      await b.editFields(id, (fs) => fs.where((f) => f.label != 'Weather').toList());
      for (final d in [b, a]) {
        await d.sync();
        link.sync();
      }
      await b.beforeFields(keepGids: true); // b repeats its migration
      await rounds([a, b], link, n: 5);
      expect(a.labels(id), contains('Weather'), reason: 'a holds values for it');
      expect(b.labels(id), contains('Weather'));
    });
  });

  group('review findings', () {
    test('1. a share from before with fields: b upgrades first, then a (the lower id): one set of fields, all values', () async {
      final (a, b, link) = await oldShare();
      await b.updateCache();
      await b.sync();
      link.sync();
      await a.updateCache();
      await rounds([a, b], link, n: 6);
      await expectOneSet(a, b);
    });

    test('1b. the other order: a upgrades first, then b', () async {
      final (a, b, link) = await oldShare();
      await a.updateCache();
      await a.sync();
      link.sync();
      await b.updateCache();
      await rounds([a, b], link, n: 6);
      await expectOneSet(a, b);
    });

    test('2. a field taken out before the update stays removed everywhere, and its values stay on the entries', () async {
      final (a, b, link, id) = await shared(fields: [num_('Distance'), txt('Weather'), txt('Notes')]);
      await a.addValues(id, 'e1', {'Weather': 'Sun'});
      await rounds([a, b], link);
      for (final d in [a, b]) {
        await d.beforeFields();
        Dev.stripRecordFields(d.folder);
      }
      link.sync();
      await a.editFields(id, (fs) => fs.where((f) => f.label != 'Weather').toList());
      expect(a.nb.notebook(id)!.def.fields.where((f) => f.hidden).length, 1, reason: 'the store keeps it hidden: it has values');
      await rounds([a, b], link, n: 5);
      for (final d in [a, b]) {
        expect(d.labels(id), ['Distance', 'Notes'], reason: d.label);
      }
      expect(a.nb.notebook(id)!.def.fields.where((f) => f.hidden && f.label == 'Weather').length, 1);
      expect((await a.nb.entries(id)).single.values.values, contains('Sun'));
    });

    test('3. a hidden "Notes" with values and a newer visible "Notes" on one device: both kept, the visible one visible', () async {
      final (a, b, link, id) = await shared(fields: [txt('Distance'), txt('Notes')]);
      await a.addValues(id, 'e1', {'Notes': 'old text'});
      await rounds([a, b], link);
      for (final d in [a, b]) {
        await d.beforeFields();
        Dev.stripRecordFields(d.folder);
      }
      link.sync();
      await a.editFields(id, (fs) => fs.where((f) => f.label != 'Notes').toList());
      await a.editFields(id, (fs) => [...fs, txt('Notes')]);
      await a.stripGids();
      await rounds([a, b], link, n: 5);
      final fs = a.nb.notebook(id)!.def.fields.where((f) => f.label.startsWith('Notes')).toList();
      expect(fs.length, 2);
      expect(fs.where((f) => !f.hidden).length, 1, reason: 'the new one is visible');
      expect(fs.map((f) => f.gid).toSet().length, 2, reason: 'two ids');
      expect(a.labels(id), contains('Notes'));
      expect(b.labels(id), contains('Notes'));
      expect((await a.nb.entries(id)).single.values.values, contains('old text'));
    });

    test('4a. a crash after the ids were set and before the marker (a folder error): the notes are written again under the shared names', () async {
      final (a, b, link, id) = await drifted();
      failOn(b, (p) => p.endsWith('.cnote'));
      await syncQuiet(b);
      expect(b.nb.notebook(id)!.def.fields.every((f) => f.gid != null), isTrue, reason: 'the notebook took its ids before the run stopped');
      b.folder.beforeWrite = null;
      await rounds([a, b], link, n: 5);
      for (final d in [a, b]) {
        expect((await valuesOf(d, id, 'e1'))['Weather'], 'Sun', reason: d.label);
      }
      final path = b.folder.text.keys.firstWhere((k) => k.startsWith('$id/') && k.endsWith('.cnote'));
      expect(b.folder.text[path], contains('weather: Sun'));
      expect(b.folder.text[path], isNot(contains('sky:')));
    });

    test('4b. a folder error while the record is written, then a rerun', () async {
      final (a, b, link, id) = await drifted();
      failOn(b, (p) => p.endsWith('/notebook.json'));
      await syncQuiet(b);
      b.folder.beforeWrite = null;
      await rounds([a, b], link, n: 5);
      for (final d in [a, b]) {
        expect((await valuesOf(d, id, 'e1'))['Weather'], 'Sun', reason: d.label);
        expect(d.labels(id), ['Weather', 'Notes'], reason: d.label);
      }
    });

    test('4c. another device\'s edit lands between the stopped run and its rerun', () async {
      final (a, b, link, id) = await drifted();
      failOn(b, (p) => p.endsWith('.cnote'));
      await syncQuiet(b);
      b.folder.beforeWrite = null;
      await a.sync();
      link.sync();
      await a.editFields(id, (fs) => [for (final f in fs) f.label == 'Weather' ? f.copyWith(label: 'Conditions') : f]);
      await rounds([a, b], link, n: 6);
      for (final d in [a, b]) {
        expect(d.labels(id), ['Conditions', 'Notes'], reason: d.label);
        expect((await valuesOf(d, id, 'e1'))['Conditions'], 'Sun', reason: d.label);
      }
    });

    test('4d. the notebook gets another id between the stopped run and its rerun', () async {
      final (a, b, link) = await oldShare();
      await b.updateCache();
      failOn(b, (p) => p.endsWith('.cnote'));
      await syncQuiet(b);
      b.folder.beforeWrite = null;
      link.sync();
      await a.updateCache();
      await rounds([a, b], link, n: 7);
      await expectOneSet(a, b);
    });

    test('5. a field added on both devices before the update, each with its own key in the notes: every value is kept', () async {
      final (a, b, link, id) = await shared(fields: [txt('Weather')]);
      await rounds([a, b], link);
      for (final d in [a, b]) {
        await d.beforeFields();
        Dev.stripRecordFields(d.folder);
      }
      link.sync();
      await a.editFields(id, (fs) => [...fs, txt('Trail')]);
      await b.editFields(id, (fs) => [...fs, txt('Trail')]);
      await a.addValues(id, 'ea', {'Trail': 'north'});
      await b.addValues(id, 'eb', {'Trail': 'south'});
      await a.stripGids();
      await b.stripGids();
      await b.beforeFields(props: {id: jsonEncode({b.field(id, 'Trail').fid!: 'trail_b'})});
      await rounds([a, b], link, n: 6);
      for (final d in [a, b]) {
        expect((await valuesOf(d, id, 'ea'))['Trail'], 'north', reason: d.label);
        expect((await valuesOf(d, id, 'eb'))['Trail'], 'south', reason: d.label);
        expect(d.labels(id), ['Weather', 'Trail'], reason: d.label);
      }
    });

    test('6. an old name of one field that is the current name of another field maps to the field it was', () async {
      final (a, b, link, id) = await drifted(extraSky: true);
      await rounds([a, b], link, n: 6);
      for (final d in [a, b]) {
        final v = await valuesOf(d, id, 'e1');
        expect(v['Weather'], 'Sun', reason: d.label);
        expect(v.containsKey('Sky'), isFalse, reason: '${d.label}: not in Sky');
      }
    });
  });
}
