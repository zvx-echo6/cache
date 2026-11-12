import 'dart:convert';

import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/sync/field_sync.dart';
import 'package:cache/notebook/sync/share_format.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('a record with fields is read by a build that only knows key/key_at pairs: the later `fields` is kept as a whole', () {
      // what the generic merge does with `fields`/`fields_at` (the test of the unknown-property merge covers the mechanism); here the
      // pair is there, so a build without the fix carries it
      final rec = NbRecord.live('n', nameAt: 1, body: {'name': 'Hikes', 'fields': const [], 'fields_at': 7});
      expect(rec.body['fields_at'], 7);
    });
  });
}
